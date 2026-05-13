#!/usr/bin/env python3
"""
Train a YOLO-nano hearing-aid brand detector + classifier.

Held in PARALLEL to the existing EfficientNet-B0 brand classifier
(``train_brand_classifier.py``). This does NOT replace it — A/B integration
on-device happens later.

## Why YOLO here

EfficientNet-B0 gives whole-image brand probability. YOLO gives a *bounding
box* per detection, which the scanner already renders as the "hero" demo
moment (see ``feature_overlay_painter.dart``). A real detector (rather than
the OCR-region-derived box currently used) means the box snaps to the
device itself, not to readable text. The on-device pipeline can then
fuse three signals instead of two:

  * OCR + fuzzy brand match    (BrandMatcher)
  * EfficientNet whole-image   (existing TFLite)
  * YOLO box + brand class     (this script)

## Variant choice: yolo11n, not yolov26n

The task brief asked for "YOLOv26-nano". As of ultralytics 8.4.48 (the
version pinned on this machine) the published nano weights are
``yolo11n``; there is no ``yolov26n`` release in the package. We use
``yolo11n.pt`` and document the substitution. When a v26 nano ships,
swap MODEL_VARIANT and retrain — the rest of the pipeline is unchanged.

## Known limitation: proxy bounding boxes

We have brand *classification* labels (folder = brand) but no human-drawn
bounding boxes. For v1 we synthesise a whole-image box per training
image (cx=0.5, cy=0.5, w=1.0, h=1.0). This trains the classifier head
correctly but teaches the detector that "the hearing aid fills the frame"
— which is true of the unaudinary product shots that dominate the dataset
but is NOT true of real hand-held photos. Expect mAP@50 to look healthy
on the val split (same distribution) and degrade significantly on
real-world photos. Real bbox annotations are the obvious follow-up;
``data/preprocess_box_photos.py`` already has a Grounding-DINO-style
auto-labeller scaffolded that would be the right next step.

## Outputs

  * ``data/models/hearing_aid_yolo.mlpackage`` — CoreML for iOS
  * ``data/models/hearing_aid_yolo.pt``        — PyTorch fallback
  * ``data/models/hearing_aid_yolo_labels.json`` — class index → brand name
  * ``data/yolov26_metrics.md``                — real metrics

The .mlpackage and .pt are gitignored (large + regenerable). Only the
labels JSON and metrics markdown are committed.

Usage:
    python3 data/train_yolov26.py                 # full run, 30 epochs
    python3 data/train_yolov26.py --epochs 5      # quick smoke test
    python3 data/train_yolov26.py --no-coreml     # skip CoreML export
"""

from __future__ import annotations

import argparse
import json
import random
import shutil
import sys
import time
from pathlib import Path

# We import ultralytics lazily so --help works without it.

# ---------------------------------------------------------------------------
# Paths. The image data lives in the PARENT repo (not in this worktree) — the
# image_by_brand folder is full of absolute-path symlinks into data/images/
# which is ignored by git. We resolve to the parent repo so the script works
# from any worktree.
# ---------------------------------------------------------------------------

WORKTREE_DATA   = Path(__file__).parent.resolve()
PARENT_REPO     = Path("/Users/nick/git/individuals/seray/recycled-sound")
SOURCE_IMG_ROOT = PARENT_REPO / "data" / "images_by_brand"

YOLO_DATASET    = WORKTREE_DATA / "yolo_dataset"
YOLO_RUNS       = WORKTREE_DATA / "yolo_runs"
MODEL_DIR       = WORKTREE_DATA / "models"
METRICS_MD      = WORKTREE_DATA / "yolov26_metrics.md"

MODEL_VARIANT   = "yolo11n.pt"  # nano, ~5MB, ~3M params
# 320 not 640 — CPU training on M1 Max is ~4x faster at 320. Real-world
# scanner frames are 640px wide but the device occupies a small region;
# the YOLO head will still localise. Bump to 640 once we move off CPU.
IMG_SIZE        = 320
DEFAULT_EPOCHS  = 15
VAL_SPLIT       = 0.20
SEED            = 42

