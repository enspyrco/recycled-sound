#!/usr/bin/env python3
"""Option-D GATE spike: SAM 3 text-prompt segmentation LATENCY on Apple Silicon.

The make-or-break question for Option D: when the hearing aid comes to rest, we
fire ONE synchronous segment pass at the stillness moment. SAM 3 has no published
mobile variant, so the interaction-moment latency is unknown. If it's multi-second,
the user stares at a frozen screen the instant they hold still -> UX graveyard.

This times the UNGATED lite text variant (vil-uob/sam3-litetext-s0) on MPS as the
closest measurable proxy. Three numbers, because they answer different questions:

  cold_load      model .from_pretrained + .to(mps)   -> ONE-TIME app-startup tax
  cold_infer     first forward pass (lazy kernel compile, graph warmup)
  warm_infer     median of N repeats                 -> THE GATE (steady state)

In the real app the model loads once at startup (cold, amortized) then fires a
WARM inference at every stillness event -- so warm_infer is the load-bearing gauge.

Budget: interaction-moment path wants ~200ms (sub-perceptual), certainly <500ms.
Caveat to carry: Mac MPS is NOT an iPhone NPU -- a good Mac number is necessary
but not sufficient; a BAD Mac number is a strong negative regardless of phone.

CORRECTNESS: MPS dispatch is async. We torch.mps.synchronize() before stopping
every clock, else we'd time Python's queue-dispatch (~10x too fast = a plausible lie).

Usage: python3 spike_sam3_latency.py --glob 'spike_in/*.jpg' --warm 10
"""
import argparse, glob as globmod, inspect, os, statistics, sys, time
import numpy as np
from PIL import Image


def sync(dev):
    """Block until the device's queued work is actually done (so the clock is honest)."""
    import torch
    if dev == "mps":
        torch.mps.synchronize()
    elif dev == "cuda":
        torch.cuda.synchronize()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="*")
    ap.add_argument("--glob")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--text", default="hearing aid")
    ap.add_argument("--model", default="vil-uob/sam3-litetext-s0")
    ap.add_argument("--thresh", type=float, default=0.3)
    ap.add_argument("--warm", type=int, default=10, help="warm repeats per image")
    ap.add_argument("--cpu", action="store_true", help="force CPU (sanity baseline)")
    args = ap.parse_args()

    paths = list(args.images)
    if args.glob:
        paths += sorted(globmod.glob(args.glob))[: args.n]
    if not paths:
        print("no images", file=sys.stderr); sys.exit(2)

    import torch
    from transformers import Sam3Processor, AutoModel

    dev = "cpu" if args.cpu else ("mps" if torch.backends.mps.is_available() else "cpu")

    # --- COLD LOAD: the one-time startup tax (processor + model -> device) ---
    t0 = time.perf_counter()
    proc = Sam3Processor.from_pretrained(args.model)
    try:
        model = AutoModel.from_pretrained(args.model)
    except Exception:
        model = AutoModel.from_pretrained(args.model, trust_remote_code=True)
    model = model.to(dev).eval()
    sync(dev)
    cold_load_ms = (time.perf_counter() - t0) * 1000.0

    pp_sig = set(inspect.signature(proc.post_process_instance_segmentation).parameters)

    print(f"model: {args.model}")
    print(f"device: {dev}   text: '{args.text}'   warm repeats: {args.warm}")
    print(f"COLD LOAD (startup, one-time): {cold_load_ms:8.1f} ms\n")
    print(f"{'image':14s} {'WxH':>11s} {'cold_infer':>11s} "
          f"{'warm_med':>9s} {'warm_min':>9s} {'warm_max':>9s}  verdict")

    def preprocess(path):
        img = Image.open(path).convert("RGB")
        h, w = img.height, img.width
        inputs = proc(images=img, text=args.text, return_tensors="pt").to(dev)
        return inputs, (w, h)

    def infer(inputs):
        with torch.no_grad():
            _ = model(**inputs)
        sync(dev)

    all_warm = []
    for path in paths:
        inputs, (w, h) = preprocess(path)

        # COLD first inference: lazy kernel compile + graph warmup folded in.
        t0 = time.perf_counter(); infer(inputs); cold_infer_ms = (time.perf_counter() - t0) * 1000.0

        # WARM steady-state: same inputs, N repeats. Median is the gate number.
        warm = []
        for _ in range(args.warm):
            t0 = time.perf_counter(); infer(inputs); warm.append((time.perf_counter() - t0) * 1000.0)
        med = statistics.median(warm)
        all_warm.append(med)
        verdict = "PASS<500" if med < 500 else ("AMBER<1s" if med < 1000 else "FAIL>1s")
        print(f"{os.path.basename(path):14s} {f'{w}x{h}':>11s} {cold_infer_ms:9.1f}ms "
              f"{med:7.1f}ms {min(warm):7.1f}ms {max(warm):7.1f}ms  {verdict}")

    if all_warm:
        overall = statistics.median(all_warm)
        print(f"\n=== GATE: warm steady-state median across {len(all_warm)} photos = "
              f"{overall:.1f} ms ===")
        print("budget: ~200ms ideal, <500ms acceptable for the stillness interaction moment.")
        print("NOTE: Mac MPS != iPhone NPU. Necessary-not-sufficient if PASS; strong signal if FAIL.")


if __name__ == "__main__":
    main()
