#!/usr/bin/env python3
"""
🎯 CLIPArTT Test-Time Adaptation for Hearing Aid Visual Search
================================================================

The scanner uses CLIP visual search across ~1,927 product-shot embeddings.
When matching real-world hand-held photos, average cosine similarity drops
to ~0.518 (LOW threshold) — a clear domain shift.

This script implements a CLIPArTT-inspired test-time adaptation
(https://arxiv.org/pdf/2405.00754):

  1. Encode target (real-world or synthesised) photos with frozen CLIP.
  2. For each target embedding, pseudo-label it against the catalog via
     top-k cosine similarity (transductive pseudo-labels).
  3. Train a lightweight residual adapter on CLIP's image-embedding output
     (512 → 512, initialised to identity) so that each target embedding
     becomes more similar to its top-k catalog pseudo-class centroids than
     to other classes (a transductive InfoNCE objective).
  4. Re-embed the entire catalog through the adapter and write a NEW
     ChromaDB collection `clip_visual_adapted` — the original
     `hearing_aids_visual` collection is untouched.
  5. Evaluate top-1 / top-5 retrieval accuracy on a held-out target set,
     before and after adaptation; emit `data/adaptation_report.md`.

Why an adapter rather than full encoder LoRA?
  - Fast and deterministic on MPS.
  - Catalog has only ~1.9k embeddings → adapter capacity is appropriate.
  - Keeps the door open for a heavier LoRA fine-tune later (task #15).

GRACEFUL DEGRADATION
--------------------
If no curated real-world target photos are present (current state — there
is no `data/real_world_photos/` directory), we hold out a stratified
sample of the catalog itself and apply STRONG hand-held-photo
augmentations (heavy blur, rotation, perspective skew, brightness jitter,
JPEG-style compression, partial occlusion) to *simulate* the target
distribution. This is FLAGGED in the report — it under-represents the true
domain shift. The right next step once Seray ships real photos is to drop
them into `data/real_world_photos/<brand>/...` and rerun.

USAGE
-----
    python3 data/clipartt_adaptation.py
    python3 data/clipartt_adaptation.py --epochs 50 --lr 1e-3 --topk 5
    python3 data/clipartt_adaptation.py --real-photos data/real_world_photos
"""
from __future__ import annotations

import argparse
import json
import math
import random
import sys
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import List, Tuple

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from PIL import Image, ImageFilter

import chromadb
import open_clip


# ──────────────────────────────────────────────────────────────────────
# Paths and defaults
# ──────────────────────────────────────────────────────────────────────
DATA_DIR = Path(__file__).parent
CHROMA_DIR = DATA_DIR / "chroma_db"
IMAGE_DIR = DATA_DIR / "images"
PROCESSED_DIR = DATA_DIR / "processed"
REPORT_PATH = DATA_DIR / "adaptation_report.md"
ADAPTER_PATH = PROCESSED_DIR / "clipartt_adapter.pt"

MODEL_NAME = "ViT-B-32"
PRETRAINED = "laion2b_s34b_b79k"
SOURCE_COLLECTION = "hearing_aids_visual"
ADAPTED_COLLECTION = "clip_visual_adapted"


# ──────────────────────────────────────────────────────────────────────
# Hyper-parameter struct (logged into the report for reproducibility)
# ──────────────────────────────────────────────────────────────────────
@dataclass
class Config:
    seed: int = 1337
    holdout_fraction: float = 0.15
    topk_pseudo: int = 5
    epochs: int = 30
    batch_size: int = 64
    lr: float = 5e-4
    weight_decay: float = 1e-4
    temperature_init: float = 1.0 / 0.07  # CLIP default scale
    augment_strength: str = "heavy"        # heavy | light | none
    real_photos_dir: str | None = None     # if set, use real photos as targets
    model_name: str = MODEL_NAME
    pretrained: str = PRETRAINED


# ──────────────────────────────────────────────────────────────────────
# Reproducibility
# ──────────────────────────────────────────────────────────────────────
def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.backends.mps.is_available():
        torch.mps.manual_seed(seed)


