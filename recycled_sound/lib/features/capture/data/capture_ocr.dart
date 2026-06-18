import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../scanner/data/brand_matcher.dart';
import '../../scanner/data/vision_ocr.dart';
import 'ocr_crop_pyramid.dart';

/// What OCR managed to read off the captured stills.
class CaptureId {
  const CaptureId({required this.brand, required this.model});

  final String brand;
  final String model;

  bool get isEmpty => brand.isEmpty && model.isEmpty;

  @override
  String toString() => 'CaptureId(brand: "$brand", model: "$model")';
}

/// Auto-identifies brand + model from captured stills, so volunteers don't have
/// to type them — the audiologist confirms later.
///
/// This deliberately runs OCR on the **saved image files** (the brand-label
/// shots), not on the live camera stream. The scanner's 15-second-latency crux
/// came from OCRing every live frame on the single camera thread; reading a
/// still that's already on disk never competes with the preview for frames, so
/// the throughput-sacred rule is preserved. OCR is also strictly best-effort:
/// every failure is swallowed and leaves the field blank for the audiologist.
///
/// ## Dual-engine A/B (task #55)
///
/// On iOS we read each still with BOTH ML Kit and Apple Vision `.accurate`,
/// then match brand/model against the **union** of their tokens — fusion can
/// only ever find more than one engine alone. The standalone result of each
/// engine is logged in debug builds so the on-device A/B (does Vision actually
/// beat ML Kit on real captures?) collects itself with no extra harness. On
/// Android the Vision channel doesn't exist, so we fall back to ML Kit only.
class CaptureOcr {
  /// Lazily created so constructing a [CaptureOcr] (e.g. in a widget test that
  /// pumps the capture screen) never opens the ML Kit platform channel — that
  /// only happens the first time [identify] actually runs.
  TextRecognizer? _recognizer;
  TextRecognizer get _r => _recognizer ??= TextRecognizer();

  /// Read brand/model from the given image files (the brand-label / medial
  /// shots). Returns the best match found, or null if nothing matched. Never
  /// throws — a recognizer or decode failure just yields fewer tokens.
  ///
  /// Each still is expanded into the **full frame plus a multi-scale center-crop
  /// pyramid** ([kOcrCropFractions]) before OCR, and the tokens from every scale
  /// are unioned. Full-frame OCR already reads most brand labels, but hard
  /// low-contrast / embossed ones only surface at a tighter crop (#58,
  /// `technical_ocr_crop_pyramid.md`) — and OCR is non-monotonic in scale, so a
  /// label invisible at one fraction reads at another. The crops are temp files
  /// deleted before this returns; if cropping fails we still OCR the original.
  Future<CaptureId?> identify(List<String> imagePaths) async {
    final expanded = await _expandWithCrops(imagePaths);
    try {
      final mlkitTokens = await _mlkitTokens(expanded.paths);
      final visionTokens = await _visionTokens(expanded.paths);

      final fused = <String>[...mlkitTokens, ...visionTokens];
      final result = _matchTokens(fused);

      // Shadow A/B: log what each engine would have found on its own, so a real
      // device capture session tells us whether Vision .accurate is pulling its
      // weight vs ML Kit (or whether either alone would suffice). Fires on both
      // platforms — on Android `vision` is null (channel is iOS-only), but the
      // mlkit/fused reads still expose whether the crop pyramid recovered a hard
      // label that full-frame missed (the #58 on-device verification signal).
      if (kDebugMode) {
        final mlkitOnly = _matchTokens(mlkitTokens);
        final visionOnly = _matchTokens(visionTokens);
        debugPrint('CaptureOcr A/B over ${imagePaths.length} still(s), '
            '${expanded.paths.length} frame(s) incl. crops: '
            'mlkit=$mlkitOnly  vision=$visionOnly  fused=$result');
      }

      return result;
    } finally {
      await expanded.dispose();
    }
  }

