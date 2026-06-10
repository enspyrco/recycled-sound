// Excluded from coverage: CustomPainter over live frames; bounding-box render path
// coverage:ignore-file
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Whether a detection is a confirmed match or ambient (unmatched) text.
enum DetectionType {
  /// Confirmed brand/model match — green brackets.
  matched,
  /// Ambient text the scanner is reading — dim amber.
  ambient,
  /// Model candidate being evaluated — cyan/blue brackets.
  modelCandidate,
}

/// A detected text region to highlight on the camera preview.
class TextDetection {
  const TextDetection({
    required this.boundingBox,
    required this.label,
    this.type = DetectionType.matched,
  });

  /// Bounding box in ML Kit's coordinate space (rotated image).
  final Rect boundingBox;

  /// What was matched — e.g. "MAKE: Oticon" or raw text for ambient.
  final String label;

  /// Whether this is a confirmed match or ambient text the scanner is reading.
  final DetectionType type;
}

/// A snap event — records when and where a feature was first detected,
/// so the painter can draw the trailing-border capture effect.
class SnapEvent {
  SnapEvent({required this.boundingBox, required this.label})
      : timestamp = DateTime.now();

  final Rect boundingBox;
  final String label;
  final DateTime timestamp;

  /// Milliseconds since the snap fired.
  int get ageMs => DateTime.now().difference(timestamp).inMilliseconds;
}

/// A catalog cascade event — triggers the data stream animation when
/// the device catalog fills in fields.
class CascadeEvent {
  CascadeEvent({required this.field, required this.value})
      : timestamp = DateTime.now();

  final String field;
  final String value;
  final DateTime timestamp;

  int get ageMs => DateTime.now().difference(timestamp).inMilliseconds;
}

/// Paints overlays on detected text regions:
/// - **Matched**: green corner brackets with label (brand/model identified)
/// - **Ambient**: dim amber brackets (scanner is reading but no match yet)
/// - **Data stream**: horizontal lines sweeping down during catalog cascade
///
/// The ambient detections show the scanner is alive and working — reading
/// serial numbers, regulatory marks, everything — before a match lands.
class FeatureOverlayPainter extends CustomPainter {
  FeatureOverlayPainter({
    required this.detections,
    required this.imageSize,
    required this.previewSize,
    required this.sensorOrientation,
    required this.animationValue,
    this.snapEvents = const [],
    this.cascadeEvents = const [],
  });

  final List<TextDetection> detections;
  final Size imageSize;
  final Size previewSize;
  final int sensorOrientation;

  /// 0.0–1.0 pulsing animation for the brackets.
  final double animationValue;

  /// Active snap events — draws trailing borders for captures in progress.
  final List<SnapEvent> snapEvents;

  /// Active cascade events — draws data stream for catalog fills.
  final List<CascadeEvent> cascadeEvents;

  // Colors
  static const _matchedColor = Color(0xFF10B981); // success green
  static const _ambientColor = Color(0xFFD97706); // warm amber
  static const _candidateColor = Color(0xFF22D3EE); // cyan
  static const _cascadeColor = Color(0xFF60A5FA); // data blue
  static const _cascadeGreen = Color(0xFF34D399); // bright green

  /// Pseudo-random fragments for the data stream effect.
  static const _dataFragments = [
    'BTE', 'RIC', 'ITE', 'CIC', '312', '13', '675', '10',
    'RECHG', 'SLIM', 'STD', 'NONE', '2024', '2023', '2022',
    'PREMIUM', 'ADVANCED', 'ESSENTIAL', 'AURACAST', 'BT LE',
    '0x4F', '0xA3', '>>>', '===', '|||', '...', '###',
    'QUERY', 'MATCH', 'INDEX', 'FETCH', 'RESOLVE', 'CONFIRM',
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Draw data stream effect (behind everything else)
    for (final cascade in cascadeEvents) {
      final age = cascade.ageMs;
      if (age > 1200) continue; // 1.2s animation
      _drawDataStream(canvas, size, cascade, age / 1200.0);
    }

    // Draw snap ripple effects
    for (final snap in snapEvents) {
      final age = snap.ageMs;
      if (age > 500) continue;
      final rect = _transformRect(snap.boundingBox, size);
      _drawSnapRipple(canvas, rect, age / 500.0);
    }

    // Always draw a centre scanning reticle
    _drawScanReticle(canvas, size);

    if (detections.isEmpty) return;

    // Draw ambient detections first (underneath)
    for (final detection in detections) {
      if (detection.type == DetectionType.ambient) {
        final rect = _transformRect(detection.boundingBox, size);
        _drawAmbientBrackets(canvas, rect);
      }
    }

    // Draw model candidates (cyan)
    for (final detection in detections) {
      if (detection.type == DetectionType.modelCandidate) {
        final rect = _transformRect(detection.boundingBox, size);
        _drawModelCandidateBrackets(canvas, rect);
        _drawLabel(canvas, rect, detection.label, color: _candidateColor);
      }
    }

    // Draw matched detections on top (green)
    for (final detection in detections) {
      if (detection.type == DetectionType.matched) {
        final rect = _transformRect(detection.boundingBox, size);
        _drawMatchedBrackets(canvas, rect);
        _drawLabel(canvas, rect, detection.label);
      }
    }
  }

