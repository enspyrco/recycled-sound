#!/usr/bin/env python3
"""Option-D spike, stage 5: DINOv2 vs CLIP fine-grained retrieval bake-off.

The close-the-loop spike showed CLIP ViT-B/32 retrieval is the weak link
(wrong brand/style even on clean SAM3 crops). The research flagged DINOv2/v3
self-supervised features as stronger for fine-grained. This embeds the SAME
catalog (1927 imgs, aligned to chroma hearing_aids_visual metadata) with BOTH
DINOv2 and CLIP, retrieves the SAME SAM3 white-bg crops, and scores each on
brand (ReSound) and style (BTE/RIC) correctness — apples to apples.

Catalog DINOv2 embeddings are cached to dinov2_catalog.npz (slow first run).
"""
import glob, os, sys
import numpy as np
from PIL import Image

GT_BRAND = "resound"            # all 3 query photos are ReSound
GT_STYLE = {"behind the ear", "receiver in canal", "ric", "bte"}  # 1612 is a BTE


def l2(x):
    return x / (np.linalg.norm(x, axis=-1, keepdims=True) + 1e-9)


def catalog_meta():
    import chromadb
    col = chromadb.PersistentClient(path="chroma_db").get_collection("hearing_aids_visual")
    got = col.get(include=["metadatas", "embeddings"])
    rows = []
    for meta, emb in zip(got["metadatas"], got["embeddings"]):
        lp = meta.get("local_path")
        if not lp:
            continue
        rows.append({
            "path": lp,
            "manufacturer": meta.get("manufacturer", "?"),
            "name": meta.get("name", "?"),
            "style": meta.get("style", "?"),
            "all_names": meta.get("all_device_names", ""),
            "clip": np.array(emb, dtype=np.float32),
        })
    return rows


def dinov2_embed_batch(paths, batch=16):
    import torch
    from transformers import AutoImageProcessor, AutoModel
    dev = "mps" if torch.backends.mps.is_available() else "cpu"
    proc = AutoImageProcessor.from_pretrained("facebook/dinov2-base")
    model = AutoModel.from_pretrained("facebook/dinov2-base").to(dev).eval()
    embs = []
    for i in range(0, len(paths), batch):
        chunk = paths[i:i + batch]
        imgs = []
        for p in chunk:
            try:
                imgs.append(Image.open(p).convert("RGB"))
            except Exception:
                imgs.append(Image.new("RGB", (224, 224), (255, 255, 255)))
        inp = proc(images=imgs, return_tensors="pt").to(dev)
        with torch.no_grad():
            out = model(**inp)
        e = out.pooler_output.cpu().numpy()
        embs.append(e)
        if i % (batch * 10) == 0:
            print(f"  dinov2 catalog {i}/{len(paths)}")
    return l2(np.vstack(embs).astype(np.float32))


def dinov2_embed_one(img):
    import torch
    from transformers import AutoImageProcessor, AutoModel
    if not hasattr(dinov2_embed_one, "m"):
        dev = "mps" if torch.backends.mps.is_available() else "cpu"
        dinov2_embed_one.dev = dev
        dinov2_embed_one.p = AutoImageProcessor.from_pretrained("facebook/dinov2-base")
        dinov2_embed_one.m = AutoModel.from_pretrained("facebook/dinov2-base").to(dev).eval()
    inp = dinov2_embed_one.p(images=img, return_tensors="pt").to(dinov2_embed_one.dev)
    with torch.no_grad():
        e = dinov2_embed_one.m(**inp).pooler_output.cpu().numpy()
    return l2(e)[0]


def clip_embed_one(img):
    import torch, open_clip
    if not hasattr(clip_embed_one, "m"):
        dev = "mps" if torch.backends.mps.is_available() else "cpu"
        clip_embed_one.dev = dev
        m, _, pp = open_clip.create_model_and_transforms("ViT-B-32", pretrained="laion2b_s34b_b79k")
        clip_embed_one.m = m.to(dev).eval(); clip_embed_one.pp = pp
    t = clip_embed_one.pp(img).unsqueeze(0).to(clip_embed_one.dev)
    with torch.no_grad():
        e = clip_embed_one.m.encode_image(t).cpu().numpy()
    return l2(e)[0]


def score(rows, idxs):
    """Report top hits + rank of first correct-brand and first correct-style."""
    brand_rank = style_rank = None
    for rank, i in enumerate(idxs, 1):
        r = rows[i]
        txt = (r["name"] + " " + r["all_names"]).lower()
        if brand_rank is None and GT_BRAND in txt:
            brand_rank = rank
        if style_rank is None and r["style"].lower() in GT_STYLE:
            style_rank = rank
    return brand_rank, style_rank


def main():
    crops = sorted(glob.glob("spike_loop/*__whitecrop.png"))
    if not crops:
        print("no crops in spike_loop/ — run spike_close_loop.py first", file=sys.stderr)
        sys.exit(2)

    print("loading catalog metadata + CLIP embeddings from chroma...")
    rows = catalog_meta()
    clip_cat = l2(np.vstack([r["clip"] for r in rows]))
    def resolve(lp):
        for cand in (lp, os.path.join("images", lp), os.path.join("data", "images", lp)):
            if os.path.exists(cand):
                return cand
        return lp
    paths = [resolve(r["path"]) for r in rows]
    missing = sum(1 for p in paths if not os.path.exists(p))
    if missing:
        print(f"  WARNING: {missing}/{len(paths)} catalog images missing on disk")

    cache = "dinov2_catalog.npz"
    if os.path.exists(cache):
        print(f"loading cached DINOv2 catalog: {cache}")
        dino_cat = np.load(cache)["emb"]
        if dino_cat.shape[0] != len(rows):
            print("  cache stale — re-embedding"); dino_cat = None
    else:
        dino_cat = None
    if dino_cat is None:
        print(f"embedding {len(rows)} catalog images with DINOv2 (slow, cached after)...")
        dino_cat = dinov2_embed_batch(paths)
        np.savez_compressed(cache, emb=dino_cat)

    K = 5
    print(f"\n{'='*72}\nBAKE-OFF (ground truth: ReSound, BTE/RIC). rank=1 is best.\n{'='*72}")
    for cp in crops:
        img = Image.open(cp).convert("RGB")
        print(f"\n{os.path.basename(cp)}")
        for label, qfn, cat in [("CLIP  ", clip_embed_one, clip_cat),
                                ("DINOv2", dinov2_embed_one, dino_cat)]:
            q = qfn(img)
            sims = cat @ q
            idxs = np.argsort(-sims)[:K]
            br, st = score(rows, idxs)
            top = rows[idxs[0]]
            print(f"  {label}: brand_rank={br or '>5':<3} style_rank={st or '>5':<3} "
                  f"| top1: {top['manufacturer'][:10]:10s} {top['name'][:34]:34s} [{top['style'][:10]}]")
    print("\n(brand_rank/style_rank = position of first correct hit in top-5; lower=better)")


if __name__ == "__main__":
    main()
