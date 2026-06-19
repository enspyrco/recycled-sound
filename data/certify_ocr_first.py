#!/usr/bin/env python3
"""Task #56 certification harness: score the OCR-first brand baseline against a
bar DEFINED UP FRONT, so the Option-D identify decision is a mechanical YES/NO.

This is the analysis half of #56. Hand it a folder of real captures (brand-face
shots of 5-8 brand-diverse devices) and it reports brand accuracy vs the bar.

WHAT IT DOES (the recipe the #57 spike validated — no learned segmenter):
  for each brand-face shot:
    crop the frame to a PYRAMID of NATIVE center-crops (default 35..85%)
      -- straddles Apple Vision's non-monotonic scale dead-band (see
         concept_option_d_architecture.md: a single crop is a knife-edge)
    run Apple Vision .accurate OCR on each crop (data/vision_ocr.swift)
    collect all tokens across scales; fuzzy-match (Levenshtein<=1, the app's
      rule -- "Resouno"->ReSound) against the canonical brand list
    brand is CORRECT if the ground-truth brand is hit at ANY scale.

THE BAR (locked before any data is shot):
  Brand: OCR(+fuzzy) correct brand on >=90% of clean brand-face shots.
  (Style >=85% is the linear probe's job -- run data/linear_probe.py on the
   lateral/medial shape crops separately; this harness scores BRAND only.)
  DECISION: brand clears -> OCR-first brand spine certified; pair with the Style
  probe. Brand fails -> the OCR-first thesis is weaker than the N=1 spike showed;
  revisit (embossed/grey-on-grey harder than 1612 suggested).
  Caveat: N~=5-8 is directionally decisive, not statistically tight.

GROUND TRUTH from filename: <brand>__<model>__<variant>.<ext>
  brand   = text before the first '__'  (e.g. resound, gn, phonak)
  variant = clean | messy | lateral | medial  (only clean/messy scored here;
            'messy' is reported separately as a robustness read, not in the bar)
  e.g.  resound__unknown__clean.jpg   phonak__audeo__messy.jpg
  (Alternatively pass --labels labels.csv with `filename,brand` rows.)

Usage:
    python3 certify_ocr_first.py --in certify_set/            # score a folder
    python3 certify_ocr_first.py --in certify_set/ --fracs 35,45,55,65,75,85
"""
import argparse
import csv
import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageOps

# Canonical brands on the Recycled Sound register (+ common sub-brand/model words
# that OCR may catch instead of the maker). Ground-truth tokens normalize to these.
BRANDS = ["resound", "oticon", "phonak", "unitron", "signia", "widex", "beltone",
          "gn", "starkey", "bernafon", "hansaton", "rexton", "blamey", "saunders",
          "sonic", "audeo", "nera", "moxi", "nexia"]
# brand aliases -> canonical (OCR/model words that imply a maker)
ALIAS = {"audeo": "phonak", "nera": "oticon", "moxi": "unitron", "nexia": "resound",
         "gn": "resound", "saunders": "blamey"}


def levenshtein(a, b):
    a, b = a.lower(), b.lower()
    if abs(len(a) - len(b)) > 1:
        return 2  # >1, we only care about <=1
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


def fuzzy_brand(token):
    """Return canonical brand if token matches a brand word with Levenshtein<=1
    (whole-token or as a contained run), else None. Mirrors the app's fuzzy rule."""
    t = re.sub(r"[^a-z]", "", token.lower())
    if len(t) < 2:
        return None
    for b in BRANDS:
        # exact substring (covers 'ReSound' inside a longer token) OR fuzzy whole-token
        if b in t or levenshtein(t, b) <= 1:
            return ALIAS.get(b, b)
    return None


def gt_brand(path, labels):
    name = os.path.basename(path)
    if labels and name in labels:
        return ALIAS.get(labels[name].lower(), labels[name].lower())
    stem = name.split("__")[0].lower()
    return ALIAS.get(stem, stem)


def variant(path):
    parts = os.path.splitext(os.path.basename(path))[0].split("__")
    return parts[-1].lower() if len(parts) >= 2 else "clean"


def center_crop(arr, frac):
    h, w = arr.shape[:2]
    m = (1.0 - frac) / 2.0
    return arr[int(h * m):int(h * (1 - m)), int(w * m):int(w * (1 - m))]


def ensure_vocr():
    vocr = "/tmp/vocr"
    src = os.path.join(os.path.dirname(__file__), "vision_ocr.swift")
    if not os.path.exists(vocr) or os.path.getmtime(src) > os.path.getmtime(vocr):
        r = subprocess.run(["swiftc", "-O", src, "-o", vocr], capture_output=True, text=True)
        if r.returncode != 0:
            print("swiftc failed:\n" + r.stderr, file=sys.stderr); sys.exit(3)
    return vocr


