#!/usr/bin/env python3
"""Option-D spike: mobile-SAM mask quality on hearing-aid photos.

Answers the #1 open question from the 2026-06-18 CV research
(project_cv_research_2026_06_18.md): does a mobile-SAM-class model produce a
clean mask of a small, shiny hearing aid? EdgeSAM is the phone-proven variant;
MobileSAM (installable via ultralytics) is its near-parity QUALITY analog — we
use it here because the spike measures mask quality, not phone latency (which
the research already validated for EdgeSAM/EdgeTAM).

Pipeline per image: centre-point prompt -> mask -> overlay + background-free
crop, plus a printed mask-area fraction as a coarse sanity signal. The crop is
exactly what the identify stage would embed (segment-then-retrieve).

Usage:
    python3 spike_segment_masks.py IMG [IMG ...] [--out DIR] [--model mobile_sam.pt]
    python3 spike_segment_masks.py --glob 'images/uploaded_assets/*.png' --n 8
"""
import argparse
import glob as globmod
import os
import sys

import numpy as np
from PIL import Image


def load_rgb(path):
    im = Image.open(path).convert("RGB")
    return im, np.array(im)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="*", help="image paths")
    ap.add_argument("--glob", help="glob pattern (alternative to positional paths)")
    ap.add_argument("--n", type=int, default=8, help="max images when using --glob")
    ap.add_argument("--out", default="spike_out", help="output dir")
    ap.add_argument("--model", default="mobile_sam.pt", help="ultralytics SAM weights")
    ap.add_argument(
        "--prompt",
        choices=["point", "box"],
        default="point",
        help="point = centre click (cheap, can grab bg/sub-part); "
        "box = centred box covering --boxfrac (robust for a centred device)",
    )
    ap.add_argument(
        "--boxfrac",
        type=float,
        default=0.8,
        help="box prompt covers this fraction of the frame (centred)",
    )
    args = ap.parse_args()

    paths = list(args.images)
    if args.glob:
        paths += sorted(globmod.glob(args.glob))[: args.n]
    if not paths:
        print("no images given (use positional paths or --glob)", file=sys.stderr)
        sys.exit(2)

    os.makedirs(args.out, exist_ok=True)

    from ultralytics import SAM  # lazy import so --help is instant

    model = SAM(args.model)
    print(f"model: {args.model}   images: {len(paths)}   out: {args.out}/\n")
    print(f"{'image':42s} {'mask%':>6s} {'crop_wh':>11s}  note")

    for path in paths:
        try:
            im, arr = load_rgb(path)
        except Exception as e:
            print(f"{os.path.basename(path):42s}  LOAD ERR {e}")
            continue
        h, w = arr.shape[:2]
        if args.prompt == "box":
            # Centred box covering boxfrac of the frame: "the device is in here".
            m = (1.0 - args.boxfrac) / 2.0
            box = [int(w * m), int(h * m), int(w * (1 - m)), int(h * (1 - m))]
            res = model(im, bboxes=[box], verbose=False)[0]
        else:
            # Centre-point prompt: mimics a user centring the device in frame.
            res = model(im, points=[[w // 2, h // 2]], labels=[1], verbose=False)[0]
        if res.masks is None or len(res.masks.data) == 0:
            print(f"{os.path.basename(path):42s}  {'--':>6s}  NO MASK")
            continue
        mask = res.masks.data[0].cpu().numpy().astype(bool)
        if mask.shape != (h, w):
            mask = np.array(
                Image.fromarray(mask.astype(np.uint8) * 255).resize((w, h))
            ) > 127
        frac = mask.mean()

        # Overlay (red tint where masked) for eyeballing.
        overlay = arr.copy()
        overlay[mask] = (0.45 * overlay[mask] + 0.55 * np.array([255, 0, 0])).astype(
            np.uint8
        )

        # Background-free crop to the mask bbox — what identify would embed.
        ys, xs = np.where(mask)
        y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
        crop_rgba = np.dstack([arr, (mask * 255).astype(np.uint8)])[y0 : y1 + 1, x0 : x1 + 1]
        cw, ch = x1 - x0 + 1, y1 - y0 + 1

        stem = os.path.splitext(os.path.basename(path))[0]
        Image.fromarray(overlay).save(os.path.join(args.out, f"{stem}__overlay.png"))
        Image.fromarray(crop_rgba, "RGBA").save(
            os.path.join(args.out, f"{stem}__crop.png")
        )

        # Coarse health flags: a too-small mask = missed the device; a near-full
        # mask = grabbed the whole frame (background bleed).
        note = "ok"
        if frac < 0.02:
            note = "TOO SMALL (missed device?)"
        elif frac > 0.85:
            note = "TOO BIG (grabbed background?)"
        print(f"{os.path.basename(path):42s} {frac*100:6.1f} {cw:4d}x{ch:<5d}  {note}")

    print(f"\nwrote overlays + crops to {args.out}/ — eyeball the __overlay.png files")


if __name__ == "__main__":
    main()