# ──────────────────────────────────────────────────────────────────────
# Augmentations — simulate hand-held real-world photos
# ──────────────────────────────────────────────────────────────────────
def hand_held_augment(img: Image.Image, strength: str = "heavy", rng: random.Random | None = None) -> Image.Image:
    """Apply augmentations that roughly bridge product-shot → hand-held domain.

    Heavy strength is the default — product shots are clean, hand-held
    photos have: motion blur, awkward angles, uneven lighting, low-res
    crops, fingers/desk-clutter occlusions.
    """
    if strength == "none":
        return img
    rng = rng or random.Random()
    w, h = img.size

    # 1. Random rotation ±25°
    img = img.rotate(rng.uniform(-25, 25), resample=Image.BILINEAR, expand=False, fillcolor=(255, 255, 255))

    # 2. Perspective skew (mild)
    if strength == "heavy":
        dx = int(w * rng.uniform(-0.08, 0.08))
        dy = int(h * rng.uniform(-0.08, 0.08))
        img = img.transform(
            (w, h),
            Image.AFFINE,
            (1, rng.uniform(-0.1, 0.1), dx, rng.uniform(-0.1, 0.1), 1, dy),
            resample=Image.BILINEAR,
            fillcolor=(255, 255, 255),
        )

    # 3. Blur (motion / out-of-focus)
    blur_radius = rng.uniform(0.5, 2.5) if strength == "heavy" else rng.uniform(0.0, 0.8)
    img = img.filter(ImageFilter.GaussianBlur(radius=blur_radius))

    # 4. Brightness/colour jitter via Pillow ImageEnhance (kept minimal-dep)
    from PIL import ImageEnhance
    img = ImageEnhance.Brightness(img).enhance(rng.uniform(0.7, 1.3))
    img = ImageEnhance.Contrast(img).enhance(rng.uniform(0.75, 1.25))
    img = ImageEnhance.Color(img).enhance(rng.uniform(0.6, 1.3))

    # 5. Downscale-then-upscale to mimic low-res phone crops
    if strength == "heavy":
        small = max(64, int(min(w, h) * rng.uniform(0.4, 0.7)))
        img = img.resize((small, small), Image.BILINEAR).resize((w, h), Image.BILINEAR)

    # 6. Random partial occlusion (a hand, finger, desk edge)
    if strength == "heavy" and rng.random() < 0.6:
        occ_w = int(w * rng.uniform(0.1, 0.3))
        occ_h = int(h * rng.uniform(0.1, 0.3))
        ox = rng.randint(0, max(1, w - occ_w))
        oy = rng.randint(0, max(1, h - occ_h))
        # paint a neutral grey patch
        from PIL import ImageDraw
        draw = ImageDraw.Draw(img)
        grey = rng.randint(100, 200)
        draw.rectangle([ox, oy, ox + occ_w, oy + occ_h], fill=(grey, grey, grey))

    return img


# ──────────────────────────────────────────────────────────────────────
# Adapter module — residual identity-init linear layer
# ──────────────────────────────────────────────────────────────────────
class ResidualAdapter(nn.Module):
    """y = L2-normalise(x + W·x), where W is initialised to zero so that
    the network starts as the identity. Keeps adaptation conservative and
    means a pre-adaptation comparison is meaningful (no random shift)."""

    def __init__(self, dim: int = 512):
        super().__init__()
        self.proj = nn.Linear(dim, dim, bias=False)
        nn.init.zeros_(self.proj.weight)
        self.logit_scale = nn.Parameter(torch.tensor(math.log(1.0 / 0.07)))

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        out = x + self.proj(x)
        out = out / out.norm(dim=-1, keepdim=True).clamp_min(1e-8)
        return out