def run_vocr(vocr, png_paths):
    """Run the Vision OCR binary over PNGs, return {basename: [all .accurate tokens]}."""
    out = {}
    if not png_paths:
        return out
    r = subprocess.run([vocr, *png_paths], capture_output=True, text=True)
    cur = None
    for line in r.stdout.splitlines():
        m = re.match(r"^(\S+\.png)\s", line)
        if m:
            cur = m.group(1)
        elif cur and line.strip().startswith("all:"):
            toks = line.split("all:", 1)[1].strip()
            out[cur] = [t.strip() for t in toks.split("|") if t.strip()]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="indir", required=True)
    ap.add_argument("--fracs", default="35,45,55,65,75,85",
                    help="native center-crop %% pyramid (straddle the OCR dead band)")
    ap.add_argument("--labels", help="optional filename,brand CSV")
    args = ap.parse_args()

    fracs = [int(x) / 100 for x in args.fracs.split(",")]
    labels = {}
    if args.labels:
        with open(args.labels) as f:
            for row in csv.reader(f):
                if len(row) >= 2:
                    labels[row[0].strip()] = row[1].strip()

    imgs = sorted(p for ext in ("jpg", "jpeg", "png", "JPG", "HEIC")
                  for p in glob.glob(os.path.join(args.indir, f"*.{ext}")))
    if not imgs:
        print(f"no images in {args.indir}", file=sys.stderr); sys.exit(2)

    vocr = ensure_vocr()
    work = tempfile.mkdtemp(prefix="certify_")
    # crop every image to the pyramid; remember which crops belong to which source
    crop_map = {}  # crop_basename -> source_path
    for p in imgs:
        try:
            arr = np.array(ImageOps.exif_transpose(Image.open(p).convert("RGB")))
        except Exception as e:
            print(f"LOAD ERR {p}: {e}", file=sys.stderr); continue
        stem = os.path.splitext(os.path.basename(p))[0]
        for fr in fracs:
            cb = f"{stem}__f{int(fr*100):03d}.png"
            Image.fromarray(center_crop(arr, fr)).save(os.path.join(work, cb))
            crop_map[cb] = p

    toks_by_crop = run_vocr(vocr, [os.path.join(work, c) for c in crop_map])

    # aggregate per source image
    per_img = {}
    for cb, src in crop_map.items():
        toks = toks_by_crop.get(cb, [])
        hits = {fuzzy_brand(t) for t in toks}
        hits.discard(None)
        d = per_img.setdefault(src, {"scales_hit": [], "brands": set(), "raw": []})
        if hits:
            d["scales_hit"].append(int(re.search(r"f(\d+)\.png", cb).group(1)))
            d["brands"] |= hits
        d["raw"] += toks

    print(f"\nfracs: {args.fracs}   images: {len(imgs)}   brands seen: "
          f"{sorted({gt_brand(p, labels) for p in imgs})}\n")
    print(f"{'image':40s} {'GT':9s} {'variant':8s} {'got':10s} {'scales_hit':22s} verdict")
    clean_total = clean_ok = 0
    for p in imgs:
        gt = gt_brand(p, labels)
        var = variant(p)
        d = per_img.get(p, {"scales_hit": [], "brands": set(), "raw": []})
        got = ",".join(sorted(d["brands"])) or "—"
        ok = gt in d["brands"]
        scales = ",".join(str(s) for s in sorted(set(d["scales_hit"]))) or "—"
        verdict = "OK " + ("✓" if ok else "✗")
        if var in ("clean",):
            clean_total += 1; clean_ok += int(ok)
        print(f"{os.path.basename(p):40s} {gt:9s} {var:8s} {got:10s} {scales:22s} {verdict}")

    shutil.rmtree(work, ignore_errors=True)
    if clean_total:
        acc = 100.0 * clean_ok / clean_total
        bar = "PASS ✓ (>=90%)" if acc >= 90 else "FAIL ✗ (<90%)"
        print(f"\n=== BRAND BAR: {clean_ok}/{clean_total} clean brand-face shots correct "
              f"= {acc:.0f}%  ->  {bar} ===")
        print("Style >=85% is the linear-probe's call: run data/linear_probe.py on "
              "the lateral/medial crops. Caveat: N~5-8 is directional, not tight.")
    else:
        print("\nNo 'clean' variant shots found — name them <brand>__<model>__clean.jpg "
              "(or pass --labels). 'messy' shots are robustness reads, not the bar.")


if __name__ == "__main__":
    main()