  /// Expand each still into itself + its center-crop pyramid. Crops are written
  /// to a single temp dir (deleted by [_ExpandedStills.dispose]); a still that
  /// can't be decoded simply contributes only its full frame.
  Future<_ExpandedStills> _expandWithCrops(List<String> imagePaths) async {
    Directory? tempDir;
    try {
      tempDir = await Directory.systemTemp.createTemp('ocr_crops_');
    } catch (_) {
      // No temp dir → fall back to full-frame-only OCR (never regress).
      return _ExpandedStills(paths: imagePaths, tempDir: null);
    }
    final paths = <String>[];
    for (final path in imagePaths) {
      paths.add(path); // full frame first — it reads most labels on its own
      paths.addAll(await writeOcrCropPyramid(path, tempDir));
    }
    return _ExpandedStills(paths: paths, tempDir: tempDir);
  }

  /// ML Kit tokens from every readable still (best-effort, both platforms).
  Future<List<String>> _mlkitTokens(List<String> imagePaths) async {
    final tokens = <String>[];
    for (final path in imagePaths) {
      try {
        final recognized =
            await _r.processImage(InputImage.fromFilePath(path));
        for (final block in recognized.blocks) {
          for (final line in block.lines) {
            tokens.add(line.text);
            tokens.addAll(line.text.split(RegExp(r'\s+')));
          }
        }
      } catch (_) {
        // Best-effort — skip an unreadable frame, keep whatever else we got.
      }
    }
    return tokens;
  }

  /// Apple Vision `.accurate` tokens (iOS only; off the camera hot path).
  /// Returns empty on Android or if the channel/initialize fails — the caller
  /// still has the ML Kit tokens, so a Vision failure degrades, never breaks.
  Future<List<String>> _visionTokens(List<String> imagePaths) async {
    if (!Platform.isIOS) return const [];
    final tokens = <String>[];
    try {
      await VisionOcr.initialize();
    } catch (_) {
      return const []; // custom-words bundle missing → skip Vision entirely.
    }
    for (final path in imagePaths) {
      try {
        final blocks = await VisionOcr.recognizeFile(path: path, accurate: true);
        for (final b in blocks) {
          tokens.add(b.text);
          tokens.addAll(b.text.split(RegExp(r'\s+')));
        }
      } catch (_) {
        // Best-effort per still (e.g. MissingPluginException, decode failure).
      }
    }
    return tokens;
  }

  /// Match brand/model from a token list. Strongest signal first: a model
  /// lookup yields brand AND model together ("moxi2 kiss" → Unitron + Moxi2
  /// Kiss) even if the brand word isn't legible; brand-only is the fallback.
  CaptureId? _matchTokens(List<String> tokens) {
    String? brand;
    String? model;

    for (final t in tokens) {
      final m = BrandMatcher.matchModelAnyBrand(t);
      if (m != null) {
        brand = m.brand;
        model = m.model;
        break;
      }
    }
    if (brand == null) {
      for (final t in tokens) {
        final b = BrandMatcher.matchBrand(t);
        if (b != null) {
          brand = b;
          break;
        }
      }
    }

    if (brand == null && model == null) return null;
    return CaptureId(brand: brand ?? '', model: model ?? '');
  }

  void dispose() => _recognizer?.close();
}

/// The full-frame stills plus their temp crop files, bundled with the temp dir
/// so the caller can clean up in a `finally` regardless of OCR outcome.
class _ExpandedStills {
  _ExpandedStills({required this.paths, required this.tempDir});

  /// Every path to OCR: each original still followed by its center-crops.
  final List<String> paths;

  /// The temp dir holding the crop files, or null if none was created.
  final Directory? tempDir;

  /// Remove the temp crop files. Best-effort — a cleanup failure must never
  /// surface from an otherwise-successful identify().
  Future<void> dispose() async {
    try {
      await tempDir?.delete(recursive: true);
    } catch (_) {}
  }
}
