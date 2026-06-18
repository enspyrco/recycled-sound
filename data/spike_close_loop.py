#!/usr/bin/env python3
"""Option-D spike, stage 4: close the loop — segment -> embed -> retrieve.

Proves segment-then-IDENTIFY, not just segment-then-mask. For each real photo:
  RAW  : embed the whole photo with CLIP -> kNN vs catalog (hearing_aids_visual)
  MASK : SAM 3 text-prompt "hearing aid" -> crop -> composite on WHITE
         (match the catalog's product-on-white domain) -> embed -> kNN
and compares the top hits. Hypothesis: the clean masked crop closes the
domain gap and ranks the correct brand (ReSound) higher than the raw photo.

Same CLIP model as build_visual_embeddings.py: open_clip ViT-B-32 laion2b.
"""
import argparse, glob as globmod, os, sys
import numpy as np
from PIL import Image


def clip_embed(model, preprocess, dev, pil_img):
    import torch
    t = preprocess(pil_img).unsqueeze(0).to(dev)
    with torch.no_grad():
        e = model.encode_image(t)
        e = e / e.norm(dim=-1, keepdim=True)
    return e.cpu().numpy()[0].tolist()


def fmt_hits(res):
    out = []
    metas = res.get("metadatas", [[]])[0]
    dists = res.get("distances", [[]])[0]
    for meta, d in zip(metas, dists):
        devs = meta.get("devices") or meta.get("model") or meta.get("brand") or "?"
        if isinstance(devs, str) and len(devs) > 38:
            devs = devs[:38]
        out.append(f"{str(devs):40s} d={d:.3f}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("images", nargs="*")
    ap.add_argument("--glob")
    ap.add_argument("--n", type=int, default=8)
    ap.add_argument("--k", type=int, default=3)
    ap.add_argument("--text", default="hearing aid")
    ap.add_argument("--thresh", type=float, default=0.1)
    ap.add_argument("--sam", default="vil-uob/sam3-litetext-s0")
    ap.add_argument("--collection", default="hearing_aids_visual")
    args = ap.parse_args()

    paths = list(args.images)
    if args.glob:
        paths += sorted(globmod.glob(args.glob))[: args.n]
    if not paths:
        print("no images", file=sys.stderr); sys.exit(2)

    import torch, open_clip, chromadb
    from transformers import Sam3Processor, AutoModel

    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    print(f"loading CLIP ViT-B-32 laion2b on {dev}...")
    clip, _, preprocess = open_clip.create_model_and_transforms(
        "ViT-B-32", pretrained="laion2b_s34b_b79k")
    clip = clip.to(dev).eval()
    col = chromadb.PersistentClient(path="chroma_db").get_collection(args.collection)
    print(f"collection '{args.collection}': {col.count()} embeddings")
    print(f"loading SAM3 lite text ({args.sam})...")
    proc = Sam3Processor.from_pretrained(args.sam)
    sam = AutoModel.from_pretrained(args.sam).to(dev).eval()

    for path in paths:
        img = Image.open(path).convert("RGB")
        arr = np.array(img); h, w = arr.shape[:2]
        print(f"\n{'='*70}\n{os.path.basename(path)}")

        # RAW retrieval
        raw_emb = clip_embed(clip, preprocess, dev, img)
        raw = col.query(query_embeddings=[raw_emb], n_results=args.k)
        print("  RAW  photo -> top hits:")
        for line in fmt_hits(raw): print("    ", line)

        # SAM3 mask -> crop on white -> retrieval
        inp = proc(images=img, text=args.text, return_tensors="pt").to(dev)
        with torch.no_grad():
            out = sam(**inp)
        res = proc.post_process_instance_segmentation(
            out, target_sizes=[(h, w)], threshold=args.thresh, mask_threshold=0.5)[0]
        masks, scores = res.get("masks"), res.get("scores")
        if masks is None or len(masks) == 0:
            print("  MASK : NO INSTANCE (text prompt found nothing)")
            continue
        scores = scores.cpu().numpy() if hasattr(scores, "cpu") else np.array(scores)
        m = masks[int(scores.argmax())]
        m = (m.cpu().numpy() if hasattr(m, "cpu") else np.array(m)).astype(bool)
        if m.shape != (h, w):
            m = np.array(Image.fromarray(m.astype(np.uint8) * 255).resize((w, h))) > 127
        ys, xs = np.where(m)
        y0, y1, x0, x1 = ys.min(), ys.max(), xs.min(), xs.max()
        white = np.full_like(arr, 255)
        white[m] = arr[m]
        crop = Image.fromarray(white[y0:y1 + 1, x0:x1 + 1])
        os.makedirs("spike_loop", exist_ok=True)
        crop.save(f"spike_loop/{os.path.splitext(os.path.basename(path))[0]}__whitecrop.png")
        mask_emb = clip_embed(clip, preprocess, dev, crop)
        mk = col.query(query_embeddings=[mask_emb], n_results=args.k)
        print(f"  MASK crop (score {scores.max():.2f}) -> top hits:")
        for line in fmt_hits(mk): print("    ", line)

    print("\nwrote white-bg crops to spike_loop/")


if __name__ == "__main__":
    main()
