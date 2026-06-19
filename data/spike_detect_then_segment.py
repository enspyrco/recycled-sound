#!/usr/bin/env python3
"""Option-D spike, stage 2: detect-by-text -> box -> segment.

The fixed-geometric-prompt spike (spike_segment_masks.py) showed SAM's masks are
crisp but localization is brittle in the hand-held domain (hand wins "most
salient", thin/edge-on devices in clutter get missed: 2/3 real photos failed).
The research's principled fix is text-promptable localization. This tests the
robust two-stage path WITHOUT waiting for on-device SAM 3 PCS: YOLO-World
(open-vocab, text-prompted detection) finds the device box, then MobileSAM
segments inside it.

Usage:
    python3 spike_detect_then_segment.py --glob 'spike_in/*.jpg' [--out DIR]
    python3 spike_detect_then_segment.py IMG [IMG ...] --classes "hearing aid,earpiece"
"""
import argparse
import glob as globmod
import os
import sys

import numpy as np
from PIL import Image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="*")
    ap.add_argument("--glob")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--out", default="spike_dts")
    ap.add_argument(
        "--classes",
        default="hearing aid,earpiece,small electronic device",
        help="comma-separated open-vocab text prompts for the detector",
    )
    ap.add_argument("--detector", default="yolov8s-worldv2.pt")
    ap.add_argument("--sam", default="mobile_sam.pt")
    args = ap.parse_args()

    paths = list(args.images)
    if args.glob:
        paths += sorted(globmod.glob(args.glob))[: args.n]
    if not paths:
        print("no images", file=sys.stderr)
        sys.exit(2)
    os.makedirs(args.out, exist_ok=True)

    from ultralytics import YOLOWorld, SAM

    classes = [c.strip() for c in args.classes.split(",") if c.strip()]
    det = YOLOWorld(args.detector)
    det.set_classes(classes)
    sam = SAM(args.sam)
    print(f"detector: {args.detector}  classes: {classes}\nsam: {args.sam}\n")
    print(f"{'image':18s} {'det_conf':>8s} {'mask%':>6s} {'crop_wh':>11s}  note")

    for path in paths:
        arr = np.array(Image.open(path).convert("RGB"))
        h, w = arr.shape[:2]
        dres = det(path, conf=0.01, verbose=False)[0]
        if dres.boxes is None or len(dres.boxes) == 0:
            print(f"{os.path.basename(path):18s} {'--':>8s}  NO DETECTION")
            continue
        # Highest-confidence box.
        confs = dres.boxes.conf.cpu().numpy()
        best = int(confs.argmax())
        box = dres.boxes.xyxy.cpu().numpy()[best].astype(int).tolist()
        conf = float(confs[best])

        sres = sam(path, bboxes=[box], verbose=False)[0]
        if sres.masks is None or len(sres.masks.data) == 0:
            print(f"{os.path.basename(path):18s} {conf:8.3f}  {'--':>6s}  DET ok, NO MASK")
            continue
        mask = sres.masks.data[0].cpu().numpy().astype(bool)
        if mask.shape != (h, w):
            mask = np.array(
                Image.fromarray(mask.astype(np.uint8) * 255).resize((w, h))
            ) > 127
        frac = mask.mean()

        overlay = arr.copy()
        overlay[mask] = (0.45 * overlay[mask] + 0.55 * np.array([255, 0, 0])).astype(np.uint8)
        # draw the detection box in green
        x0, y0, x1, y1 = box
        overlay[max(y0, 0):y0 + 6, x0:x1] = [0, 255, 0]
        overlay[y1 - 6:y1, x0:x1] = [0, 255, 0]
        overlay[y0:y1, max(x0, 0):x0 + 6] = [0, 255, 0]
        overlay[y0:y1, x1 - 6:x1] = [0, 255, 0]

        ys, xs = np.where(mask)
        cy0, cy1, cx0, cx1 = ys.min(), ys.max(), xs.min(), xs.max()
        crop = np.dstack([arr, (mask * 255).astype(np.uint8)])[cy0:cy1 + 1, cx0:cx1 + 1]
        cw, ch = cx1 - cx0 + 1, cy1 - cy0 + 1

        stem = os.path.splitext(os.path.basename(path))[0]
        Image.fromarray(overlay).save(os.path.join(args.out, f"{stem}__overlay.png"))
        Image.fromarray(crop, "RGBA").save(os.path.join(args.out, f"{stem}__crop.png"))

        note = "ok"
        if frac < 0.01:
            note = "mask tiny"
        elif frac > 0.6:
            note = "mask huge (bg?)"
        print(f"{os.path.basename(path):18s} {conf:8.3f} {frac*100:6.1f} {cw:4d}x{ch:<5d}  {note}")

    print(f"\nwrote to {args.out}/ — green box = detection, red = mask")


if __name__ == "__main__":
    main()