# ──────────────────────────────────────────────────────────────────────
# Catalog loader
# ──────────────────────────────────────────────────────────────────────
def load_catalog(client: chromadb.PersistentClient) -> Tuple[np.ndarray, List[str], List[dict], List[str]]:
    """Return (embeddings [N×512], ids, metadatas, class_labels) for the catalog."""
    col = client.get_collection(SOURCE_COLLECTION)
    got = col.get(include=["embeddings", "metadatas", "documents"])
    embs = np.asarray(got["embeddings"], dtype=np.float32)
    embs /= np.linalg.norm(embs, axis=-1, keepdims=True).clip(min=1e-8)
    ids = got["ids"]
    metas = got["metadatas"]
    # Class label = device name (the retrieval target)
    labels = [m.get("name", "unknown") for m in metas]
    return embs, ids, metas, labels


# ──────────────────────────────────────────────────────────────────────
# CLIP loading
# ──────────────────────────────────────────────────────────────────────
def load_clip(cfg: Config, device: str):
    print(f"🧠 Loading CLIP {cfg.model_name} ({cfg.pretrained})...")
    t0 = time.time()
    # Surface errors loudly — do NOT silently fall back to a smaller model
    model, _, preprocess = open_clip.create_model_and_transforms(
        cfg.model_name, pretrained=cfg.pretrained
    )
    model.eval()
    model = model.to(device)
    print(f"   loaded in {time.time() - t0:.1f}s on {device}")
    return model, preprocess


@torch.no_grad()
def encode_images(model, preprocess, paths: List[Path], device: str, batch_size: int = 32,
                  augment: bool = False, aug_strength: str = "heavy", aug_seed: int = 0) -> np.ndarray:
    rng = random.Random(aug_seed)
    out: List[torch.Tensor] = []
    for i in range(0, len(paths), batch_size):
        batch_paths = paths[i:i + batch_size]
        tensors = []
        for p in batch_paths:
            img = Image.open(p).convert("RGB")
            if augment:
                img = hand_held_augment(img, strength=aug_strength, rng=rng)
            tensors.append(preprocess(img))
        if not tensors:
            continue
        x = torch.stack(tensors).to(device)
        feat = model.encode_image(x).float()
        feat = feat / feat.norm(dim=-1, keepdim=True).clamp_min(1e-8)
        out.append(feat.cpu())
    return torch.cat(out, dim=0).numpy()


# ──────────────────────────────────────────────────────────────────────
# CLIPArTT loss — transductive top-k InfoNCE
# ──────────────────────────────────────────────────────────────────────
def clipartt_loss(
    target_feat: torch.Tensor,     # [B, D] adapter-projected target features
    class_protos: torch.Tensor,    # [C, D] adapter-projected class prototypes
    pseudo_topk: torch.Tensor,     # [B, K] indices of top-k pseudo classes (from frozen CLIP)
    logit_scale: torch.Tensor,     # scalar param
) -> torch.Tensor:
    """For each target sample b:
        positive set  = its top-k pseudo classes (soft label over k entries)
        negative set  = all other classes
    Compute NCE over class prototypes.
    """
    scale = logit_scale.exp().clamp(max=100.0)
    logits = scale * target_feat @ class_protos.t()  # [B, C]
    log_prob = F.log_softmax(logits, dim=-1)         # [B, C]
    # Soft target: uniform over top-k
    B, K = pseudo_topk.shape
    soft_target = torch.zeros_like(logits)
    soft_target.scatter_(1, pseudo_topk, 1.0 / K)
    loss = -(soft_target * log_prob).sum(dim=-1).mean()
    return loss


# ──────────────────────────────────────────────────────────────────────
# Class prototype builder — average per class
# ──────────────────────────────────────────────────────────────────────
def build_class_protos(embs: np.ndarray, labels: List[str]) -> Tuple[np.ndarray, List[str]]:
    by: dict[str, List[np.ndarray]] = {}
    for e, lab in zip(embs, labels):
        by.setdefault(lab, []).append(e)
    classes = sorted(by.keys())
    protos = np.stack([np.mean(by[c], axis=0) for c in classes]).astype(np.float32)
    protos /= np.linalg.norm(protos, axis=-1, keepdims=True).clip(min=1e-8)
    return protos, classes


