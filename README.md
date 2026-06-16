# Recycled Sound

A community app that collects, services, and redistributes donated hearing aids to people who can't afford them — primarily refugees, asylum seekers, and low-income residents in Greater Dandenong, Victoria, Australia.

A joint initiative of the **Rotary Club of Springvale City** and **Arches Audiology** (Seray Lim, Clinical Audiologist), with audiology student volunteers from the **University of Melbourne** and **La Trobe University**.

The hero feature is a **Google Lens-style hearing-aid scanner** — point a phone at a donated device and it pre-fills 7 specification fields by fusing on-device OCR, neural-net brand classification, CLIP visual search, and a confidence-aware elimination tree over a 345-device register. The scanner is **human-in-the-loop by design**: the audiologist confirms or corrects everything before a device enters the QA queue.

> **If you're a CV/ML researcher reading this with an eye on contributing**, skip to [Open research surface area](#open-research-surface-area) — it maps specific open problems in this codebase to active research areas (image quality assessment, multi-frame super-resolution, HDR fusion, vision-language fusion, domain adaptation, small-object 3D reconstruction). The 7 subsections each name the files, the prior attempts, and the shape of a useful contribution.

## Status

**Active development, mid-fan-out.** Last TestFlight: **v0.4.0+7** (uploaded 2026-05-13 via the Enspyr team key; CI auto-deploys on subsequent merges to `main`). Bundle: `co.enspyr.recycledsound`.

Recent week's velocity (May 7–13) shipped: an on-device profiling baseline that overturned the headline "15-second latency" hypothesis (the pipeline is actually 30fps — OCR-signal-bound, not throughput-bound); a native iOS Vision OCR plugin running in shadow mode against ML Kit; a `customWords` bias asset with 360 hearing-aid brand/model tokens; a confidence-rank override guard on the elimination tree to stop wrong-narrowing flapping; structured contradiction logging; and four parallel research streams (CLIPArTT domain adaptation, YOLO-nano detector baseline, TestFlight CI automation, box-rig ingestion CLI) merged into `main`.

Wireframes cover 16 screens across 5 user flows. iOS app implements the full scanner pipeline (Home → Live Scan → 7-field Confirmation → Devices) end-to-end, plus auth, routing, and device register. Donor / Recipient / Privacy flows are designed but not yet built — those are Sprint 1/2 implementation work.

## What's built

### iOS / Flutter app (`recycled_sound/`)

| Area | Status | Notes |
|------|--------|-------|
| Routing | ✅ | `go_router` with shell route + bottom tabs (Home, Devices) |
| Home screen (1A) | ✅ | Hero CTA, stats cards, quick-action tiles |
| Live Scanner (1B) | ✅ | ~2,200-line single-threaded camera pipeline. ML Kit OCR + EfficientNet-B0 TFLite brand classifier + CIELAB colour detection + auto-cycling preprocessor (RAW/ENHANCE/HI-CON/OCR) + bounding-box overlay. Drives a `DeviceIndex` elimination tree over the 345-device catalog. Now also runs Apple Vision OCR in shadow mode for accuracy A/B. |
| Analysing (1C) | ✅ | Transitional progress screen between capture and results |
| Results (1D) | ✅ | Inline-editable spec rows; routes to Devices, Confirmation, or 3D capture |
| 7-field Confirmation | ✅ | The convergence point — fuses every upstream signal into Make / Model / Style / Tubing / Battery / Battery size / Colour. Slot-reel slam animation, AI-confidence badges, chip selectors, colour swatches. **Not in wireframes yet — emergent UX.** |
| 3D Capture | ✅ | ARKit `ObjectCaptureView` guided flow via native Swift plugin. Untested at scale. **Not in wireframes — research-driven.** |
| Device list (2A) | ✅ | Cards over the in-memory device register |
| Device detail (2C) | ✅ | Full spec view per device |
| Auth — Login & Signup | ✅ | Firebase Auth, email/password |
| Audiologist Review (2B) | ❌ | Wireframed, not built |
| Donor flow (3A–3C) | 🟡 | Signup screen exists; Donation Form / Confirmation not built |
| Recipient flow (4A–4C) | ❌ | Wireframed, not built |
| Privacy & Consent (5A–5C) | ❌ | Wireframed, not built |

