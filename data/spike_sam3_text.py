#!/usr/bin/env python3
"""Option-D spike, stage 3: SAM 3 TEXT-prompted segmentation (PCS).

The geometric-prompt spikes showed localization is the blocker in the hand-held
domain (centre-point grabs the hand; YOLO-World doesn't know "hearing aid").
SAM 3's headline capability is Promptable Concept Segmentation: segment the
thing *named* by a noun phrase. This tests that path with an UNGATED lite text
variant (vil-uob/sam3-litetext-s0) — weaker than full facebook/sam3 (which is
manually gated), but it directly answers: does "hearing aid" as a text prompt
locate + mask the device, including in the low-contrast hand-held case?

Usage: python3 spike_sam3_text.py --glob 'spike_in/*.jpg' --text 'hearing aid'
"""
import argparse, glob as globmod, inspect, os, sys
import numpy as np
from PIL import Image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="*")
    ap.add_argument("--glob")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--text", default="hearing aid")
    ap.add_argument("--out", default="spike_sam3")
    ap.add_argument("--model", default="vil-uob/sam3-litetext-s0")
    ap.add_argument("--thresh", type=float, default=0.3)
    args = ap.parse_args()

    paths = list(args.images)
    if args.glob:
        paths += sorted(globmod.glob(args.glob))[: args.n]
    if not paths:
        print("no images", file=sys.stderr); sys.exit(2)
    os.makedirs(args.out, exist_ok=True)

    import torch
    from transformers import Sam3Processor, AutoModel
    proc = Sam3Processor.from_pretrained(args.model)
    try:
        model = AutoModel.from_pretrained(args.model)
    except Exception:
        model = AutoModel.from_pretrained(args.model, trust_remote_code=True)
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    model = model.to(dev).eval()
    pp_sig = set(inspect.signature(proc.post_process_instance_segmentation).parameters)
    print(f"model: {args.model}  device: {dev}  text: '{args.text}'  thresh: {args.thresh}")
    print(f"pp params: {pp_sig}\n")
    print(f"{'image':16s} {'#inst':>5s} {'bestScore':>9s} {'mask%':>6s}  note")

    for path in paths:
        arr = np.array(Image.open(path).convert("RGB")); h, w = arr.shape[:2]
        inputs = proc(images=Image.open(path).convert("RGB"), text=args.text,
                      return_tensors="pt").to(dev)
        with torch.no_grad():
            outputs = model(**inputs)
        kw = {}
        if "target_sizes" in pp_sig: kw["target_sizes"] = [(h, w)]
        if "threshold" in pp_sig: kw["threshold"] = args.thresh
        if "mask_threshold" in pp_sig: kw["mask_threshold"] = 0.5
        try:
            res = proc.post_process_instance_segmentation(outputs, **kw)[0]
        except Exception as e:
            print(f"{os.path.basename(path):16s}  post-process ERR: {str(e)[:60]}"); continue
        masks = res.get("masks"); scores = res.get("scores")
        if masks is None or len(masks) == 0:
            print(f"{os.path.basename(path):16s} {0:5d} {'--':>9s}  {'--':>6s}  NO INSTANCE"); continue
        scores = scores.cpu().numpy() if hasattr(scores, "cpu") else np.array(scores)
        best = int(scores.argmax())
        m = masks[best]
        m = (m.cpu().numpy() if hasattr(m, "cpu") else np.array(m)).astype(bool)
        if m.shape != (h, w):
            m = np.array(Image.fromarray(m.astype(np.uint8) * 255).resize((w, h))) > 127
        frac = m.mean()
        overlay = arr.copy()
        overlay[m] = (0.45 * overlay[m] + 0.55 * np.array([255, 0, 0])).astype(np.uint8)
        stem = os.path.splitext(os.path.basename(path))[0]
        Image.fromarray(overlay).save(os.path.join(args.out, f"{stem}__overlay.png"))
        print(f"{os.path.basename(path):16s} {len(masks):5d} {scores[best]:9.3f} {frac*100:6.1f}  ok")

    print(f"\nwrote overlays to {args.out}/")


if __name__ == "__main__":
    main()
