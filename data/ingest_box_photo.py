#!/usr/bin/env python3
"""
End-to-end box-rig photo ingestion.

Takes a single hearing aid photo captured inside Seray's clear plastic
storage box (see docs/box-photo-capture-guide.md) and runs it through
the full data pipeline so it lands in every downstream consumer:

  1. Preprocess via preprocess_box_photos.process_image
       → perspective-corrected + white-balanced 448x448 crop
       → saved to data/images_box/<brand>/
  2. Append to training corpus at data/images_by_brand/<brand>/
       (matches symlink convention used by train_brand_classifier.py;
        '_box' suffix so the existing _filter_box_photos() helper still
        recognises these as box photos)
  3. Update ChromaDB 'hearing_aids_visual' collection with a CLIP
     embedding of the perspective-corrected crop
  4. (Optional, --test-reference) copy into data/test_reference/<brand>/
     so test_pipeline.py picks it up via folder mode

Idempotency: a SHA-256 of the source photo is recorded in
data/box_ingest_manifest.json. Re-running on the same photo (by hash)
is a no-op for the corpus + embedding stages.

Usage:
  python3 data/ingest_box_photo.py <photo_path> --brand <brand> \\
      --model <model> [--test-reference] [--dry-run]

Example:
  python3 data/ingest_box_photo.py ~/Desktop/box07.jpg \\
      --brand Oticon --model "Nera2 Pro" --test-reference

Hard constraints honored:
  - Does not modify preprocess_box_photos.py
  - Append/update only; never deletes existing corpus entries
  - No new heavy dependencies beyond what siblings already use
    (cv2, numpy, PIL, open_clip, torch, chromadb)
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

# Reuse the existing preprocessor without modifying its contract.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import preprocess_box_photos as pbp  # noqa: E402

DATA_DIR = Path(__file__).resolve().parent
CHROMA_DIR = DATA_DIR / "chroma_db"
IMAGES_BOX_DIR = DATA_DIR / "images_box"
ORGANISED_DIR = DATA_DIR / "images_by_brand"
TEST_REFERENCE_DIR = DATA_DIR / "test_reference"
MANIFEST_PATH = DATA_DIR / "box_ingest_manifest.json"

CLIP_MODEL_NAME = "ViT-B-32"
CLIP_PRETRAINED = "laion2b_s34b_b79k"
VISUAL_COLLECTION = "hearing_aids_visual"


# ─── Helpers ─────────────────────────────────────────────────────


def _safe_token(text: str) -> str:
    """Lowercase, alnum-only token suitable for filenames."""
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _load_manifest() -> dict:
    """Manifest schema: {"entries": {<sha256>: {brand, model, timestamp, paths}}}"""
    if MANIFEST_PATH.exists():
        try:
            with open(MANIFEST_PATH) as f:
                data = json.load(f)
                if isinstance(data, dict) and "entries" in data:
                    return data
        except (json.JSONDecodeError, OSError):
            pass
    return {"entries": {}}


def _save_manifest(manifest: dict) -> None:
    MANIFEST_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(MANIFEST_PATH, "w") as f:
        json.dump(manifest, f, indent=2, sort_keys=True)


# ─── Stage 1: Preprocess ─────────────────────────────────────────


def stage_preprocess(photo_path: Path, brand: str, base_stem: str):
    """Run the existing box preprocessor; write outputs to images_box/<brand>/.

    Returns dict with paths to the written original/rectified/wb-corrected
    crops, plus the rectified BGR ndarray for downstream embedding.
    """
    result = pbp.process_image(photo_path, visualise=False)
    if result is None:
        return None
    original, rectified, wb_corrected, _vis, metadata = result

    brand_dir = IMAGES_BOX_DIR / brand
    brand_dir.mkdir(parents=True, exist_ok=True)

    paths = {
        "original": brand_dir / f"{base_stem}.jpg",
        "rect": brand_dir / f"{base_stem}_rect.jpg",
        "wb": brand_dir / f"{base_stem}_wb.jpg",
    }

    import cv2  # imported by preprocess_box_photos already
    cv2.imwrite(str(paths["original"]), original)
    cv2.imwrite(str(paths["rect"]), rectified)
    cv2.imwrite(str(paths["wb"]), wb_corrected)

    return {
        "paths": paths,
        "rectified_bgr": rectified,
        "wb_corrected_bgr": wb_corrected,
        "metadata": metadata,
    }


# ─── Stage 2: Training corpus ────────────────────────────────────


def stage_append_to_corpus(brand: str, image_paths: dict, base_stem: str) -> list[Path]:
    """Copy box outputs into images_by_brand/<brand>/ with '_box' suffix.

    train_brand_classifier.py rebuilds symlinks from product images on
    each run, but box images live alongside as real files (or symlinks)
    with '_box' in the name so they survive the rebuild. We copy rather
    than symlink to make the corpus robust to source moves.
    """
    dest_dir = ORGANISED_DIR / brand
    dest_dir.mkdir(parents=True, exist_ok=True)

    added: list[Path] = []
    for kind, src in image_paths.items():
        # Use the wb-corrected variant as canonical for training (best
        # colour normalisation), rect as a second sample, skip original
        # (raw box photo has too much background for the classifier).
        if kind == "original":
            continue
        suffix = "_box" if kind == "rect" else "_box_wb"
        dest = dest_dir / f"{base_stem}{suffix}.jpg"
        if dest.exists():
            # Idempotent: same hash + brand → already there.
            continue
        shutil.copy2(src, dest)
        added.append(dest)
    return added


# ─── Stage 3: ChromaDB embedding ─────────────────────────────────


def _open_clip_model():
    import open_clip
    import torch

    model, _, preprocess = open_clip.create_model_and_transforms(
        CLIP_MODEL_NAME, pretrained=CLIP_PRETRAINED,
    )
    model.eval()
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model = model.to(device)
    return model, preprocess, device, torch


def stage_update_embedding(
    rect_path: Path,
    brand: str,
    model_name: str,
    photo_hash: str,
) -> Optional[dict]:
    """Encode the rectified crop with CLIP and upsert into ChromaDB.

    Returns None if ChromaDB / open_clip aren't available — the caller
    treats that as a stage-skipped (not a hard failure) so the CLI can
    still complete the corpus + manifest stages on a fresh checkout
    without the build artifacts.
    """
    try:
        import chromadb  # type: ignore
    except ImportError:
        return {"skipped": "chromadb not installed"}

    if not CHROMA_DIR.exists():
        return {"skipped": f"{CHROMA_DIR} missing (run build_visual_embeddings.py first)"}

    try:
        clip_model, preprocess, device, torch = _open_clip_model()
    except ImportError:
        return {"skipped": "open_clip / torch not installed"}

    from PIL import Image
    img = Image.open(rect_path).convert("RGB")
    img_tensor = preprocess(img).unsqueeze(0).to(device)
    with torch.no_grad():
        embedding = clip_model.encode_image(img_tensor)
        embedding = embedding / embedding.norm(dim=-1, keepdim=True)
    vec = embedding.cpu().numpy().tolist()[0]

    client = chromadb.PersistentClient(path=str(CHROMA_DIR))
    try:
        collection = client.get_collection(VISUAL_COLLECTION)
    except Exception:
        collection = client.get_or_create_collection(
            name=VISUAL_COLLECTION,
            metadata={"hnsw:space": "cosine"},
        )

    # Use the photo hash as the deterministic doc id → re-running is a
    # true upsert (no duplicate embeddings).
    doc_id = f"box_ingest_{photo_hash[:16]}"
    name = f"{brand} {model_name}".strip()
    metadata = {
        "image_url": f"local://box_ingest/{doc_id}",
        "local_path": str(rect_path.relative_to(DATA_DIR)),
        "name": name,
        "manufacturer": brand,
        "model": model_name,
        "style": "",
        "technology_tier": "",
        "linked_device_count": "1",
        "all_device_names": name,
        "source": "box_ingest",
    }
    document = f"{brand} {model_name} — box-rig capture"

    collection.upsert(
        ids=[doc_id],
        embeddings=[vec],
        metadatas=[metadata],
        documents=[document],
    )

    return {
        "collection": VISUAL_COLLECTION,
        "doc_id": doc_id,
        "count_after": collection.count(),
    }


# ─── Stage 4: Test reference set ─────────────────────────────────


def stage_test_reference(image_paths: dict, brand: str, base_stem: str) -> Optional[Path]:
    dest_dir = TEST_REFERENCE_DIR / brand
    dest_dir.mkdir(parents=True, exist_ok=True)
    # Use the rectified crop — it's the version test_pipeline.py would
    # see if Seray captured a fresh photo against the same rig.
    dest = dest_dir / f"{base_stem}_rect.jpg"
    if dest.exists():
        return None  # idempotent
    shutil.copy2(image_paths["rect"], dest)
    return dest


# ─── Orchestration ───────────────────────────────────────────────


def ingest(
    photo_path: Path,
    brand: str,
    model: str,
    test_reference: bool = False,
    dry_run: bool = False,
) -> dict:
    if not photo_path.is_file():
        raise FileNotFoundError(f"Photo not found: {photo_path}")

    # Preserve caller's casing — existing brand folders use mixed case
    # (e.g. "ReSound", "GN Resound") that .title() would mangle.
    brand_clean = brand.strip()
    model_clean = model.strip()
    photo_hash = _sha256(photo_path)
    short_hash = photo_hash[:8]
    base_stem = f"box_ingest_{short_hash}_{_safe_token(brand_clean)}_{_safe_token(model_clean)}"

    manifest = _load_manifest()
    already_ingested = photo_hash in manifest["entries"]

    summary = {
        "photo": str(photo_path),
        "photo_hash": photo_hash,
        "brand": brand_clean,
        "model": model_clean,
        "base_stem": base_stem,
        "already_ingested": already_ingested,
        "stages": {},
    }

    if dry_run:
        summary["dry_run"] = True
        return summary

    # Stage 1 — preprocess. Run even when already ingested so we can
    # repair missing outputs, but skip the file-write if the rect crop
    # already exists.
    rect_target = IMAGES_BOX_DIR / brand_clean / f"{base_stem}_rect.jpg"
    if rect_target.exists():
        preprocess_result = {
            "paths": {
                "original": IMAGES_BOX_DIR / brand_clean / f"{base_stem}.jpg",
                "rect": rect_target,
                "wb": IMAGES_BOX_DIR / brand_clean / f"{base_stem}_wb.jpg",
            },
            "rectified_bgr": None,
            "wb_corrected_bgr": None,
            "metadata": {"reused": True},
        }
        summary["stages"]["preprocess"] = {"reused_existing": True, "rect": str(rect_target)}
    else:
        preprocess_result = stage_preprocess(photo_path, brand_clean, base_stem)
        if preprocess_result is None:
            raise RuntimeError(
                "Box detection failed on this photo. Re-shoot per "
                "docs/box-photo-capture-guide.md (box flat, all 4 corners visible)."
            )
        summary["stages"]["preprocess"] = {
            "wrote": [str(p) for p in preprocess_result["paths"].values()],
            "white_balance_scale": preprocess_result["metadata"]["white_balance_scale"],
        }

    # Stage 2 — corpus append
    added = stage_append_to_corpus(brand_clean, preprocess_result["paths"], base_stem)
    summary["stages"]["corpus"] = {
        "added": [str(p) for p in added],
        "brand_dir": str(ORGANISED_DIR / brand_clean),
    }

    # Stage 3 — embedding upsert
    embedding_result = stage_update_embedding(
        preprocess_result["paths"]["rect"], brand_clean, model_clean, photo_hash,
    )
    summary["stages"]["embedding"] = embedding_result or {"skipped": "unknown"}

    # Stage 4 — test reference (optional)
    if test_reference:
        ref_path = stage_test_reference(preprocess_result["paths"], brand_clean, base_stem)
        summary["stages"]["test_reference"] = {
            "path": str(ref_path) if ref_path else None,
            "skipped_existing": ref_path is None,
        }

    # Manifest update — record once, even if re-running (refresh timestamp
    # only on first ingest so we preserve audit trail).
    if not already_ingested:
        manifest["entries"][photo_hash] = {
            "brand": brand_clean,
            "model": model_clean,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "source_path": str(photo_path),
            "base_stem": base_stem,
        }
        _save_manifest(manifest)
        summary["manifest_updated"] = True
    else:
        summary["manifest_updated"] = False

    return summary


# ─── CLI ─────────────────────────────────────────────────────────


def _print_summary(summary: dict) -> None:
    print()
    print("=" * 60)
    print(f"  Box-rig ingest: {Path(summary['photo']).name}")
    print("=" * 60)
    print(f"  Brand:        {summary['brand']}")
    print(f"  Model:        {summary['model']}")
    print(f"  Photo hash:   {summary['photo_hash'][:16]}...")
    print(f"  Base stem:    {summary['base_stem']}")
    print(f"  Already seen: {summary['already_ingested']}")
    print()
    for stage, info in summary["stages"].items():
        print(f"  [{stage}]")
        if isinstance(info, dict):
            for k, v in info.items():
                if isinstance(v, list):
                    if not v:
                        print(f"      {k}: (none — idempotent skip)")
                    else:
                        for item in v:
                            print(f"      {k}: {item}")
                else:
                    print(f"      {k}: {v}")
        else:
            print(f"      {info}")
    print()
    print(f"  Manifest updated: {summary.get('manifest_updated', False)}")
    print(f"  Manifest path:    {MANIFEST_PATH}")
    print()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="End-to-end box-rig hearing aid photo ingestion",
    )
    parser.add_argument("photo", help="Path to the box-rig photo (jpg/png/heic)")
    parser.add_argument("--brand", required=True, help='e.g. "Oticon"')
    parser.add_argument("--model", required=True, help='e.g. "Nera2 Pro"')
    parser.add_argument(
        "--test-reference",
        action="store_true",
        help="Also copy into data/test_reference/<brand>/ for test_pipeline.py",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would happen without writing anything",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Emit summary as JSON (for programmatic callers)",
    )
    args = parser.parse_args()

    photo_path = Path(args.photo).expanduser().resolve()
    t0 = time.time()
    try:
        summary = ingest(
            photo_path=photo_path,
            brand=args.brand,
            model=args.model,
            test_reference=args.test_reference,
            dry_run=args.dry_run,
        )
    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    summary["elapsed_seconds"] = round(time.time() - t0, 2)

    if args.json:
        print(json.dumps(summary, indent=2, default=str))
    else:
        _print_summary(summary)
        print(f"  Elapsed: {summary['elapsed_seconds']}s")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(main())