# Brand merges mirror train_brand_classifier.py so the two heads share
# the same label space (important for A/B comparison).
BRAND_ALIASES = {
    "Hansaton": "Signia",
    "Rexton":   "Signia",
    "Jabra":    "ReSound",
    "Specsavers Advance": None,
    "Hearing Australia":  None,
    "Amplifon":           None,
}


def discover_brands() -> dict[str, list[Path]]:
    """Walk source dir, return {canonical_brand: [image_paths]}."""
    if not SOURCE_IMG_ROOT.exists():
        sys.exit(f"FATAL: source images not found at {SOURCE_IMG_ROOT}")

    brand_to_paths: dict[str, list[Path]] = {}
    for brand_dir in sorted(SOURCE_IMG_ROOT.iterdir()):
        if not brand_dir.is_dir():
            continue
        canonical = BRAND_ALIASES.get(brand_dir.name, brand_dir.name)
        if canonical is None:
            continue  # dropped brand
        imgs = [p for p in brand_dir.iterdir()
                if p.suffix.lower() in {".jpg", ".jpeg", ".png", ".webp"}]
        # Skip .avif — ultralytics/PIL can't read it without plugins.
        # Resolve symlinks now so YOLO doesn't choke later.
        imgs = [p.resolve() for p in imgs if p.exists()]
        if not imgs:
            continue
        brand_to_paths.setdefault(canonical, []).extend(imgs)
    return brand_to_paths


def build_yolo_dataset(brand_to_paths: dict[str, list[Path]]) -> tuple[list[str], Path]:
    """Materialise an Ultralytics-format dataset.

    Layout:
        yolo_dataset/
            images/train/*.jpg
            images/val/*.jpg
            labels/train/*.txt   # "<class_id> 0.5 0.5 1.0 1.0"
            labels/val/*.txt
            dataset.yaml
    """
    if YOLO_DATASET.exists():
        shutil.rmtree(YOLO_DATASET)
    for split in ("train", "val"):
        (YOLO_DATASET / "images" / split).mkdir(parents=True)
        (YOLO_DATASET / "labels" / split).mkdir(parents=True)

    classes = sorted(brand_to_paths.keys())
    cls_idx = {c: i for i, c in enumerate(classes)}

    rng = random.Random(SEED)
    counts = {c: {"train": 0, "val": 0} for c in classes}

    for brand, paths in brand_to_paths.items():
        rng.shuffle(paths)
        n_val = max(1, int(len(paths) * VAL_SPLIT))
        for i, src in enumerate(paths):
            split = "val" if i < n_val else "train"
            # Use a unique filename to avoid collisions across brands.
            stem = f"{brand}_{i:05d}{src.suffix.lower()}"
            dst_img = YOLO_DATASET / "images" / split / stem
            try:
                # Hard-link if same filesystem (fast, zero copy); else copy.
                dst_img.symlink_to(src)
            except OSError:
                shutil.copy2(src, dst_img)
            # Whole-image proxy bbox — see module docstring.
            label = YOLO_DATASET / "labels" / split / (Path(stem).stem + ".txt")
            label.write_text(f"{cls_idx[brand]} 0.5 0.5 1.0 1.0\n")
            counts[brand][split] += 1

    yaml_path = YOLO_DATASET / "dataset.yaml"
    yaml_path.write_text(
        f"path: {YOLO_DATASET}\n"
        "train: images/train\n"
        "val: images/val\n"
        f"nc: {len(classes)}\n"
        f"names: {classes}\n"
    )

    print(f"[dataset] {sum(c['train']+c['val'] for c in counts.values())} images, "
          f"{len(classes)} classes")
    for c in classes:
        print(f"  {c:12s} train={counts[c]['train']:4d} val={counts[c]['val']:4d}")
    return classes, yaml_path


