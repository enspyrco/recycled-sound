#!/usr/bin/env python3
"""Upload a signed AAB to a Google Play testing track via the Android Publisher API.

This is the Android counterpart to the iOS TestFlight CI pipeline: once the
`play-publisher` service account has been granted release permission in Play
Console, a single command pushes a new build to the internal (or closed/beta)
track — no Console clicking per upload.

Auth model (two realms — see #345):
  * The service account lives in GCP (project recycled-sound-app) and holds the
    JSON key. Default key path: ~/.claude/keys/recycled-sound-play-publisher.json
    (override with $RS_PLAY_SA_KEY).
  * Its permission to publish is granted in Play Console > Users & permissions,
    NOT GCP IAM. If you get a 401/403 below, that grant is the missing step.

Usage:
  python3 scripts/play_upload.py \
      --aab recycled_sound/build/app/outputs/bundle/release/app-release.aab \
      --track internal \
      [--status draft|completed] [--package co.enspyr.recycledsound]

  --status draft     uploads the bundle and stages it on the track WITHOUT
                     releasing (good for a first dry run / sanity check).
  --status completed rolls it out to that track's testers immediately (default).

Requires: google-api-python-client, google-auth  (already present in this env).
"""

import argparse
import os
import sys

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload

DEFAULT_KEY = os.path.expanduser("~/.claude/keys/recycled-sound-play-publisher.json")
DEFAULT_PACKAGE = "co.enspyr.recycledsound"
SCOPES = ["https://www.googleapis.com/auth/androidpublisher"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--aab", required=True, help="Path to the signed .aab")
    ap.add_argument("--track", default="internal", help="internal | alpha | beta | production")
    ap.add_argument("--status", default="completed", choices=["draft", "completed"],
                    help="draft = stage without releasing; completed = roll out (default)")
    ap.add_argument("--package", default=DEFAULT_PACKAGE)
    ap.add_argument("--key", default=os.environ.get("RS_PLAY_SA_KEY", DEFAULT_KEY),
                    help="Service account JSON key path")
    args = ap.parse_args()

    if not os.path.isfile(args.aab):
        print(f"ERROR: AAB not found: {args.aab}", file=sys.stderr)
        return 2
    if not os.path.isfile(args.key):
        print(f"ERROR: service account key not found: {args.key}\n"
              f"       Set $RS_PLAY_SA_KEY or pass --key.", file=sys.stderr)
        return 2

    creds = service_account.Credentials.from_service_account_file(args.key, scopes=SCOPES)
    service = build("androidpublisher", "v3", credentials=creds, cache_discovery=False)
    edits = service.edits()

    try:
        edit_id = edits.insert(packageName=args.package, body={}).execute()["id"]
        print(f"• opened edit {edit_id}")

        media = MediaFileUpload(args.aab, mimetype="application/octet-stream", resumable=True)
        bundle = edits.bundles().upload(
            packageName=args.package, editId=edit_id, media_body=media).execute()
        version_code = bundle["versionCode"]
        print(f"• uploaded bundle — versionCode {version_code}")

        edits.tracks().update(
            packageName=args.package, editId=edit_id, track=args.track,
            body={"releases": [{"versionCodes": [str(version_code)], "status": args.status}]},
        ).execute()
        print(f"• staged versionCode {version_code} on '{args.track}' (status={args.status})")

        edits.commit(packageName=args.package, editId=edit_id).execute()
        print(f"✓ committed. Build {version_code} is on the '{args.track}' track "
              f"({'live to testers' if args.status == 'completed' else 'draft — release it in Console'}).")
        return 0

    except HttpError as e:
        status = getattr(e, "status_code", None) or (e.resp.status if e.resp else "?")
        print(f"\nERROR: Android Publisher API returned {status}", file=sys.stderr)
        # ALWAYS surface Google's real reason — a 403 on bundle upload (vs. on the
        # edit insert) is usually NOT a missing user grant; printing only the
        # canned "authorize the SA" message hides the actual cause (e.g. the app
        # needs its first manual upload, a versionCode clash, or a signing-key
        # mismatch). The reason string in e.content is what you actually need.
        detail = None
        try:
            detail = e.content.decode() if isinstance(e.content, bytes) else e.content
        except Exception:
            detail = str(e)
        print(f"  reason: {detail}", file=sys.stderr)
        if str(status) in ("401", "403"):
            print("  → If this is an authorization problem, in Play Console:\n"
                  "    Users & permissions > Invite new users >\n"
                  "    play-publisher@recycled-sound-app.iam.gserviceaccount.com\n"
                  "    Grant app access to recycled-sound with at least\n"
                  "    'Release to testing tracks'. Then re-run.\n"
                  "    (But if the SA already has access, read the reason above —\n"
                  "    a bundle-upload 403 is often a first-upload/signing issue.)",
                  file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
