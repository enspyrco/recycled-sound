# TestFlight CI

`.github/workflows/testflight.yml` builds the iOS IPA and uploads it to App Store Connect (TestFlight) on every push to `main`. It can also be triggered manually from the Actions tab via `workflow_dispatch`.

Pull-request runs are intentionally skipped — only merges to `main` produce a TestFlight build. This keeps build minutes (and Apple's submission queue) sane.

## What the workflow does

1. Checks out the repo on a `macos-14` runner.
2. Installs the Flutter stable toolchain (cached).
3. Decodes a base64 distribution certificate into a temporary keychain.
4. Decodes a base64 App Store provisioning profile into `~/Library/MobileDevice/Provisioning Profiles/`.
5. Builds the IPA with `flutter build ipa --release` using a build number derived from `7 + github.run_number` (offset past the last manually uploaded build, which was build 7 / v0.3.2 on 2026-04-06).
6. Decodes the App Store Connect API key into `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`.
7. Uploads the IPA with `xcrun altool --upload-app` using the API key + issuer ID (matches the existing manual pipeline documented in memory).
8. Best-effort cleanup of the keychain and API key on the runner.

## Required GitHub Actions secrets

Set these under **Settings → Secrets and variables → Actions** in the GitHub repo. None of them should ever be committed to the repo.

| Secret | What it is | How to produce it |
|---|---|---|
| `APP_STORE_CONNECT_API_KEY_ID` | The Key ID shown in App Store Connect for the API key (e.g. `AZ4F82S7XD`). | App Store Connect → Users and Access → Keys → existing or new key. |
| `APP_STORE_CONNECT_ISSUER_ID` | The Issuer ID UUID shown above the key list (one per team). | App Store Connect → Users and Access → Keys → top of page. |
| `APP_STORE_CONNECT_API_KEY_CONTENT` | Base64-encoded contents of the `.p8` private key file. | `base64 -i ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 \| pbcopy` |
| `KEYCHAIN_PASSWORD` | Any random string — used only to protect the ephemeral runner keychain. | `openssl rand -base64 24` |
| `IOS_CERTIFICATE_P12_BASE64` | Base64-encoded Apple Distribution `.p12` certificate. | Export from Keychain Access on a Mac that already has the cert (right-click → Export → .p12, set a password). Then `base64 -i Distribution.p12 \| pbcopy`. |
| `IOS_CERTIFICATE_P12_PASSWORD` | The password you set when exporting the `.p12`. | Type it when prompted by Keychain Access. |
| `IOS_PROVISIONING_PROFILE_BASE64` | Base64-encoded App Store provisioning profile for `co.enspyr.recycledsound`. | Download from https://developer.apple.com/account/resources/profiles → `base64 -i recycled_sound_appstore.mobileprovision \| pbcopy`. |

The API key, issuer ID, and team match the existing Enspyr team-wide credentials (see `~/.claude/projects/-Users-nick-git-individuals-seray-recycled-sound/memory/reference_testflight_deploy.md`).

## Build numbering

`pubspec.yaml` carries `version: 0.3.2+7`. The workflow overrides the build number at build time with `--build-number=$((7 + github.run_number))`, so:

- The first CI run uploads as build 8.
- Each subsequent run increments monotonically.
- The marketing version (`0.3.2`) still comes from `pubspec.yaml`; bump it manually when you want a new version train.

If you ever need to reset, replace the `7 +` offset in `testflight.yml` with whatever the last successfully uploaded build number is.

## Triggering manually

Actions → TestFlight → **Run workflow** → pick a branch (typically `main`) → Run.

## Enabling the workflow

1. Set all secrets in the table above.
2. Merge this PR to `main`.
3. The next push to `main` (or a manual `workflow_dispatch`) will build and upload. Watch Actions → TestFlight for output; Apple emails when processing finishes (~5–10 min after upload).

## Troubleshooting

- **`No signing certificate "iOS Distribution" found`** — the `.p12` import failed. Re-export from Keychain Access including the private key, and re-base64 it.
- **`Provisioning profile doesn't match`** — the profile must be for `co.enspyr.recycledsound` and include the distribution cert in `IOS_CERTIFICATE_P12_BASE64`.
- **`altool` 401/403** — Key ID / Issuer ID mismatch, or the API key's role lacks "Developer" or higher in App Store Connect.
- **Build number collision** — Apple rejects a build whose `(version, build)` pair was already accepted. Bump `version:` in `pubspec.yaml` or change the offset in the workflow.
