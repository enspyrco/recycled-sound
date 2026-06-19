#!/usr/bin/env python3
"""Option-D spike #57: does a cheap geometric-prompt SEGMENTER beat a DUMB FIXED
CENTER-CROP, judged by the real OCR-first bar?

Context (concept_option_d_architecture.md): we killed SAM3 on latency and pivoted
to OCR-first + controlled capture. The architecture now leans on a cheap geometric
segmenter (EdgeSAM) to (a) tighten the crop so OCR reads the tiny brand label and
(b) isolate device-only pixels for colour. Task #57 asks the subtraction question:
under CONTROLLED capture (device centered in frame), is a learned segmenter even
needed, or does a fixed center-crop do the job? If the fixed crop is as good, the
whole EdgeSAM/SAM3 sub-chain DISSOLVES — maximum subtraction.

SUBSTITUTION (named, not laundered): the segmenter arm uses MobileSAM (ultralytics)
as EdgeSAM's near-parity QUALITY analog. EdgeSAM's distinguishing virtue is on-PHONE
latency (RepViT CNN, ~26ms iPhone 14, arXiv 2312.06660), which a Mac MPS number
can't faithfully measure; for box-prompted MASK QUALITY the two are near-parity
(same distilled-SAM decoder lineage). The EdgeSAM-specific on-phone latency gap
stays OPEN and is cheap to close later IF this spike shows the segmenter is needed.

THE BAR (defined up front, before looking at any output):
  A crop SUCCEEDS if (1) OCR reads the brand off it (ReSound, via the app's
  Levenshtein-<=1 fuzzy — "Resouno"->ReSound) AND (2) colour pixels are device-only
  (no skin/background). (2) is structurally UNACHIEVABLE for a fixed crop (no mask),
  ACHIEVABLE for a segmenter — so even an OCR tie still favours the segmenter on (2).
  Latency target < 500ms warm. Mask/crop usable on >=2/3 photos -> de-risked.

Ground truth: all 3 spike photos are ONE ReSound BTE.
  1612 = brand-label face PRESENTED, un-occluded  -> brand info IS in the frame
  1613 = CE/battery face shown (brand NOT on this face) -> info NOT in frame
  1614 = edge-on sliver, no brand text in frame        -> info NOT in frame
So a HONEST pass = brand recovered on 1612; 1613/1614 are capture-presentation
failures no crop can fix (no model reads info that isn't in the frame).

Outputs per photo into --out: fixed-crop PNGs (a couple fractions), MobileSAM
box-prompt crop (orig pixels) + white-composited crop + overlay, MobileSAM
point-prompt crop (contrast). Prints mask%, colour-purity proxy, warm latency.
Then run data/vision_ocr.swift over the --out dir to score the OCR bar.

Usage:
    python3 spike_crop_vs_segment.py --glob 'spike_in/*.jpg' --out spike_cvs
"""
import argparse
import glob as globmod
import os
import statistics
import sys
import time

import numpy as np
from PIL import Image, ImageOps


def sync(dev):
    """Honest clock: block until queued device work is actually done (MPS is async)."""
    import torch
    if dev == "mps":
        torch.mps.synchronize()
    elif dev == "cuda":
        torch.cuda.synchronize()


def load_rgb_oriented(path):
    """EXIF-transpose so phone photos (orient=6) are upright — ignoring this is a
    known 0-token OCR bug (concept_option_d note)."""
    im = ImageOps.exif_transpose(Image.open(path).convert("RGB"))
    return im, np.array(im)


def center_crop(arr, frac):
    h, w = arr.shape[:2]
    m = (1.0 - frac) / 2.0
    y0, y1 = int(h * m), int(h * (1 - m))
    x0, x1 = int(w * m), int(w * (1 - m))
    return arr[y0:y1, x0:x1]


