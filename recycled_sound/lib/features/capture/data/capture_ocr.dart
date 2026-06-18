import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../scanner/data/brand_matcher.dart';
import '../../scanner/data/vision_ocr.dart';

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
  Future<CaptureId?> identify(List<String> imagePaths) async {
    final mlkitTokens = await _mlkitTokens(imagePaths);
    final visionTokens = await _visionTokens(imagePaths);

    final fused = <String>[...mlkitTokens, ...visionTokens];
    final result = _matchTokens(fused);

    // Shadow A/B: log what each engine would have found on its own, so a real
    // device capture session tells us whether Vision .accurate is pulling its
    // weight vs ML Kit (or whether either alone would suffice).
    if (kDebugMode && Platform.isIOS) {
      final mlkitOnly = _matchTokens(mlkitTokens);
      final visionOnly = _matchTokens(visionTokens);
      debugPrint('CaptureOcr A/B over ${imagePaths.length} still(s): '
          'mlkit=$mlkitOnly  vision=$visionOnly  fused=$result');
    }

    return result;
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