# ──────────────────────────────────────────────────────────────────────
# Retrieval metric — top-1 / top-5 against class prototypes
# ──────────────────────────────────────────────────────────────────────
def retrieval_topk(target_embs: np.ndarray, target_labels: List[str],
                   protos: np.ndarray, classes: List[str], ks=(1, 5)) -> dict:
    sims = target_embs @ protos.T  # [N, C]
    cls_idx = {c: i for i, c in enumerate(classes)}
    out = {}
    for k in ks:
        topk = np.argpartition(-sims, kth=min(k, sims.shape[1] - 1), axis=1)[:, :k]
        hits = 0
        for i, lab in enumerate(target_labels):
            if lab not in cls_idx:
                continue
            if cls_idx[lab] in topk[i]:
                hits += 1
        out[f"top{k}"] = hits / max(1, len(target_labels))
    out["avg_max_sim"] = float(np.mean(sims.max(axis=1)))
    out["sim_histogram"] = histogram(sims.max(axis=1))
    return out


def histogram(values: np.ndarray, bins=(0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.01)) -> dict:
    edges = np.array(bins)
    counts, _ = np.histogram(values, bins=np.concatenate([[-1.0], edges]))
    labels = [f"<{edges[0]:.2f}"] + [f"{edges[i-1]:.2f}-{edges[i]:.2f}" for i in range(1, len(edges))]
    return dict(zip(labels, counts.tolist()))


# ──────────────────────────────────────────────────────────────────────
# Build target set — either real-world photos or augmented hold-out
# ──────────────────────────────────────────────────────────────────────
def find_real_photos(root: Path, manifest: dict) -> List[Tuple[Path, str]]:
    """Look for files in <root>/<brand>/*.jpg|.png|.webp.
    Returns list of (path, class_label). class_label here is the brand
    (since we don't have per-photo device names in raw uploads). That
    means retrieval evaluation against device-name protos won't be
    meaningful unless filenames encode the device — best-effort for now.
    """
    if not root.exists():
        return []
    found = []
    for brand_dir in root.iterdir():
        if not brand_dir.is_dir():
            continue
        for p in brand_dir.iterdir():
            if p.suffix.lower() in (".jpg", ".jpeg", ".png", ".webp"):
                found.append((p, brand_dir.name))
    return found


def stratified_holdout(catalog_paths: List[Path], catalog_labels: List[str],
                       fraction: float, seed: int) -> Tuple[List[int], List[int]]:
    """Returns (train_idx, holdout_idx). Stratified per class.
    Class with only one image stays in train (can't hold it out
    or there'd be no prototype to retrieve against)."""
    rng = random.Random(seed)
    by_class: dict[str, List[int]] = {}
    for i, lab in enumerate(catalog_labels):
        by_class.setdefault(lab, []).append(i)
    train, hold = [], []
    for lab, idxs in by_class.items():
        if len(idxs) < 2:
            train.extend(idxs)
            continue
        rng.shuffle(idxs)
        n_hold = max(1, int(round(len(idxs) * fraction)))
        # Never hold out ALL of a class
        n_hold = min(n_hold, len(idxs) - 1)
        hold.extend(idxs[:n_hold])
        train.extend(idxs[n_hold:])
    return train, hold