  /// Data stream animation — horizontal scan lines sweep down the screen
  /// with monospace text fragments streaming past. Represents the catalog
  /// lookup happening in real-time.
  void _drawDataStream(
      Canvas canvas, Size size, CascadeEvent event, double progress) {
    final rng = math.Random(event.field.hashCode);

    // Phase 1 (0.0–0.4): scan lines sweep down
    // Phase 2 (0.3–0.7): field name + value resolve in centre
    // Phase 3 (0.6–1.0): everything fades out

    // ── Scan lines ──────────────────────────────────────────────────────
    if (progress < 0.6) {
      final lineAlpha = progress < 0.4
          ? (progress / 0.4) // fade in
          : 1.0 - ((progress - 0.4) / 0.2); // fade out

      final linePaint = Paint()
        ..color = _cascadeColor.withValues(alpha: lineAlpha * 0.15)
        ..strokeWidth = 1.0;

      // 8 scan lines sweeping down at different speeds
      for (var i = 0; i < 8; i++) {
        final speed = 0.6 + rng.nextDouble() * 0.8;
        final offset = rng.nextDouble() * 0.3;
        final y = ((progress * speed + offset) % 1.0) * size.height;
        canvas.drawLine(
          Offset(0, y),
          Offset(size.width, y),
          linePaint,
        );
      }
    }

    // ── Streaming text fragments ────────────────────────────────────────
    if (progress < 0.7) {
      final fragAlpha = progress < 0.1
          ? progress / 0.1
          : progress > 0.5
              ? 1.0 - ((progress - 0.5) / 0.2)
              : 1.0;

      // 12 random text fragments at various positions
      for (var i = 0; i < 12; i++) {
        final x = rng.nextDouble() * size.width;
        final baseY = rng.nextDouble() * size.height;
        // Fragments drift downward
        final y = baseY + progress * 60.0 * (0.5 + rng.nextDouble());

        if (y > size.height || y < 0) continue;

        final fragment = _dataFragments[rng.nextInt(_dataFragments.length)];
        final tp = TextPainter(
          text: TextSpan(
            text: fragment,
            style: TextStyle(
              color: _cascadeColor.withValues(alpha: fragAlpha * 0.4),
              fontSize: 9,
              fontWeight: FontWeight.w500,
              fontFamily: 'monospace',
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();

        tp.paint(canvas, Offset(x, y));
      }
    }

    // ── Central resolve: field name + value ──────────────────────────────
    if (progress > 0.2 && progress < 1.0) {
      final resolveAlpha = progress < 0.4
          ? (progress - 0.2) / 0.2 // fade in
          : progress > 0.8
              ? 1.0 - ((progress - 0.8) / 0.2) // fade out
              : 1.0; // full

      final cx = size.width / 2;
      final cy = size.height * 0.38;

      // Background pill
      final pillPaint = Paint()
        ..color = const Color(0xFF000000).withValues(alpha: resolveAlpha * 0.7);
      final pillRect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy), width: 200, height: 28),
        const Radius.circular(14),
      );
      canvas.drawRRect(pillRect, pillPaint);

      // Border
      final borderPaint = Paint()
        ..color = _cascadeGreen.withValues(alpha: resolveAlpha * 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      canvas.drawRRect(pillRect, borderPaint);

      // Text: "STYLE → BTE" or "BATTERY → 312"
      final label = '${event.field} → ${event.value}';
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: _cascadeGreen.withValues(alpha: resolveAlpha),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
            letterSpacing: 1.5,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
    }
  }

  Rect _transformRect(Rect rect, Size widgetSize) {
    // On iOS, ML Kit returns bounding boxes already in display-oriented
    // coordinates (it applies the InputImageRotation internally). So we only
    // need to scale from image space to widget space — no rotation needed.
    final scaleX = widgetSize.width / imageSize.width;
    final scaleY = widgetSize.height / imageSize.height;

    return Rect.fromLTRB(
      rect.left * scaleX,
      rect.top * scaleY,
      rect.right * scaleX,
      rect.bottom * scaleY,
    );
  }

  /// Draw expanding ripple brackets — 3 trailing copies at increasing scale,
  /// each fading as the animation progresses. Like a radar ping.
  void _drawSnapRipple(Canvas canvas, Rect rect, double progress) {
    for (var i = 1; i <= 3; i++) {
      final expand = i * 4.0 * progress;
      final opacity = (1.0 - progress) * (1.0 - i * 0.25);
      if (opacity <= 0) continue;

      final paint = Paint()
        ..color = _matchedColor.withValues(alpha: opacity * 0.8)
        ..strokeWidth = 2.0 - (i * 0.4)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      _drawCorners(canvas, rect.inflate(4 + expand), paint);
    }
  }

  /// Cyan brackets for model candidate text — shows the scanner is
  /// now hunting for the model after brand is locked.
  void _drawModelCandidateBrackets(Canvas canvas, Rect rect) {
    final opacity = 0.4 + 0.3 * animationValue;
    final paint = Paint()
      ..color = _candidateColor.withValues(alpha: opacity)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    _drawCorners(canvas, rect.inflate(3), paint);
  }

  void _drawMatchedBrackets(Canvas canvas, Rect rect) {
    final opacity = 0.6 + 0.4 * animationValue;
    final paint = Paint()
      ..color = _matchedColor.withValues(alpha: opacity)
      ..strokeWidth = 2.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    _drawCorners(canvas, rect.inflate(4), paint);
  }

  /// Centre-frame scanning reticle — always visible while scanning.
  /// Pulses gently in amber to show the scanner is active and looking.
  void _drawScanReticle(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final side = size.shortestSide * 0.35;

    final breath = 1.0 + 0.06 * animationValue;
    final rect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: side * breath,
      height: side * breath,
    );

    final opacity = 0.2 + 0.4 * animationValue;
    final paint = Paint()
      ..color = _ambientColor.withValues(alpha: opacity)
      ..strokeWidth = 1.5 + 1.0 * animationValue
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    _drawCorners(canvas, rect, paint);
  }