def train(yaml_path: Path, epochs: int) -> "YOLO":  # noqa: F821
    from ultralytics import YOLO
    model = YOLO(MODEL_VARIANT)
    print(f"[train] {MODEL_VARIANT}, {epochs} epochs, imgsz={IMG_SIZE}")
    model.train(
        data=str(yaml_path),
        epochs=epochs,
        imgsz=IMG_SIZE,
        batch=16,
        project=str(YOLO_RUNS),
        name="brand",
        exist_ok=True,
        verbose=True,
        seed=SEED,
        # Augmentations — modest because the proxy bboxes can't survive
        # heavy geometric warps without becoming wrong.
        mosaic=0.5,
        mixup=0.0,
        degrees=5.0,
        translate=0.05,
        scale=0.2,
        shear=0.0,
        fliplr=0.5,
        # Disable training plots/wandb — keep output tidy.
        plots=False,
    )
    return model


def evaluate(model, classes: list[str]) -> dict:
    """Return per-brand and overall mAP."""
    metrics = model.val(verbose=False)
    out = {
        "mAP50":     float(metrics.box.map50),
        "mAP50_95":  float(metrics.box.map),
        "per_class": {},
    }
    # Ultralytics returns mAP arrays indexed by class id.
    try:
        maps = metrics.box.maps  # mAP50-95 per class
        for i, c in enumerate(classes):
            out["per_class"][c] = float(maps[i])
    except Exception as e:  # noqa: BLE001
        out["per_class_error"] = str(e)
    return out


def measure_latency(model, classes: list[str], n: int = 20) -> dict:
    """Single-image inference latency on a handful of val images."""
    val_imgs = list((YOLO_DATASET / "images" / "val").glob("*"))[:n]
    if not val_imgs:
        return {"error": "no val images"}
    # Warm up.
    model.predict(str(val_imgs[0]), verbose=False)
    t0 = time.perf_counter()
    for p in val_imgs:
        model.predict(str(p), verbose=False)
    dt = time.perf_counter() - t0
    return {"n": len(val_imgs), "ms_per_image": (dt / len(val_imgs)) * 1000.0}


def export_models(model, want_coreml: bool) -> dict:
    MODEL_DIR.mkdir(exist_ok=True)
    out = {}

    # PyTorch weights — the source of truth, easy to re-export.
    pt_src = Path(model.trainer.best) if hasattr(model, "trainer") else None
    if pt_src and pt_src.exists():
        pt_dst = MODEL_DIR / "hearing_aid_yolo.pt"
        shutil.copy2(pt_src, pt_dst)
        out["pt"] = {"path": str(pt_dst), "size_mb": pt_dst.stat().st_size / 1e6}

    if want_coreml:
        try:
            coreml_path = model.export(format="coreml", imgsz=IMG_SIZE, nms=True)
            src = Path(coreml_path)
            dst = MODEL_DIR / "hearing_aid_yolo.mlpackage"
            if dst.exists():
                shutil.rmtree(dst) if dst.is_dir() else dst.unlink()
            shutil.move(str(src), str(dst))
            # mlpackage is a directory; sum its sizes.
            size = sum(p.stat().st_size for p in dst.rglob("*") if p.is_file())
            out["coreml"] = {"path": str(dst), "size_mb": size / 1e6}
        except Exception as e:  # noqa: BLE001
            out["coreml_error"] = str(e)

    return out


