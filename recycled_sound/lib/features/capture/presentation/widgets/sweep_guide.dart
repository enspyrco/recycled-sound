import 'dart:math' as math;

import 'package:flutter/material.dart';

/// In-app guided capture for the *video-sweep* protocol.
///
/// Instead of stepping a volunteer through six static per-face stills (the
/// legacy [CaptureSlot] sequence), the sweep protocol asks for ONE slow
/// rotation of the hearing aid in front of the camera over [sweepDuration].
/// The deployment surface is the live scanner's continuous frame stream, so a
/// rotating sweep matches what the scanner actually sees and is a superset of
/// the stills (individual frames can be extracted later).
///
/// This widget is the *demonstration + progress* overlay:
///  - a hearing-aid illustration that slowly turns about its vertical axis,
///    demonstrating the motion the volunteer should mirror;
///  - a circular progress arc that fills once over [sweepDuration] while
///    [running] is true, then fires [onComplete];
///  - a plain-language instruction.
///
/// Like [CaptureGuideHand] it is **purely cosmetic and must never block or
/// throw into the capture pipeline** (the cosmetic-never-blocks-pipeline
/// rule). A missing asset degrades to a hearing icon; the only moving parts
/// are two [AnimationController]s, disposed with the widget.
class SweepGuide extends StatefulWidget {
  const SweepGuide({
    super.key,
    this.size = 200,
    this.sweepDuration = const Duration(seconds: 10),
    this.spinPeriod = const Duration(seconds: 4),
    this.running = true,
    this.onComplete,
    this.asset = 'assets/capture_guide/hearing_aid_device.png',
    this.instruction =
        'Slowly turn the hearing aid through a full rotation.\n'
        'Keep the printed side facing the camera as it passes.',
  });

  /// Side length of the square device/ring area (the instruction sits below).
  final double size;

  /// How long one full capture sweep takes — the progress ring fills once
  /// over this duration.
  final Duration sweepDuration;

  /// How long the demonstration device takes to complete one visual turn.
  /// Independent of [sweepDuration]: the device keeps demonstrating the motion
  /// regardless of capture progress.
  final Duration spinPeriod;

  /// While true, the progress ring advances and [onComplete] eventually fires.
  /// Setting it false pauses and resets progress (e.g. the volunteer lifted
  /// the device out of frame).
  final bool running;

  /// Called once when the progress ring completes a full sweep.
  final VoidCallback? onComplete;

  /// Transparent PNG of the hearing-aid device. A missing asset falls back to
  /// [Icons.hearing] rather than a broken-image glyph.
  final String asset;

  /// Plain-language sweep instruction shown beneath the device.
  final String instruction;

  @override
  State<SweepGuide> createState() => _SweepGuideState();
}

class _SweepGuideState extends State<SweepGuide>
    with TickerProviderStateMixin {
  late final AnimationController _spin;
  late final AnimationController _progress;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: widget.spinPeriod)
      ..repeat();
    _progress = AnimationController(vsync: this, duration: widget.sweepDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onComplete?.call();
      });
    if (widget.running) _progress.forward();
  }

  @override
  void didUpdateWidget(SweepGuide oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spinPeriod != oldWidget.spinPeriod) {
      _spin.duration = widget.spinPeriod;
    }
    if (widget.sweepDuration != oldWidget.sweepDuration) {
      _progress.duration = widget.sweepDuration;
    }
    if (widget.running != oldWidget.running) {
      if (widget.running) {
        _progress.forward();
      } else {
        _progress
          ..stop()
          ..reset();
      }
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Progress ring fills once over the sweep duration.
              Positioned.fill(
                child: AnimatedBuilder(
                  animation: _progress,
                  builder: (context, _) => CustomPaint(
                    painter: _SweepRingPainter(
                      progress: _progress.value,
                      trackColor: theme.colorScheme.onSurface.withValues(
                        alpha: 0.12,
                      ),
                      progressColor: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              // Device turning about its vertical axis, demonstrating the motion.
              Padding(
                padding: EdgeInsets.all(widget.size * 0.16),
                child: AnimatedBuilder(
                  animation: _spin,
                  builder: (context, child) {
                    final angle = _spin.value * 2 * math.pi;
                    return Transform(
                      alignment: Alignment.center,
                      transform: Matrix4.identity()
                        ..setEntry(3, 2, 0.001) // perspective
                        ..rotateY(angle),
                      child: child,
                    );
                  },
                  child: _DeviceImage(asset: widget.asset),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: widget.size * 0.08),
        Text(
          widget.instruction,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.3),
        ),
      ],
    );
  }
}

/// The device image, with a graceful fallback so a missing/corrupt asset can
/// never surface a broken-image glyph in the capture flow.
class _DeviceImage extends StatelessWidget {
  const _DeviceImage({required this.asset});

  final String asset;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stack) => FittedBox(
        child: Icon(
          Icons.hearing,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// Draws the circular sweep-progress arc: a faint full-circle track with a
/// brighter arc sweeping clockwise from 12 o'clock as [progress] goes 0→1.
class _SweepRingPainter extends CustomPainter {
  _SweepRingPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
  });

  final double progress;
  final Color trackColor;
  final Color progressColor;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * 0.045;
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (size.shortestSide - stroke) / 2;

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = trackColor;
    canvas.drawCircle(center, radius, track);

    if (progress > 0) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke
        ..color = progressColor;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2, // start at 12 o'clock
        progress * 2 * math.pi,
        false,
        arc,
      );
    }
  }

  @override
  bool shouldRepaint(_SweepRingPainter old) =>
      old.progress != progress ||
      old.trackColor != trackColor ||
      old.progressColor != progressColor;
}