  void _drawAmbientBrackets(Canvas canvas, Rect rect) {
    final opacity = 0.15 + 0.1 * animationValue;
    final paint = Paint()
      ..color = _ambientColor.withValues(alpha: opacity)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    _drawCorners(canvas, rect.inflate(2), paint);
  }

  void _drawCorners(Canvas canvas, Rect rect, Paint paint) {
    final cl = rect.shortestSide * 0.25;
    final l = rect.left;
    final t = rect.top;
    final r = rect.right;
    final b = rect.bottom;

    canvas.drawLine(Offset(l, t + cl), Offset(l, t), paint);
    canvas.drawLine(Offset(l, t), Offset(l + cl, t), paint);
    canvas.drawLine(Offset(r - cl, t), Offset(r, t), paint);
    canvas.drawLine(Offset(r, t), Offset(r, t + cl), paint);
    canvas.drawLine(Offset(l, b - cl), Offset(l, b), paint);
    canvas.drawLine(Offset(l, b), Offset(l + cl, b), paint);
    canvas.drawLine(Offset(r, b - cl), Offset(r, b), paint);
    canvas.drawLine(Offset(r, b), Offset(r - cl, b), paint);
  }

  void _drawLabel(Canvas canvas, Rect rect, String label,
      {Color color = _matchedColor}) {
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final labelRect = Rect.fromLTWH(
      rect.left,
      rect.top - textPainter.height - 6,
      textPainter.width + 8,
      textPainter.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(labelRect, const Radius.circular(3)),
      Paint()..color = const Color(0xCC000000),
    );

    textPainter.paint(
        canvas, Offset(rect.left + 4, rect.top - textPainter.height - 4));
  }

  @override
  bool shouldRepaint(covariant FeatureOverlayPainter old) => true;
}