def write_metrics_md(classes: list[str], metrics: dict, latency: dict,
                     export: dict, epochs: int) -> None:
    lines = [
        "# YOLO-nano hearing-aid detector — metrics",
        "",
        "Trained in parallel to the existing EfficientNet-B0 brand classifier.",
        "Held for on-device A/B integration — the EfficientNet head is NOT",
        "being replaced by this run.",
        "",
        "## Run config",
        "",
        f"- Variant: `{MODEL_VARIANT}` (substituted for the unreleased `yolov26n`)",
        f"- Epochs: {epochs}",
        f"- Image size: {IMG_SIZE}",
        f"- Val split: {VAL_SPLIT*100:.0f}%",
        f"- Classes ({len(classes)}): {', '.join(classes)}",
        "",
        "## Known limitation: proxy bounding boxes",
        "",
        "We have brand-classification labels but no human-drawn bounding boxes.",
        "Every training image gets a whole-image bbox (cx=0.5, cy=0.5, w=h=1.0).",
        "This trains the classifier head correctly but teaches the detector that",
        "the device fills the frame — true of the unaudinary product shots but",
        "NOT of real hand-held photos. Expect strong val mAP and weaker",
        "real-world performance until proper bbox annotations exist.",
        "",
        "## Overall metrics",
        "",
        f"- mAP@50:    **{metrics['mAP50']:.4f}**",
        f"- mAP@50-95: **{metrics['mAP50_95']:.4f}**",
        "",
        "## Per-class mAP@50-95",
        "",
        "| Brand | mAP@50-95 |",
        "|-------|----------:|",
    ]
    per = metrics.get("per_class", {})
    for c in classes:
        v = per.get(c)
        lines.append(f"| {c} | {v:.4f} |" if isinstance(v, float) else f"| {c} | n/a |")

    lines += [
        "",
        "## Latency",
        "",
        f"- Samples: {latency.get('n', 0)}",
        f"- Mean ms/image (CPU/MPS local, single-batch): "
        f"**{latency.get('ms_per_image', 0):.1f} ms**",
        "",
        "## Exports",
        "",
    ]
    if "pt" in export:
        lines.append(f"- PyTorch: `{export['pt']['path']}` "
                     f"({export['pt']['size_mb']:.2f} MB)")
    if "coreml" in export:
        lines.append(f"- CoreML:  `{export['coreml']['path']}` "
                     f"({export['coreml']['size_mb']:.2f} MB)")
    if "coreml_error" in export:
        lines.append(f"- CoreML export FAILED: `{export['coreml_error']}`")

    lines += [
        "",
        "## Next steps",
        "",
        "1. Real bbox annotations (Grounding-DINO auto-label, then human triage).",
        "2. On-device A/B: load `hearing_aid_yolo.mlpackage` alongside the existing",
        "   EfficientNet TFLite. Compare brand top-1 on the 12-photo Seray set.",
        "3. Only after A/B win on real photos: replace the OCR-derived bbox in",
        "   `feature_overlay_painter.dart` with YOLO's box (the demo \"hero moment\").",
        "",
    ]
    METRICS_MD.write_text("\n".join(lines))
    print(f"[metrics] wrote {METRICS_MD}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--epochs", type=int, default=DEFAULT_EPOCHS)
    ap.add_argument("--no-coreml", action="store_true",
                    help="Skip CoreML export (useful for quick smoke tests).")
    args = ap.parse_args()

    print(f"[discover] scanning {SOURCE_IMG_ROOT}")
    brand_to_paths = discover_brands()
    classes, yaml_path = build_yolo_dataset(brand_to_paths)

    # Persist the label list — Swift side will read this to map class ids.
    MODEL_DIR.mkdir(exist_ok=True)
    (MODEL_DIR / "hearing_aid_yolo_labels.json").write_text(
        json.dumps({"classes": classes,
                    "variant": MODEL_VARIANT,
                    "imgsz": IMG_SIZE}, indent=2)
    )

    model   = train(yaml_path, args.epochs)
    metrics = evaluate(model, classes)
    latency = measure_latency(model, classes)
    export  = export_models(model, want_coreml=not args.no_coreml)
    write_metrics_md(classes, metrics, latency, export, args.epochs)

    print("[done]")
    print(json.dumps({"metrics": metrics, "latency": latency, "export": export},
                     indent=2, default=str))


if __name__ == "__main__":
    main()