# ──────────────────────────────────────────────────────────────────────
# Main pipeline
# ──────────────────────────────────────────────────────────────────────
def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=Config.epochs)
    parser.add_argument("--lr", type=float, default=Config.lr)
    parser.add_argument("--topk", type=int, default=Config.topk_pseudo)
    parser.add_argument("--batch-size", type=int, default=Config.batch_size)
    parser.add_argument("--holdout", type=float, default=Config.holdout_fraction)
    parser.add_argument("--seed", type=int, default=Config.seed)
    parser.add_argument("--augment", choices=["heavy", "light", "none"], default=Config.augment_strength)
    parser.add_argument("--real-photos", type=str, default=None,
                        help="Path to <root>/<brand>/*.jpg real-world photo dir")
    args = parser.parse_args()

    cfg = Config(
        seed=args.seed,
        holdout_fraction=args.holdout,
        topk_pseudo=args.topk,
        epochs=args.epochs,
        batch_size=args.batch_size,
        lr=args.lr,
        augment_strength=args.augment,
        real_photos_dir=args.real_photos,
    )
    seed_everything(cfg.seed)

    device = "mps" if torch.backends.mps.is_available() else "cpu"

    print("🎯 CLIPArTT Test-Time Adaptation")
    print("=" * 60)
    print(f"Config: {asdict(cfg)}")
    print(f"Device: {device}")
    print()

    # ─── Load catalog and resolve image paths ──────────────────────────
    client = chromadb.PersistentClient(path=str(CHROMA_DIR))
    print("📚 Loading catalog from ChromaDB...")
    cat_embs_orig, cat_ids, cat_metas, cat_labels = load_catalog(client)
    print(f"   {len(cat_ids)} catalog embeddings, {len(set(cat_labels))} unique classes")

    cat_paths: List[Path] = []
    valid_mask: List[bool] = []
    for m in cat_metas:
        p = IMAGE_DIR / m["local_path"]
        ok = p.exists() and p.stat().st_size > 0
        cat_paths.append(p)
        valid_mask.append(ok)
    n_valid = sum(valid_mask)
    if n_valid != len(cat_metas):
        print(f"   ⚠️  {len(cat_metas) - n_valid} catalog images missing on disk; keeping embeddings only for those.")

    # ─── Decide target source ─────────────────────────────────────────
    target_label = "real_world"
    target_pairs: List[Tuple[Path, str]] = []
    if cfg.real_photos_dir:
        target_pairs = find_real_photos(Path(cfg.real_photos_dir), {})
    if not target_pairs:
        target_label = "synthetic_augmented_holdout"
        print()
        print("⚠️  No real-world target photos found.")
        print("    Falling back to augmented hold-out of the catalog as a")
        print("    synthetic stand-in for the target distribution. This is a")
        print("    KNOWN LIMITATION — flagged in the report.")

    # ─── Build hold-out from catalog (always needed for evaluation) ───
    valid_idx = [i for i, ok in enumerate(valid_mask) if ok]
    valid_paths = [cat_paths[i] for i in valid_idx]
    valid_labels = [cat_labels[i] for i in valid_idx]
    valid_embs = cat_embs_orig[valid_idx]

    train_pos, hold_pos = stratified_holdout(valid_paths, valid_labels, cfg.holdout_fraction, cfg.seed)
    train_paths = [valid_paths[i] for i in train_pos]
    train_labels = [valid_labels[i] for i in train_pos]
    train_embs = valid_embs[train_pos]
    hold_paths = [valid_paths[i] for i in hold_pos]
    hold_labels = [valid_labels[i] for i in hold_pos]

    print(f"   hold-out: {len(hold_paths)}  /  train: {len(train_paths)}")

    # ─── CLIP model ───────────────────────────────────────────────────
    model, preprocess = load_clip(cfg, device)

    # ─── Encode held-out images twice: clean (oracle) + augmented (target) ───
    print()
    print("🔮 Encoding held-out set (clean + augmented) ...")
    hold_clean = encode_images(model, preprocess, hold_paths, device, augment=False)
    hold_aug = encode_images(model, preprocess, hold_paths, device,
                             augment=True, aug_strength=cfg.augment_strength, aug_seed=cfg.seed)

    # If real photos were provided, prefer them as the target set for training
    if target_label == "real_world":
        print(f"🌍 Using {len(target_pairs)} real-world target photos for adaptation.")
        target_paths = [p for p, _ in target_pairs]
        target_feats = encode_images(model, preprocess, target_paths, device, augment=False)
    else:
        # Use the augmented hold-out as the target set (transductive)
        target_feats = hold_aug
        print(f"🧪 Using {len(target_feats)} augmented hold-out images as the target set.")

    # Class prototypes from the TRAIN portion only (so hold-out classes can still
    # be evaluated as long as ≥1 train image per class exists, which the
    # stratified split guarantees).
    protos_orig, classes = build_class_protos(train_embs, train_labels)
    print(f"   {len(classes)} class prototypes from {len(train_embs)} train embeddings")

    # ─── BEFORE: retrieval metrics on augmented hold-out using ORIGINAL embeddings ───
    print()
    print("📊 BEFORE adaptation:")
    before = retrieval_topk(hold_aug, hold_labels, protos_orig, classes)
    print(f"   top-1: {before['top1']:.3f}   top-5: {before['top5']:.3f}   avg-max-sim: {before['avg_max_sim']:.3f}")
    before_clean = retrieval_topk(hold_clean, hold_labels, protos_orig, classes)
    print(f"   (sanity: clean hold-out top-1 {before_clean['top1']:.3f}, avg-sim {before_clean['avg_max_sim']:.3f})")

    # ─── Build pseudo-labels for target features (top-k against ORIGINAL protos) ───
    target_t = torch.from_numpy(target_feats).to(device)
    protos_t = torch.from_numpy(protos_orig).to(device)
    train_t = torch.from_numpy(train_embs).to(device)

    sims = target_t @ protos_t.T
    topk_idx = sims.topk(cfg.topk_pseudo, dim=-1).indices  # [N_target, K]

    # ─── Adapter + optimiser ──────────────────────────────────────────
    adapter = ResidualAdapter(dim=cat_embs_orig.shape[1]).to(device)
    optim = torch.optim.AdamW(adapter.parameters(), lr=cfg.lr, weight_decay=cfg.weight_decay)

    print()
    print("🏋️  Training adapter ...")
    n_target = target_t.shape[0]
    history = []
    for ep in range(cfg.epochs):
        adapter.train()
        # Shuffle target indices
        perm = torch.randperm(n_target, generator=torch.Generator().manual_seed(cfg.seed + ep))
        epoch_loss = 0.0
        n_batches = 0
        for i in range(0, n_target, cfg.batch_size):
            b_idx = perm[i:i + cfg.batch_size]
            b_target = target_t[b_idx]
            b_topk = topk_idx[b_idx]

            # Adapter applied to TARGETS and to all TRAIN embeddings, then re-pool to protos
            proj_target = adapter(b_target)
            proj_train = adapter(train_t)
            # Rebuild protos in projected space
            with torch.no_grad():
                proto_buckets = {}
                for j, lab in enumerate(train_labels):
                    proto_buckets.setdefault(lab, []).append(j)
            # Avoid Python loop in inner step: precompute index tensor once
            # (small enough: a few hundred classes × few images each)
            proj_protos = torch.stack([
                proj_train[proto_buckets[c]].mean(dim=0) for c in classes
            ])
            proj_protos = proj_protos / proj_protos.norm(dim=-1, keepdim=True).clamp_min(1e-8)

            loss = clipartt_loss(proj_target, proj_protos, b_topk, adapter.logit_scale)

            optim.zero_grad()
            loss.backward()
            optim.step()
            epoch_loss += loss.item()
            n_batches += 1

        avg = epoch_loss / max(1, n_batches)
        history.append({"epoch": ep + 1, "loss": avg})
        if ep == 0 or (ep + 1) % 5 == 0 or ep == cfg.epochs - 1:
            print(f"   epoch {ep + 1:3d}/{cfg.epochs}  loss={avg:.4f}  logit_scale={adapter.logit_scale.exp().item():.2f}")

    # ─── Apply adapter to FULL catalog and rebuild protos ─────────────
    adapter.eval()
    with torch.no_grad():
        cat_t = torch.from_numpy(cat_embs_orig).to(device)
        cat_adapted = adapter(cat_t).cpu().numpy()
        # Also adapt the train embeddings → new protos
        train_adapted = adapter(train_t).cpu().numpy()
    protos_adapted, _ = build_class_protos(train_adapted, train_labels)

    # ─── AFTER: retrieval metrics ─────────────────────────────────────
    with torch.no_grad():
        hold_aug_adapted = adapter(torch.from_numpy(hold_aug).to(device)).cpu().numpy()
    after = retrieval_topk(hold_aug_adapted, hold_labels, protos_adapted, classes)
    print()
    print("📊 AFTER adaptation:")
    print(f"   top-1: {after['top1']:.3f}   top-5: {after['top5']:.3f}   avg-max-sim: {after['avg_max_sim']:.3f}")

    delta_top1 = after["top1"] - before["top1"]
    delta_top5 = after["top5"] - before["top5"]
    delta_sim = after["avg_max_sim"] - before["avg_max_sim"]
    print(f"   Δ top-1: {delta_top1:+.3f}   Δ top-5: {delta_top5:+.3f}   Δ avg-sim: {delta_sim:+.3f}")

    # ─── Persist adapter weights ──────────────────────────────────────
    PROCESSED_DIR.mkdir(exist_ok=True)
    torch.save({
        "state_dict": adapter.state_dict(),
        "config": asdict(cfg),
        "before": before,
        "after": after,
    }, ADAPTER_PATH)
    print(f"💾 Adapter saved to {ADAPTER_PATH}")

    # ─── Write adapted ChromaDB collection (parallel; never touch original) ───
    print()
    print(f"🗄️  Writing adapted catalog → '{ADAPTED_COLLECTION}' (original '{SOURCE_COLLECTION}' untouched)")
    try:
        client.delete_collection(ADAPTED_COLLECTION)
    except Exception:
        pass
    adapted = client.create_collection(
        name=ADAPTED_COLLECTION,
        metadata={
            "description": "CLIPArTT-adapted visual embeddings for hearing aid scanner (test-time adapter, transductive top-k pseudo-labels)",
            "model": f"{cfg.model_name} ({cfg.pretrained}) + ResidualAdapter",
            "dimensions": str(cat_adapted.shape[1]),
            "hnsw:space": "cosine",
            "source_collection": SOURCE_COLLECTION,
            "config": json.dumps(asdict(cfg)),
        },
    )
    BATCH = 500
    for i in range(0, len(cat_ids), BATCH):
        adapted.add(
            ids=cat_ids[i:i + BATCH],
            embeddings=cat_adapted[i:i + BATCH].tolist(),
            metadatas=cat_metas[i:i + BATCH],
        )
    print(f"   ✅ adapted collection has {adapted.count()} embeddings")

    # ─── Report ───────────────────────────────────────────────────────
    write_report(cfg, before, before_clean, after, history, target_label,
                 len(target_feats), len(classes), len(train_paths), len(hold_paths),
                 delta_top1, delta_top5, delta_sim)
    print(f"📝 Report written to {REPORT_PATH}")

    # ─── Honest accounting ────────────────────────────────────────────
    if delta_top1 < -0.005:
        print()
        print("⚠️  Adaptation REDUCED top-1 accuracy. Reporting as-is.")
        print("    Next-step candidate: LoRA fine-tune of the CLIP image tower")
        print("    (see task #15 in the project tracker).")

    return 0