def colour_purity(arr_crop, mask_crop):
    """Proxy for 'device-only colour': stdev of masked pixels vs whole crop.
    A device-only region is more colour-coherent (low stdev) than a region that
    also contains skin + couch + glare. Returns (masked_std, full_std)."""
    full_std = float(arr_crop.reshape(-1, 3).std(axis=0).mean())
    if mask_crop is None or mask_crop.sum() == 0:
        return None, full_std
    dev_px = arr_crop[mask_crop]
    masked_std = float(dev_px.std(axis=0).mean()) if len(dev_px) else None
    return masked_std, full_std


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="*")
    ap.add_argument("--glob")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--out", default="spike_cvs")
    ap.add_argument("--model", default="mobile_sam.pt")
    ap.add_argument("--boxfrac", type=float, default=0.6,
                    help="centered box-prompt covers this fraction of the frame")
    ap.add_argument("--cropfracs", default="0.4,0.6",
                    help="fixed center-crop fractions to emit for the dumb baseline")
    ap.add_argument("--warm", type=int, default=8, help="warm latency repeats")
    args = ap.parse_args()

    paths = list(args.images)
    if args.glob:
        paths += sorted(globmod.glob(args.glob))[: args.n]
    if not paths:
        print("no images", file=sys.stderr); sys.exit(2)
    os.makedirs(args.out, exist_ok=True)
    cropfracs = [float(x) for x in args.cropfracs.split(",")]

    import torch
    from ultralytics import SAM
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    model = SAM(args.model)

    print(f"segmenter: {args.model} (EdgeSAM quality analog)   device(reported): {dev}")
    print(f"box-prompt frac: {args.boxfrac}   fixed-crop fracs: {cropfracs}   warm: {args.warm}\n")
    print(f"{'image':14s} {'arm':12s} {'mask%':>6s} {'crop_wh':>11s} "
          f"{'dev_std':>8s} {'full_std':>9s}  note")

    latencies = []
    for path in paths:
        im, arr = load_rgb_oriented(path)
        h, w = arr.shape[:2]
        stem = os.path.splitext(os.path.basename(path))[0]

        # --- DUMB FIXED CENTER-CROPS (no model) ---
        for cf in cropfracs:
            cc = center_crop(arr, cf)
            _, fstd = colour_purity(cc, None)
            Image.fromarray(cc).save(os.path.join(args.out, f"{stem}__fixed{int(cf*100)}.png"))
            print(f"{stem:14s} {'fixed'+str(int(cf*100)):12s} {'--':>6s} "
                  f"{cc.shape[1]:4d}x{cc.shape[0]:<5d} {'--':>8s} {fstd:9.1f}  "
                  f"colour NOT device-only (no mask)")

        # --- SEGMENTER: centered box prompt (controlled-capture assumption) ---
        m = (1.0 - args.boxfrac) / 2.0
        box = [int(w * m), int(h * m), int(w * (1 - m)), int(h * (1 - m))]

        # warm latency (sync discipline; full model call = encode+decode), labeled proxy
        res = model(im, bboxes=[box], verbose=False)[0]  # cold (graph warmup) + result
        warm = []
        for _ in range(args.warm):
            t0 = time.perf_counter()
            _ = model(im, bboxes=[box], verbose=False)
            sync(dev)
            warm.append((time.perf_counter() - t0) * 1000.0)
        med = statistics.median(warm); latencies.append(med)

        def emit_mask(res, tag):
            if res.masks is None or len(res.masks.data) == 0:
                print(f"{stem:14s} {tag:12s} {'--':>6s} {'--':>11s} "
                      f"{'--':>8s} {'--':>9s}  NO MASK")
                return
            mask = res.masks.data[0].cpu().numpy().astype(bool)
            if mask.shape != (h, w):
                mask = np.array(Image.fromarray(mask.astype(np.uint8) * 255).resize((w, h))) > 127
            frac = mask.mean()
            ys, xs = np.where(mask)
            if len(ys) == 0:
                print(f"{stem:14s} {tag:12s} {frac*100:6.1f} EMPTY"); return
            y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
            arr_crop = arr[y0:y1+1, x0:x1+1]
            mask_crop = mask[y0:y1+1, x0:x1+1]
            dstd, fstd = colour_purity(arr_crop, mask_crop)
            # orig-pixel crop (for OCR) + white-composited crop (for colour/identify)
            Image.fromarray(arr_crop).save(os.path.join(args.out, f"{stem}__{tag}.png"))
            white = arr_crop.copy(); white[~mask_crop] = 255
            Image.fromarray(white).save(os.path.join(args.out, f"{stem}__{tag}_white.png"))
            overlay = arr.copy()
            overlay[mask] = (0.45 * overlay[mask] + 0.55 * np.array([255, 0, 0])).astype(np.uint8)
            Image.fromarray(overlay).save(os.path.join(args.out, f"{stem}__{tag}_overlay.png"))
            cw, ch = x1 - x0 + 1, y1 - y0 + 1
            note = "ok"
            if frac < 0.02: note = "TOO SMALL (missed device?)"
            elif frac > 0.85: note = "TOO BIG (grabbed bg?)"
            print(f"{stem:14s} {tag:12s} {frac*100:6.1f} {cw:4d}x{ch:<5d} "
                  f"{dstd if dstd is not None else 0:8.1f} {fstd:9.1f}  {note}")

        emit_mask(res, "sambox")
        res_pt = model(im, points=[[w // 2, h // 2]], labels=[1], verbose=False)[0]
        emit_mask(res_pt, "sampoint")
        print(f"{stem:14s} {'sam_latency':12s} warm median = {med:.1f} ms "
              f"(MobileSAM TinyViT on {dev}; EdgeSAM RepViT would differ — proxy)")
        print()

    if latencies:
        print(f"=== segmenter warm latency median across {len(latencies)} photos = "
              f"{statistics.median(latencies):.1f} ms (PROXY: MobileSAM/Mac, not EdgeSAM/phone) ===")
    print(f"\nwrote crops to {args.out}/. NEXT: score the OCR bar:")
    print(f"  swiftc -O vision_ocr.swift -o /tmp/vocr 2>/dev/null; /tmp/vocr {args.out}/*.png")


if __name__ == "__main__":
    main()