**Frame-budget rule:** the scanner runs on a single-threaded camera pipeline. Anything in `_processFrame` competes with OCR for frames — visual polish is *not* free. See `CLAUDE.md` for the detection-throughput governance and the 2026-05-07 profiling baseline (median per-frame: OCR 24.3ms, prep 2.7ms, match+state <0.1ms — OCR is 85% of every frame's cost).

### Backend (`functions/`, `functions-clip/`)

- `analyzeHearingAid` — Cloud Vision API (OCR + labels) + catalog matcher (TypeScript)
- `clip_encode` — Python Cloud Function, ViT-B-32 laion2b CLIP embedding → cosine similarity against 1,927 pre-computed embeddings
- `setUserRole` — role-based custom claims
- `seedCatalog` — populate hearing aid catalog
- Firestore + Storage security rules with role-based permissions

The scanner is currently **on-device only**; the cloud pipeline is the original architecture and remains available as a fallback / shadow path.

### Data pipeline (`data/`)

- **Device DNA** — 37-dim capability vectors over 1,496 devices, ChromaDB
- **CLIP visual search** — 2,267 product images embedded with ViT-B-32 laion2b
- **CLIPArTT domain adaptation** — test-time adapter; parallel `clip_visual_adapted` collection; on synthetic targets currently *worse* than baseline (honest finding — needs real photos)
- **Box-rig photo ingestion** — end-to-end CLI for capturing training data with a clear plastic-box CV calibration rig
- **Linear probe results** — Brand 69.7%, **Style 91.2% (AI-grade!)**, Battery 78.7%
- **YOLO-nano baseline** — `yolo11n` trained on 1,505 product shots; mAP@50=0.21 with whole-image proxy bboxes (held for A/B against EfficientNet, not yet integrated)
- **Custom-words export** — 360 hearing-aid tokens (brands, product lines, style codes, battery codes) used as Apple Vision `customWords` bias
- `test_pipeline.py` — local harness comparing CLIP + Vision API on Seray's real device photos

### CI / deployment

- GitHub Actions: Flutter analyze + test, Cloud Functions build, **automated TestFlight deployment on merge to `main`**
- Skips Flutter+Functions tests for infra-only PRs (`.github/`, `data/`, `docs/`) so research-track changes aren't blocked by the Flutter coverage gate
- Last manual deploy: `xcrun altool` direct from this Mac using the Enspyr team API key

### Design system & wireframes

- 16 HTML wireframes across 5 flows (hosted on GitHub Pages)
- Figma design system: 15-colour palette, full typography scale, component library (Button, Chip, Input, Spec Row, Toggle, Confidence Row, etc.)
- Figma plugin to regenerate all screens

## Architecture

```
├── recycled_sound/             Flutter app (iOS + Android, focus = iOS)
│   ├── lib/
│   │   ├── core/               routing, theme, providers, shared widgets
│   │   └── features/
│   │       ├── auth/           login, signup, Firebase Auth integration
│   │       ├── home/           home screen with hero CTA
│   │       ├── scanner/        live scanner, analysing, results,
│   │       │                   confirmation (7-field), 3D capture
│   │       └── devices/        device list, device detail
│   ├── ios/Runner/             native iOS plugins (Swift):
│   │   ├── VisionOcrPlugin.swift     VNRecognizeTextRequest + customWords
│   │   ├── ObjectCapturePlugin.swift LiDAR 3D scan via RealityKit
│   │   └── AppDelegate.swift         plugin registration
│   └── assets/                 device_catalog.json, brand_classifier.tflite,
│                               custom_words.json (360 tokens), device_db.bin
├── functions/                  Firebase Cloud Functions (TypeScript)
│   ├── analyzeHearingAid       Vision API + catalog matcher
│   ├── setUserRole             Role-based custom claims
│   └── seedCatalog             Populate hearing aid catalog
├── functions-clip/             Python Cloud Function (CLIP encoder)
├── data/                       Python data pipeline:
│   ├── train_brand_classifier.py     EfficientNet-B0 training
│   ├── train_yolov26.py              YOLO detector training
│   ├── clipartt_adaptation.py        domain-adaptation pipeline
│   ├── build_visual_embeddings.py    catalog → ChromaDB
│   ├── ingest_box_photo.py           box-rig single-photo ingest
│   ├── preprocess_box_photos.py      perspective + WB correction
│   ├── export_custom_words.py        catalog → Vision customWords
│   ├── linear_probe.py               feasibility probe over CLIP features
│   ├── test_pipeline.py              offline regression harness
│   └── chroma_db/                    ChromaDB index (gitignored)
├── figma-plugin/               Figma plugin for wireframe generation
├── wireframes/                 Static HTML wireframes (GitHub Pages)
└── docs/                       privacy policy, scanner roadmap, CI guide,
                                box-photo capture guide, TestFlight setup,
                                linear-probe results
```

**Stack:** Flutter (Dart) · Firebase (Auth, Firestore, Storage, Functions) · ML Kit (current OCR) · Apple Vision (replacement OCR, shadow mode) · TensorFlow Lite (EfficientNet-B0) · ultralytics (YOLO11n) · open_clip (CLIP ViT-B-32 laion2b) · ChromaDB · ARKit + RealityKit (3D capture) · Cloud Vision API (cloud fallback)

## AI/ML stack at a glance

| Capability | Library / model | Where it runs | File |
|-----------|----------------|---------------|------|
| OCR (incumbent) | google_mlkit_text_recognition | on-device, Dart channel | `lib/.../live_scanner_screen.dart` |
| OCR (shadow, replacing) | Apple Vision `VNRecognizeTextRequest` + customWords bias | on-device, Swift plugin | `ios/Runner/VisionOcrPlugin.swift` + `lib/.../data/vision_ocr.dart` |
| Brand classifier | EfficientNet-B0 TFLite | on-device | `lib/.../data/brand_classifier.dart` + `data/train_brand_classifier.py` |
| Brand+box detector | YOLO11n (held for A/B) | trained, not yet integrated | `data/train_yolov26.py`, `data/yolov26_metrics.md` |
| Visual search | CLIP ViT-B-32 laion2b | cloud + local | `functions-clip/` + `data/build_visual_embeddings.py` |
| Visual search (adapted) | CLIPArTT residual adapter | offline pipeline | `data/clipartt_adaptation.py`, `data/adaptation_report.md` |
| Fuzzy text match | Levenshtein over 360-token corpus | Dart | `lib/.../data/brand_matcher.dart` |
| Colour | CIELAB k-NN over palette | Dart, on-device | `lib/.../data/colour_classifier.dart` |
| 3D reconstruction | RealityKit Object Capture (photogrammetry) | iOS native | `ios/Runner/ObjectCapturePlugin.swift` |
| Elimination tree | Inverted indexes over 345-device catalog, confidence-rank override guard | Dart | `lib/.../data/device_index.dart` |
| Frame preprocessor | RAW / ENHANCE / HI-CON / OCR filters, auto-cycled | Dart, on-device | `lib/.../data/frame_preprocessor.dart` |

## User Roles

| Role | Can do |
|------|--------|
| Donor | Donate hearing aids, scan to pre-fill specs, optionally connect with recipient |
| Recipient | Apply for a device, upload hearing assessment, track application status |
| Audiologist | Review AI-identified specs, confirm tech level, mark QA passed |
| Admin | Manage matching, approve workflows, moderate messaging, assign roles |

**All recipient-facing workflows are human-mediated by design** — no automation touches vulnerable users (refugees, asylum seekers) directly until manual workflows are tested and proven safe. Firm project decision from Sprint 6 (Feb 2026).

## Audiologist's 7-Field Identification Model

The scanner captures these per device, each with a different AI / human split:

| # | Field | AI handles | Human confirms |
|---|-------|-----------|----------------|
| 1 | Make | OCR ✅ | – |
| 2 | Model | OCR ✅ | – |
| 3 | Style (BTE/RIC/ITE/CIC) | CLIP probe at 91.2% accuracy (validated, integrating) | confirm |
| 4 | Tubing (slim/standard/none) | – | input only |
| 5 | Battery vs rechargeable | partial | confirm |
| 6 | Battery size (10/13/312/675) | classifier in design (78.7% probe baseline) | confirm |
| 7 | Colour | CIELAB classifier (OCR-gated) ✅ | confirm via swatches |

## Current crux (as of 2026-05-13)

The 2026-05-07 profiling overturned the previous "15-second latency" framing. We are **not** frame-budget bound — the pipeline runs at ~30fps with OCR taking 85% of each frame's cost (median 24.3ms of a 33ms budget at 30fps).

The real crux turned out to be **OCR signal quality**:

1. **ML Kit returns 0 text blocks for ~12 seconds** of scanning even with the 4-filter cycle. Auto-cycling isn't actually making text appear.
2. **When OCR finally reads, the output is garbled** — strings like `uoO`, `O4 1Nuog0`, `od Jlyuosan`, `oMIywon` that look like 180°-rotated `Oticon`-family text. Open question: is this a rotation bug in the BGRA path, or a recognizer failure mode on small stamped text? The current build has a debug overlay rendering the exact bytes ML Kit sees, side-by-side with the camera preview, to disambiguate.
3. **Neural-net hit the right answer and we ignored it.** `neural net → Oticon (46.5%) / Phonak (13.4%) / ReSound (8.1%)` — a clear 3.5× margin winner, but the absolute-confidence gate at 0.7 was over-conservative. The gate now accepts on `(abs ≥ 0.7) OR (abs ≥ 0.4 AND top1/top2 ≥ 2.0)`.
4. **Brand-flap pathology under noisy OCR overrides.** Once a brand was locked, a later fuzzy-match on garbled text was unconditionally overwriting it. Fixed with a confidence-rank override guard.

The active investment is the **Apple Vision OCR + `customWords` bias** path: 360 hearing-aid tokens push the recognizer toward known brand/model strings at decode time, sidestepping the post-hoc Levenshtein patch. Currently running in shadow mode so we can A/B against ML Kit on real scans before flipping the primary.

For the full re-ranked priority list with empirical baselines, see `docs/scanner-roadmap.md` and the corresponding memory note (`plan_scanner_forward.md`).

## Open research surface area

Recycled Sound is a working app with a clear social mission — but several of its hardest open questions are research-shaped, not engineering-shaped. The sections below map specific problems in this codebase to active areas of computer-vision research. Each names the relevant files, prior attempts in the repo, and the shape of a useful contribution.

### 1. Image Quality Assessment as an OCR gate

**Problem.** On-device profiling on 2026-05-07 showed that ML Kit returned zero text blocks for 360 consecutive frames (~12 seconds) before finally finding something — and what it found was garbled. The pipeline was running heavy OCR on every frame regardless of whether the frame was readable in principle.

**Current state.** The pipeline cycles through four preprocessing filters (RAW / ENHANCE / HI-CON / OCR) frame-by-frame with no quality signal — pure trial-and-error. Every frame goes to OCR with no upstream filtering.

**Where IQA fits.** A no-reference IQA head run *before* OCR could:
1. Skip out-of-focus or motion-blurred frames (saving the largest cost in the per-frame budget)
2. Score each preprocessor variant on the same source frame, pick the highest-quality one
3. Detect the "the camera is pointed at a desk, not a device" failure mode and prompt the user
4. Rank candidate frames in a burst by quality to feed the auto-capture still

**Code starting points.** `recycled_sound/lib/features/scanner/data/frame_preprocessor.dart` (the filter cycle); `recycled_sound/lib/features/scanner/presentation/live_scanner_screen.dart::_processFrame` (the per-frame OCR call site); `data/test_pipeline.py` (offline harness — extends cleanly into an IQA benchmark on Seray's 12-photo reference set).

**Shape of a contribution.** A small on-device IQA head — TFLite or CoreML, sub-5ms inference — gating OCR. The 12-photo Seray reference set is the validation target. Bonus: the same head could feed the failed-scan auto-export feature (planned) to retain only the *worst* frames as training data for the next iteration — a self-improving quality loop.

### 2. Multi-frame super-resolution for tiny stamped text

**Problem.** Hearing aids carry model names and serial codes stamped on tiny areas of the device body — usually the battery door or behind the receiver tube. At our 720×1280 stream resolution these texts are 8–12 pixels tall, right at the edge of what ML Kit or Apple Vision can decode.

**Current state.** The auto-capture path takes a single full-resolution still (~4032×3024 on iPhone) when the colour gate fires. One frame, no merging.

**Where SR fits.** Burst capture (5–10 frames at native resolution) + alignment + merge to produce a single higher-information image. Two reference points worth comparing:
- **Wronski et al., SIGGRAPH 2019** ("Handheld Multi-Frame Super-Resolution") — the algorithm shipping in Google Pixel's Super-Res Zoom. Uses natural hand tremor as sub-pixel offset. Published implementations available.
- **MFSR-GAN (2025)** — newer, explicitly models handheld motion. Potentially more robust to operator-specific hand-tremor profiles.

Published literature reports ~21% OCR accuracy lift from SR on document images. For the hearing-aid stamp case the gain is likely larger because we're closer to the recognizability cliff.

**Code starting points.** `recycled_sound/lib/features/scanner/presentation/live_scanner_screen.dart::_autoCapturForOcr` (the single-frame still path). Apple's `AVCaptureMultiCamSession` and burst capture APIs for the iOS native side.

**Shape of a contribution.** A native iOS plugin (Swift) that takes 5–10 burst frames, aligns and merges, returns a single sharper still. Drop-in replacement for the current single-frame still path. Real subject for an internal paper or external publication if the OCR lift holds — "Multi-frame super-resolution for medical-device identification" sits in an under-explored intersection.

### 3. HDR and specular highlight recovery

**Problem.** Hearing aid bodies are often glossy plastic or metallic — and the stamped serial regions catch direct light easily. We've seen frames where the brand name is unreadable because the entire stamped area is blown out to white.

**Current state.** Single-exposure capture, no tone-mapping, no HDR fusion. The auto-cycling filter's HI-CON mode is a contrast stretch with no awareness of clipped highlights.

**Where HDR fits.** Multi-exposure capture (one bracket at -1 EV / 0 / +1 EV) + exposure fusion à la Mertens to restore highlight detail in the stamp region. Could share burst-capture infrastructure with the SR work above.

**Code starting points.** Same `_autoCapturForOcr` site. iOS `AVCapturePhotoBracketSettings` for the bracket. `data/preprocess_box_photos.py` already has tone-mapping scaffolding for the box-rig calibration work — that pipeline could be the offline development environment before pushing into the on-device path.

**Shape of a contribution.** Bracket capture + exposure fusion as another option in the scanner's signal repertoire. Particularly relevant for the high-end glossy-finish products (Phonak Sphere, Oticon Intent). Could be evaluated jointly with SR — both attack the readability-of-tiny-text problem from different physical angles.

### 4. Vision-language fusion for clinical reporting

**Problem.** The scanner identifies devices but produces a structured 7-field record, not a clinical narrative. Audiologists in busy clinics want a one-paragraph summary they can drop into a patient record: *"Donated Oticon Real 1 miniRITE T, RIC style, size 13 battery, dark grey, in good cosmetic condition. Suitable for moderate-to-severe loss, supports iPhone streaming and Tinnitus Relief."*

**Current state.** Pure structured output. No language generation in the loop.

**Where VLM fits.** A small on-device language model (Phi-3-Vision, Qwen2.5-VL, or a distilled variant) conditioned on the captured frames + structured field output, producing the clinical paragraph. Privacy-preserving by being fully on-device — medical data never leaves the phone.

**Code starting points.** `recycled_sound/lib/features/scanner/presentation/widgets/scan_hud.dart` (the 7-field display); the existing 7-field model becomes the *structured constraint* for the LM rather than the output. The `DeviceCatalog` provides the spec lookup once Make/Model are locked.

**Shape of a contribution.** Directly at the CV+NLP intersection you've flagged as a research aspiration. A small VLM head running on Apple Neural Engine. Custom prompting / structured-output constraints to enforce the audiologist's field convention. Potential research angle: how much can vision conditioning recover from a 1–3B-param language model in the medical-device domain? Comparison study against pure-text generation with the structured fields as the only input.

### 5. Domain adaptation under product-shot / real-world shift

**Problem.** The CLIP visual search index is built from 1,927 product shots (clean, white-background, studio lighting). Real-world hand-held photos from clinics live in a different distribution — cluttered backgrounds, mixed lighting, occluded by fingers, often at oblique angles. Measured similarity drops to **0.518 average** (well below the threshold for confident match) for real photos against the catalog index.

**Current state.** CLIPArTT-style test-time adaptation pipeline shipped on 2026-05-12 (`data/clipartt_adaptation.py`). On the synthetic augmented target (no real photos available at the time) the adapter slightly *hurt* retrieval — top-1 went 0.226 → 0.195. Honest interpretation: pseudo-labels from an unadapted CLIP on heavy synthetic augmentations are too noisy a teacher.

**Where deeper DA fits.** Once Seray captures a real-world target set (~50–100 photos), the right next steps are:
- LoRA fine-tune of the CLIP image tower
- HyperGAN-CLIP-style adapter networks (SIGGRAPH Asia 2024)
- BiCLIP-style structured geometric realignment (2026)

**Code starting points.** `data/clipartt_adaptation.py` for the existing pipeline; `data/chroma_db/` for the catalog index; `data/adaptation_report.md` for the empirical baseline. The real-world target set lands in `data/real_world_photos/<brand>/` once Seray provides it.

**Shape of a contribution.** A comparison study of the three DA approaches on a held-out clinical set, against the unadapted baseline. The hearing-aid retrieval problem has the rare combination of (a) a clean, well-defined catalog distribution, (b) a quantifiable target distribution from clinical use, and (c) a downstream metric that matters (audiologist scan latency). Niche but real — an internal paper or workshop submission is realistic.

### 6. Small-object 3D reconstruction at the edge of feasibility

**Problem.** Hearing aids are small (2–3cm). Apple's RealityKit Object Capture officially supports 5cm+ objects; we're at the edge. The "3D model rotates beside the spec sheet" was the audience-impact hero moment from the Rotary talk (standing ovation, multiple clubs requested follow-up talks), but the current implementation is unreliable on the form factor.

**Current state.** ARKit `ObjectCaptureView` guided flow is built (`recycled_sound/ios/Runner/ObjectCapturePlugin.swift`) but untested on real devices at scale. LiDAR-supplemented paths have been explored but LiDAR's 3cm resolution is barely enough.

**Where 3D research fits.** Three contender approaches to compare on the small-form-factor edge:
- Apple's photogrammetry (current default)
- NeRF-based reconstruction from the same image sequence
- 3D Gaussian splatting (recent, fast inference)

**Code starting points.** The plugin Swift code, `recycled_sound/lib/features/scanner/presentation/capture_3d_screen.dart` for the Flutter-side guided flow, and `~/.claude/projects/.../memory/technical_3d_point_cloud.md` for the failure-mode catalog from prior attempts.

**Shape of a contribution.** Comparison study on a held-out set of 10–20 devices: which method reconstructs the 3cm form factor with best fidelity at reasonable inference latency on an iPhone? Real evaluation rather than vibes. Bonus: any improvement directly feeds the demo moment that's been recruiting Rotary clubs.

### 7. Adaptive scan strategy (speculative — for the RL-curious)

**Problem.** The scanner currently cycles preprocessor filters round-robin (RAW → ENHANCE → HI-CON → OCR), independent of what's actually working for the device in hand. With real-world per-device variance, this is wasteful — different surface finishes / lighting / orientations prefer different filters.

**Where RL / bandits fit.** Multi-armed bandit over (filter, frame quality, capture timing) decisions per scan. Reward = time-to-lock or final detection accuracy. Could learn per-brand or per-style policies (BTE filter cycle might differ from RIC).

**Code starting points.** `live_scanner_screen.dart::_processFrame` for the cycling logic. The `ScanTracker` infrastructure already records per-frame filter-vs-detection events that could become the offline policy training data.

**Shape of a contribution.** Speculative — the rule-based approach probably gets us most of the way for the immediate term. But if you've worked in RL and want a small, well-bounded application with clear ground truth and short episodes, this is one. Also a reasonable RL-curriculum entry point for the project.

## Getting started (clone-and-run)

```bash
# Repo
git clone https://github.com/enspyrco/recycled-sound.git
cd recycled-sound

# Flutter side
cd recycled_sound
flutter pub get
flutter run -d <your iPhone>        # debug, with Vision OCR shadow mode + debug overlays
# or for native breakpoint debugging in Swift plugins:
open ios/Runner.xcworkspace          # use Xcode → Run

# Data side (Python ML pipeline)
cd ../data
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt      # if present; otherwise:
pip install torch open_clip_torch chromadb numpy Pillow opencv-python ultralytics coremltools

# Existing tools
python3 test_pipeline.py /path/to/photo.jpg      # run a single photo through CLIP + Vision
python3 build_visual_embeddings.py               # rebuild ChromaDB from data/images_by_brand
python3 train_brand_classifier.py                # retrain EfficientNet-B0
python3 train_yolov26.py                         # retrain YOLO detector
python3 clipartt_adaptation.py                   # rerun domain adaptation
python3 ingest_box_photo.py <photo> --brand Oticon --model "Real 1"
```

The iOS app's deployment target is iOS 15.5. Object Capture requires iOS 17+ on a LiDAR-equipped device. Vision OCR `customWords` requires iOS 16+. The customWords bias asset is at `recycled_sound/assets/custom_words.json` (regenerate via `data/export_custom_words.py`).

**Where to dive in first** if you're picking up cold:
1. Run a debug build and scan a hearing aid yourself for 30 seconds. The Xcode console will stream `SCANNER:` log lines including stage-by-stage `PROFILE` data, ML Kit vs Apple Vision comparison, override-guard rejections, and contradiction summaries. This is the fastest way to develop intuition for what the pipeline actually sees.
2. Read `CLAUDE.md` at the repo root — that's the canonical "context for engineers and AI assistants" doc, including the detection-throughput governance and the current re-ranked priority list.
3. Skim `~/.claude/projects/-Users-nick-git-individuals-seray-recycled-sound/memory/plan_scanner_forward.md` for the 2026-05-13 status snapshot (or its public-facing equivalent in `docs/scanner-roadmap.md`).

## Sprint roadmap

- **Sprint 0 (current):** Define & Design — wireframes ✅, design system ✅, MVP scope locking ongoing
- **Sprint 1:** Core build — auth ✅, donor listing, recipient application, admin dashboard
- **Sprint 2:** Matching & tracking — manual matching, secure messaging, status pipeline
- **Sprint 3:** Directories — audiologist directory, auditory training referrals, psychologist directory
- **Sprint 4:** Legal & safety — medical disclaimer, GDPR + Australian Privacy Act review, identity verification
- **Sprint 5:** Impact — e-waste metrics dashboard, donor-recipient impact stories
- **Phase 2:** Overseas partner organisation integration; large-grant-funded ($50k+) scale-up

## Funding & context

- Applied for City of Greater Dandenong Medium Grant ($10k) — outcome pending June 2026
- Rotary co-contribution: $2k
- Larger grants (up to $50k) open in 2027; a working app strengthens the bid
- Total project value with in-kind contributions: $27,240

## Links

- **Wireframes:** https://enspyrco.github.io/recycled-sound/
- **Figma:** https://www.figma.com/design/b86mwNrRnm5lbxawcVZb64/Recycled-Sound
- **Privacy policy:** https://enspyrco.github.io/recycled-sound/privacy.html
- **Kanban:** https://tasks.xdeca.com/boards/tqy0nch0m8tm
- **Knowledge base:** https://kb.xdeca.com/collection/recycled-sound-9y9o7u1sZ1
- **Arches Audiology:** https://www.archesaudiology.com.au/
- **GitHub:** https://github.com/enspyrco/recycled-sound

## License

Not yet specified — license decision pending. Treat as "all rights reserved" until otherwise stated; reach out before forking for non-personal use.
