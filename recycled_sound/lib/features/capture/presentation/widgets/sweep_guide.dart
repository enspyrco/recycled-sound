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
///  - a real 3D hearing-aid **turntable** (pre-rendered frames played in a
///    loop) demonstrating the rotation the volunteer should mirror;
///  - a circular progress arc that fills once over [sweepDuration] while
///    [running] is true, then fires [onComplete];
///  - a plain-language instruction.
///
/// The turntable is a sequence of pre-rendered transparent PNGs (a CC-BY 3D
/// model spun in Blender — see ATTRIBUTION.md). Playing frames means **no
/// runtime 3D engine**: the device looks genuinely 3D but costs only what an
/// image swap costs, honouring the project's throughput-sacred rule on the
/// camera screen.
///
/// Like [CaptureGuideHand] it is **purely cosmetic and must never block or
/// throw into the capture pipeline**. A missing frame degrades to a hearing
/// icon; the only moving parts are two [AnimationController]s, disposed with
/// the widget.
class SweepGuide extends StatefulWidget {
  const SweepGuide({
    super.key,
    this.size = 200,
    this.sweepDuration = const Duration(seconds: 10),
    this.spinPeriod = const Duration(seconds: 4),
    this.running = true,
    this.onComplete,
    this.frameDir = 'assets/capture_guide/aid_turntable',
    this.frameCount = 24,
    this.instruction =
        'Slowly turn the hearing aid through a full rotation.\n'
        'Keep the printed side facing the camera as it passes.',
  });

  /// Side length of the square device/ring area (the instruction sits below).
  final double size;

  /// How long one full capture sweep takes — the progress ring fills once
  /// over this duration.
  final Duration sweepDuration;

  /// How long the demonstration turntable takes to complete one full turn.
  /// Independent of [sweepDuration]: the device keeps demonstrating the motion
  /// regardless of capture progress.
  final Duration spinPeriod;

  /// While true, the progress ring advances and [onComplete] eventually fires.
  /// Setting it false pauses and resets progress (e.g. the volunteer lifted
  /// the device out of frame) and stops the turntable to save frames.
  final bool running;

  /// Called once when the progress ring completes a full sweep.
  final VoidCallback? onComplete;

  /// Asset directory holding the turntable frames `frame_00.png`..`frame_NN`.
  final String frameDir;

  /// Number of turntable frames (named `frame_00.png` .. `frame_{count-1}`).
  final int frameCount;

  /// Plain-language sweep instruction shown beneath the device.
  final String instruction;

  /// Asset path of frame [i], zero-padded to two digits.
  String frameAsset(int i) =>
      '$frameDir/frame_${i.toString().padLeft(2, '0')}.png';

  @override
  State<SweepGuide> createState() => _SweepGuideState();
}

class _SweepGuideState extends State<SweepGuide>
    with TickerProviderStateMixin {
  late final AnimationController _spin;
  late final AnimationController _progress;
  bool _precached = false;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(vsync: this, duration: widget.spinPeriod);
    _progress = AnimationController(vsync: this, duration: widget.sweepDuration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onComplete?.call();
      });
    if (widget.running) {
      _spin.repeat();
      _progress.forward();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Warm the image cache so the loop doesn't hitch on first pass.
    if (!_precached) {
      _precached = true;
      for (var i = 0; i < widget.frameCount; i++) {
        precacheImage(AssetImage(widget.frameAsset(i)), context)
            .catchError((_) {}); // missing frames degrade gracefully
      }
    }
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
        _spin.repeat();
        _progress.forward();
      } else {
        // Pause the turntable too — no point repainting a guide nobody is
        // mirroring (throughput-sacred: don't burn frames when idle).
        _spin.stop();
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
                      trackColor:
                          theme.colorScheme.onSurface.withValues(alpha: 0.12),
                      progressColor: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              // 3D turntable: the spin controller selects the current frame.
              Padding(
                padding: EdgeInsets.all(widget.size * 0.12),
                child: AnimatedBuilder(
                  animation: _spin,
                  builder: (context, _) {
                    final i = (_spin.value * widget.frameCount).floor() %
                        widget.frameCount;
                    return Image.asset(
                      widget.frameAsset(i),
                      fit: BoxFit.contain,
                      gaplessPlayback: true, // hold prev frame, no flicker
                      errorBuilder: (context, error, stack) => FittedBox(
                        child: Icon(Icons.hearing,
                            color: theme.colorScheme.primary),
                      ),
                    );
                  },
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
    final center = (Offset.zero & size).center;
    final radius = (size.shortestSide - stroke) / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = trackColor,
    );

    if (progress > 0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2, // start at 12 o'clock
        progress * 2 * math.pi,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = stroke
          ..color = progressColor,
      );
    }
  }

  @override
  bool shouldRepaint(_SweepRingPainter old) =>
      old.progress != progress ||
      old.trackColor != trackColor ||
      old.progressColor != progressColor;
}
