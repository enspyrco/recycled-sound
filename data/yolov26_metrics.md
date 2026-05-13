# YOLO-nano hearing-aid detector — metrics

Trained in parallel to the existing EfficientNet-B0 brand classifier.
Held for on-device A/B integration — the EfficientNet head is NOT
being replaced by this run.

## Run config

- Variant: `yolo11n.pt` (substituted for the unreleased `yolov26n`)
- Epochs: 1
- Image size: 640
- Val split: 20%
- Classes (9): Beltone, Bernafon, Oticon, Phonak, ReSound, Signia, Starkey, Unitron, Widex

## Known limitation: proxy bounding boxes

We have brand-classification labels but no human-drawn bounding boxes.
Every training image gets a whole-image bbox (cx=0.5, cy=0.5, w=h=1.0).
This trains the classifier head correctly but teaches the detector that
the device fills the frame — true of the unaudinary product shots but
NOT of real hand-held photos. Expect strong val mAP and weaker
real-world performance until proper bbox annotations exist.

## Overall metrics

- mAP@50:    **0.2075**
- mAP@50-95: **0.1738**

## Per-class mAP@50-95

| Brand | mAP@50-95 |
|-------|----------:|
| Beltone | 0.3088 |
| Bernafon | 0.0240 |
| Oticon | 0.0099 |
| Phonak | 0.2781 |
| ReSound | 0.3316 |
| Signia | 0.2073 |
| Starkey | 0.0066 |
| Unitron | 0.0533 |
| Widex | 0.3448 |

## Latency

- Samples: 20
- Mean ms/image (CPU/MPS local, single-batch): **45.2 ms**

## Exports

- PyTorch: `/Users/nick/git/individuals/seray/recycled-sound/.claude/worktrees/agent-a00b9f14d92cd9a66/data/models/hearing_aid_yolo.pt` (5.47 MB)

## Next steps

1. Real bbox annotations (Grounding-DINO auto-label, then human triage).
2. On-device A/B: load `hearing_aid_yolo.mlpackage` alongside the existing
   EfficientNet TFLite. Compare brand top-1 on the 12-photo Seray set.
3. Only after A/B win on real photos: replace the OCR-derived bbox in
   `feature_overlay_painter.dart` with YOLO's box (the demo "hero moment").