# ──────────────────────────────────────────────────────────────────────
# Report writer
# ──────────────────────────────────────────────────────────────────────
def write_report(cfg: Config, before: dict, before_clean: dict, after: dict,
                 history: list, target_label: str, n_target: int, n_classes: int,
                 n_train: int, n_holdout: int,
                 d_top1: float, d_top5: float, d_sim: float) -> None:
    lines = []
    lines.append("# CLIPArTT Test-Time Adaptation Report")
    lines.append("")
    lines.append(f"_Generated by `data/clipartt_adaptation.py`._")
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    lines.append("| Metric | Before | After | Δ |")
    lines.append("|---|---:|---:|---:|")
    lines.append(f"| Top-1 retrieval accuracy (augmented hold-out) | {before['top1']:.3f} | {after['top1']:.3f} | {d_top1:+.3f} |")
    lines.append(f"| Top-5 retrieval accuracy (augmented hold-out) | {before['top5']:.3f} | {after['top5']:.3f} | {d_top5:+.3f} |")
    lines.append(f"| Avg max cosine similarity                     | {before['avg_max_sim']:.3f} | {after['avg_max_sim']:.3f} | {d_sim:+.3f} |")
    lines.append("")
    lines.append(f"Sanity check: top-1 on the *clean* hold-out (no augmentation) against")
    lines.append(f"the original CLIP embeddings is **{before_clean['top1']:.3f}** with")
    lines.append(f"avg-sim **{before_clean['avg_max_sim']:.3f}** — this is the upper bound the")
    lines.append("adapter is trying to recover under domain shift.")
    lines.append("")

    if target_label == "synthetic_augmented_holdout":
        lines.append("## ⚠️ Limitation: synthetic target distribution")
        lines.append("")
        lines.append("No real-world hand-held photos were available at `data/real_world_photos/`,")
        lines.append("so this run used a **stratified hold-out of the catalog with heavy")
        lines.append("hand-held-style augmentations** (blur, rotation, perspective, color jitter,")
        lines.append("low-res rescaling, partial occlusion) as a synthetic stand-in for the")
        lines.append("target distribution.")
        lines.append("")
        lines.append("Augmentations approximate, but do NOT replicate, the true domain shift")
        lines.append("(specular highlights on plastic shells, finger occlusions, focus failures,")
        lines.append("warm indoor lighting, real-camera ISP pipelines). The numbers above are an")
        lines.append("**indicative lower-bound** of adapter capability — once Seray drops real")
        lines.append("scanner photos into `data/real_world_photos/<brand>/...` and we rerun, we'll")
        lines.append("get a meaningful estimate.")
    else:
        lines.append("## Target distribution: real-world photos")
        lines.append(f"")
        lines.append(f"{n_target} real-world photos were used as the target set.")
    lines.append("")

    lines.append("## Cosine-similarity histogram (augmented hold-out → nearest class prototype)")
    lines.append("")
    lines.append("| Bin | Before | After |")
    lines.append("|---|---:|---:|")
    for k in before["sim_histogram"]:
        b = before["sim_histogram"].get(k, 0)
        a = after["sim_histogram"].get(k, 0)
        lines.append(f"| {k} | {b} | {a} |")
    lines.append("")

    lines.append("## Hyperparameters (deterministic seed)")
    lines.append("")
    lines.append("```json")
    lines.append(json.dumps(asdict(cfg), indent=2))
    lines.append("```")
    lines.append("")
    lines.append(f"- Train catalog images: **{n_train}**")
    lines.append(f"- Held-out catalog images: **{n_holdout}**")
    lines.append(f"- Target set size: **{n_target}** ({target_label})")
    lines.append(f"- Class prototypes: **{n_classes}** unique device names")
    lines.append("")

    lines.append("## Training loss (per epoch)")
    lines.append("")
    lines.append("| Epoch | Loss |")
    lines.append("|---:|---:|")
    for h in history:
        lines.append(f"| {h['epoch']} | {h['loss']:.4f} |")
    lines.append("")

    lines.append("## What this is and isn't")
    lines.append("")
    lines.append("- This is a **CLIPArTT-inspired lightweight variant**: instead of LoRA on")
    lines.append("  the CLIP image tower, we train a 512×512 residual adapter on top of")
    lines.append("  frozen image embeddings, using transductive top-k pseudo-labels from the")
    lines.append("  unadapted CLIP. Faster to iterate; weaker capacity. If retrieval doesn't")
    lines.append("  recover most of the clean→augmented gap, the next step is a LoRA")
    lines.append("  fine-tune of the image encoder (task #15).")
    lines.append("- The new embeddings are written to ChromaDB collection")
    lines.append(f"  **`{ADAPTED_COLLECTION}`**. The original `{SOURCE_COLLECTION}` is untouched,")
    lines.append("  so the scanner can A/B at query time by switching collections.")
    lines.append("- Adapter weights persisted at `data/processed/clipartt_adapter.pt` so the")
    lines.append("  on-device pipeline (or cloud function) can apply the same projection to")
    lines.append("  query embeddings.")

    REPORT_PATH.write_text("\n".join(lines))


if __name__ == "__main__":
    sys.exit(main())
