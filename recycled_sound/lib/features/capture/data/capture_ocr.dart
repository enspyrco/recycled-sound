import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../scanner/data/brand_matcher.dart';

/// What OCR managed to read off the captured stills.
class CaptureId {
  const CaptureId({required this.brand, required this.model});

  final String brand;
  final String model;

  bool get isEmpty => brand.isEmpty && model.isEmpty;
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

    String? brand;
    String? model;

    // Strongest signal: a model lookup yields brand AND model together
    // ("moxi2 kiss" → Unitron + Moxi2 Kiss), even if the brand isn't legible.
    for (final t in tokens) {
      final m = BrandMatcher.matchModelAnyBrand(t);
      if (m != null) {
        brand = m.brand;
        model = m.model;
        break;
      }
    }
    // Fallback: brand-only (the model stays blank for the audiologist).
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
