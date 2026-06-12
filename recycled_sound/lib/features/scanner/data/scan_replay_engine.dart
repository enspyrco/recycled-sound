import 'brand_matcher.dart';
import 'device_index.dart';

/// Result of replaying a frame sequence through the real matcher.
///
/// Frame indices are **1-based** — `framesToBrandLock == 3` means the
/// brand first locked while processing the third frame. `null` means the
/// field never locked across the whole sequence.
class ReplayResult {
  const ReplayResult({
    required this.frameCount,
    required this.framesToBrandLock,
    required this.framesToModelLock,
    required this.finalBrand,
    required this.finalModel,
  });

  /// Total frames in the replayed sequence.
  final int frameCount;

  /// 1-based index of the frame where brand first locked, or null.
  final int? framesToBrandLock;

  /// 1-based index of the frame where model first locked, or null.
  final int? framesToModelLock;

  final String? finalBrand;
  final String? finalModel;

  bool get brandLocked => finalBrand != null;
  bool get modelLocked => finalModel != null;

  @override
  String toString() => 'ReplayResult(frames=$frameCount, '
      'brand=$finalBrand@${framesToBrandLock ?? "—"}, '
      'model=$finalModel@${framesToModelLock ?? "—"})';
}

/// Deterministic, offline replay of an OCR-token frame sequence through
/// the **real** production matcher ([BrandMatcher] + [DeviceIndex]).
///
/// ## Why this exists
///
/// The 15-second detection-latency CRUX was an un-reproducible on-device
/// anecdote. This engine turns it into a measured number: feed a labelled
/// sequence of per-frame OCR tokens and read back frames-to-brand-lock /
/// frames-to-model-lock. Each latency optimisation then gets a
/// before/after number instead of a vibe.
///
/// ## The format-agnostic contract
///
/// The input is `List<List<String>>` — an ordered list of frames, each a
/// list of the OCR text lines ML Kit read on that frame. **Both video and
/// stills reduce to this shape**: a 12s clip at fps=2 is ~24 frames; a
/// curated stills set is N discrete frames. So the same instrument answers
/// the video-vs-stills modality question — push each format's real
/// extracted OCR through `run()` and compare frames-to-lock and whether it
/// locks at all. The engine is blind to where the frames came from.
///
/// ## What it deliberately excludes
///
/// Only the text→brand/model layer (pure Dart). The neural-net and colour
/// signals need pixels and a platform channel, so they can't run offline —
/// and they're not what the latency CRUX is about. This benchmarks the
/// matcher, exactly as the elimination tree sees OCR in `_processFrame`.
class ScanReplayEngine {
  ScanReplayEngine({DeviceIndex? index})
      : _index = index ?? DeviceIndex.instance;

  final DeviceIndex _index;

  /// Replay [frames] (each a list of OCR text lines) through the matcher.
  ///
  /// Resets the [DeviceIndex] first, so each call is independent. Mirrors
  /// the per-line matching cascade of `LiveScanScreen._processFrame`:
  ///   1. model-first reverse lookup (any brand) — can set brand FROM MODEL
  ///   2. brand match — can override a weaker brand
  ///   3. model match against the now-known brand
  ReplayResult run(List<List<String>> frames) {
    _index.reset();

    int? brandLockFrame;
    int? modelLockFrame;

    for (var f = 0; f < frames.length; f++) {
      for (final raw in frames[f]) {
        final text = raw.trim();
        if (text.length < 2) continue;
        _matchLine(text);
      }

      final state = _index.state;
      if (brandLockFrame == null &&
          state.valueOf(DeviceField.brand) != null) {
        brandLockFrame = f + 1;
      }
      if (modelLockFrame == null &&
          state.valueOf(DeviceField.model) != null) {
        modelLockFrame = f + 1;
      }
    }

    final state = _index.state;
    return ReplayResult(
      frameCount: frames.length,
      framesToBrandLock: brandLockFrame,
      framesToModelLock: modelLockFrame,
      finalBrand: state.valueOf(DeviceField.brand),
      finalModel: state.valueOf(DeviceField.model),
    );
  }

  /// One OCR line through the three-step cascade. State is read live from
  /// the index at each step — step 1 narrowing the brand FROM MODEL is
  /// visible to step 3, exactly as the live getters behave.
  void _matchLine(String text) {
    // Step 1 — model-first reverse lookup (matches any brand's model).
    final reverse = BrandMatcher.matchModelAnyBrand(text);
    if (reverse != null &&
        reverse.model != _index.state.valueOf(DeviceField.model)) {
      _index.narrow(DeviceField.model, reverse.model,
          source: DetectionSource.ocr);
      if (_index.state.valueOf(DeviceField.brand) != reverse.brand) {
        _index.narrow(DeviceField.brand, reverse.brand,
            source: DetectionSource.ocr, confidence: 'FROM MODEL');
      }
      return;
    }

    // Step 2 — direct brand match (can override a weaker brand lock).
    final brand = BrandMatcher.matchBrandDetailed(text);
    if (brand != null &&
        brand.displayName != _index.state.valueOf(DeviceField.brand)) {
      _index.narrow(DeviceField.brand, brand.displayName,
          source: DetectionSource.ocr, confidence: brand.confidenceLabel);
      return;
    }

    // Step 3 — model match against the now-known brand.
    final knownBrand = _index.state.valueOf(DeviceField.brand);
    if (knownBrand != null) {
      final model = BrandMatcher.matchModel(text, knownBrand);
      if (model != null &&
          model != _index.state.valueOf(DeviceField.model)) {
        _index.narrow(DeviceField.model, model, source: DetectionSource.ocr);
      }
    }
  }
}
