import 'dart:convert';

import 'package:flutter/services.dart';

/// Dart wrapper for the native iOS Vision OCR plugin
/// (`recycled_sound/ios/Runner/VisionOcrPlugin.swift`).
///
/// Replaces (or runs alongside) ML Kit text recognition. Two advantages
/// for our garbled-stamped-text problem:
///
/// 1. **`customWords` bias.** Apple's Vision recognizer prefers tokens
///    in the bias list at decode time — turns "Oricon" near-matches
///    into clean "Oticon" reads. The bias list is loaded once from
///    `assets/custom_words.json` (360 hearing-aid brand+model tokens).
///
/// 2. **Native iOS orientation handling.** Vision accepts
///    `CGImagePropertyOrientation` directly, sidestepping the ML Kit
///    BGRA rotation ambiguity that may be causing 180°-rotated reads.
///
/// ## Coordinate convention (v1, will likely change)
///
/// Bounding boxes returned by [recognizeText] are in **Vision's native
/// convention**: normalized 0..1, origin BOTTOM-LEFT, in post-rotation
/// image space. ML Kit returns pixel coords, origin top-left, in
/// pre-rotation space. The conversion isn't done here yet — the
/// integration site is responsible for translating to whatever the
/// overlay painter expects, or we add a translation pass later.
class VisionOcr {
  static const MethodChannel _channel =
      MethodChannel('recycled_sound/vision_ocr');

  static bool _initialized = false;

  /// Load `assets/custom_words.json` and push the bias list to the
  /// native side. Idempotent — calling twice is harmless. Safe to call
  /// from any isolate that has access to the rootBundle.
  static Future<void> initialize() async {
    if (_initialized) return;
    final raw = await rootBundle.loadString('assets/custom_words.json');
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final words = (decoded['words'] as List).cast<String>();
    await _channel.invokeMethod<void>('setCustomWords', {'words': words});
    _initialized = true;
  }

  /// Run OCR on a single frame. [orientation] is the camera's sensor
  /// orientation in degrees (typically 90 for an iPhone back camera in
  /// portrait). The native side maps this to `CGImagePropertyOrientation`.
  ///
  /// Returns the list of recognized text blocks, ordered as Vision
  /// returned them (no sort). Empty list if nothing was found.
  static Future<List<VisionTextBlock>> recognizeText({
    required Uint8List bytes,
    required int width,
    required int height,
    required int bytesPerRow,
    required int orientation,
  }) async {
    final result = await _channel.invokeMethod<List<Object?>>(
      'recognizeText',
      {
        'bytes': bytes,
        'width': width,
        'height': height,
        'bytesPerRow': bytesPerRow,
        'orientation': orientation,
      },
    );
    if (result == null) return const [];
    return result
        .whereType<Map<Object?, Object?>>()
        .map(VisionTextBlock._fromMap)
        .toList(growable: false);
  }
}

/// A recognized line of text returned by Apple's Vision framework.
///
/// [boundingBox] is in Vision's normalized post-rotation coords (0..1,
/// origin bottom-left) — see [VisionOcr] doc comment for translation
/// notes.
class VisionTextBlock {
  const VisionTextBlock({
    required this.text,
    required this.confidence,
    required this.boundingBox,
  });

  final String text;

  /// 0..1 — Vision's recognizer confidence for this candidate.
  final double confidence;

  /// Normalized 0..1 rect, origin bottom-left, post-rotation image space.
  final Rect boundingBox;

  static VisionTextBlock _fromMap(Map<Object?, Object?> m) {
    return VisionTextBlock(
      text: m['text'] as String? ?? '',
      confidence: (m['confidence'] as num?)?.toDouble() ?? 0.0,
      boundingBox: Rect.fromLTWH(
        (m['x'] as num?)?.toDouble() ?? 0.0,
        (m['y'] as num?)?.toDouble() ?? 0.0,
        (m['width'] as num?)?.toDouble() ?? 0.0,
        (m['height'] as num?)?.toDouble() ?? 0.0,
      ),
    );
  }

  @override
  String toString() => 'VisionTextBlock("$text", '
      'conf=${confidence.toStringAsFixed(2)}, '
      'bbox=$boundingBox)';
}
