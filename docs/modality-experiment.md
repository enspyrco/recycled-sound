# Video vs Stills — the modality experiment

**Status (2026-06-12):** Instrument built. Preliminary verdict below. Final
verdict blocked on one Nick-gated capture step.

## The question

The scanner's deployment surface is the live camera's **continuous frame
stream**. So the training/eval data — and the volunteer photo-day capture
protocol — should arguably be shaped like deployment: short **video clips**,
not curated **stills**. But stills are easier to curate, label, and pipe
through existing tooling. Which format do volunteers capture on photo-day?

This had been deferred three sessions because "build Delia's PRs" kept (justly)
preempting it. The risk of a fourth deferral: the dress rehearsal captures data
in *some* format, and if we later pivot, that rehearsal data is sunk cost.

## The instrument (built 2026-06-12)

`lib/features/scanner/data/scan_replay_engine.dart` +
`test/scan_replay_harness_test.dart`.

The engine replays an **ordered list of per-frame OCR token lists**
(`List<List<String>>`) through the **real** production matcher (`BrandMatcher`
+ `DeviceIndex`, against the real catalog) and reports **frames-to-brand-lock**
and **frames-to-model-lock**. It mirrors `LiveScanScreen._processFrame`'s
three-step matching cascade exactly; it excludes only the neural-net and colour
signals (those need pixels and a platform channel, and aren't what the latency
CRUX is about).

**Why this one instrument settles the format question:** video and stills both
reduce to the same frame contract. A 12s clip at fps=2 is ~24 frames; a curated
stills set is N discrete frames. Feed each format's *real extracted OCR* through
`run()` and compare frames-to-lock and whether it locks at all. The engine is
blind to provenance.

It is also the deterministic **detection-latency regression suite** the 15s
CRUX always lacked: every matcher optimisation now gets a before/after
frames-to-lock number instead of an on-device vibe.

## What the harness already showed (real evidence, not theory)

Running the baseline fixtures on the real catalog tonight surfaced two findings
that bear directly on the format decision:

1. **The bottleneck is the medial-face brand label.** Frames-to-lock is gated
   entirely on the label being readable in *some* frame (fixtures D, E). The
   brand label is printed sideways on the medial face (see anatomical taxonomy).
   A capture format wins by maximising the number of frames in which that one
   label is legible. **Video sweeps cross the medial face at multiple
   distances/angles → more OCR chances at the field that matters.** Sparse
   stills can miss it entirely (modality-comparison test).

2. **More frames is a double-edged sword until backtracking lands.** Fixture B2
   is a *known pathology* the harness reproduced deterministically: `"oricon"`
   (the documented OCR misread of "Oticon") fuzzy-matches **Signia's "Orion"
   model**, locks brand=Signia FROM MODEL, and the override guard then *refuses*
   to correct to Oticon when the clean `"nera"` signal arrives. Every extra
   frame is another chance for a noise token to lock the wrong value early —
   and the elimination tree cannot currently back out of it
   (`feedback_elimination_tree_backtracking`, the γ work).

## Preliminary verdict

**Lean video for capture, but γ-backtracking is the unlock that makes video
strictly better.**

- Video maximises the probability of catching the one label that gates
  detection (finding 1). For *training data shaped like deployment*, it is the
  right source-of-truth — a superset of stills (`ffmpeg -vf fps=2` extracts
  frames on demand).
- Until γ-backtracking lands, video's extra frames also raise the chance of an
  early wrong-lock sticking (finding 2). The override guard turns a transient
  misread into a permanent wrong ID. This is the real cost to weigh.
- **Therefore:** capture video on photo-day (don't throw away the richer
  signal), but treat γ-backtracking as the gating fix for the *live* experience,
  not a nice-to-have. The replay harness is how you'll prove γ works — fixture
  B2 flips green the day it does.

## The one Nick-gated step to a FINAL verdict

The engine needs **real extracted OCR** from actual captures of the same
devices in both formats:

1. Capture ~3 reference devices both ways: one ~12s slow-rotation **clip** each
   (must sweep the medial face) AND a **stills** set (the label-first protocol).
2. Extract per-frame OCR: `ffmpeg -vf fps=2` on the clip → frames → run ML Kit
   (or the Vision OCR plugin) on each → dump token lists. Same for each still.
3. Feed both token-sequences into `ScanReplayEngine.run()` and compare
   frames-to-lock and lock-rate across the device set.
4. Write the final verdict here and in memory `project_video_capture_pivot.md`.

Step 1 is the only blocker — it needs Nick + physical hearing aids. Everything
downstream is built and tested.
