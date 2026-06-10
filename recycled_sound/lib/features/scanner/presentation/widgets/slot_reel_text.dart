// Excluded from coverage: slot-reel slam animation; visual-only, ticker-driven
// coverage:ignore-file
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A text widget that cycles through candidate values like a slot machine
/// reel, then slams the detected value into place with a sinusoidal
/// overshoot bounce.
///
/// **Animation flow:**
/// 1. While spinning: candidates flow vertically to the RIGHT of the box.
/// 2. When [targetValue] arrives: the value slams LEFT into position,
///    overshooting past the left edge, then bouncing back with a
///    sinusoidal curve.
/// 3. Color flashes bright [accentColor] on impact, then fades to a
///    dimmed version.
///
/// Each field in the HUD should use a different [accentColor].
class SlotReelText extends StatefulWidget {
  const SlotReelText({
    super.key,
    required this.candidates,
    this.targetValue,
    this.style,
    this.accentColor = const Color(0xFF10B981), // default green
    this.spinSpeed = const Duration(milliseconds: 80),
  });

  /// Values to cycle through while spinning.
  final List<String> candidates;

  /// The detected value to land on. Null = keep spinning.
  final String? targetValue;

  /// Style while spinning.
  final TextStyle? style;

  /// Accent color for the slam flash. Each field should use a different one.
  final Color accentColor;

  /// How fast to cycle while spinning.
  final Duration spinSpeed;

  @override
  State<SlotReelText> createState() => _SlotReelTextState();
}

class _SlotReelTextState extends State<SlotReelText>
    with TickerProviderStateMixin {
  Timer? _spinTimer;
  int _currentIndex = 0;
  String _displayValue = '';
  bool _locked = false;
  bool _locking = false;

  // Vertical scroll animation (spinning candidates)
  late final AnimationController _scrollController;
  String _outgoingValue = '';
  bool _isScrolling = false;

  // Horizontal slam animation (locking into place)
  late final AnimationController _slamController;

  // Color fade animation (bright flash → dimmed)
  late final AnimationController _colorController;

  final _rng = math.Random();

  /// Slam curve: sinusoidal overshoot.
  /// Goes from 1.0 (right) → -0.15 (overshoot left) → 0.0 (home).
  static double _slamCurve(double t) {
    // Fast approach (0→0.5): slide from right to overshoot left
    // Settle (0.5→1.0): bounce back to center
    if (t < 0.5) {
      // Map [0, 0.5] → [1.0, -0.15] with ease-out
      final p = t * 2; // 0→1
      return 1.0 - 1.15 * _easeOutCubic(p);
    } else {
      // Map [0.5, 1.0] → [-0.15, 0.0] with damped sine
      final p = (t - 0.5) * 2; // 0→1
      return -0.15 * (1.0 - p) * math.cos(p * math.pi);
    }
  }

  static double _easeOutCubic(double t) => 1.0 - math.pow(1.0 - t, 3);

  @override
  void initState() {
    super.initState();

    _scrollController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 60),
    );

    _slamController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _colorController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );

    if (widget.candidates.isNotEmpty) {
      _currentIndex = _rng.nextInt(widget.candidates.length);
      _displayValue = widget.candidates[_currentIndex];
    }

    if (widget.targetValue != null) {
      _locked = true;
      _displayValue = widget.targetValue!;
      _colorController.value = 1.0; // start dimmed
    } else {
      _startSpinning();
    }
  }

  @override
  void didUpdateWidget(SlotReelText old) {
    super.didUpdateWidget(old);

    // Target just arrived — start deceleration → slam
    if (widget.targetValue != null && !_locked && !_locking) {
      _locking = true;
      _decelerate();
    }

    // Target changed after already locked — re-slam with new value
    if (_locked &&
        widget.targetValue != null &&
        widget.targetValue != _displayValue) {
      setState(() => _displayValue = widget.targetValue!);
      _slamController.forward(from: 0);
      _colorController.forward(from: 0);
      HapticFeedback.mediumImpact();
    }
  }

  @override
  void dispose() {
    _spinTimer?.cancel();
    _scrollController.dispose();
    _slamController.dispose();
    _colorController.dispose();
    super.dispose();
  }

  void _startSpinning() {
    _spinTimer = Timer.periodic(widget.spinSpeed, (_) {
      if (_locking) return;
      _advance();
    });
  }

  void _advance() {
    if (widget.candidates.isEmpty) return;
    _currentIndex = (_currentIndex + 1) % widget.candidates.length;
    final next = widget.candidates[_currentIndex];

    setState(() {
      _outgoingValue = _displayValue;
      _displayValue = next;
      _isScrolling = true;
    });

    _scrollController.forward(from: 0).then((_) {
      if (mounted) setState(() => _isScrolling = false);
    });
  }

  /// Decelerate, then slam the target value into place.
  Future<void> _decelerate() async {
    _spinTimer?.cancel();

    final target = widget.targetValue!;

    // Phase 1: slow down over ~6 ticks
    for (var delay = 100; delay <= 250; delay += 30) {
      await Future<void>.delayed(Duration(milliseconds: delay));
      if (!mounted) return;
      _advance();
    }

    // Phase 2: slam the target value in from the right
    if (!mounted) return;
    setState(() {
      _displayValue = target;
      _locked = true;
    });

    // Fire both animations simultaneously
    _slamController.forward(from: 0);
    _colorController.forward(from: 0);
    HapticFeedback.heavyImpact();
  }

  @override
  Widget build(BuildContext context) {
    final spinStyle = widget.style ??
        const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: Color(0x55FFFFFF),
          letterSpacing: 0.3,
        );

    return ClipRect(
      child: SizedBox(
        height: 16,
        child: _locked ? _buildLockedValue(spinStyle) : _buildSpinning(spinStyle),
      ),
    );
  }

  /// Locked state: slam animation + color fade.
  Widget _buildLockedValue(TextStyle spinStyle) {
    return AnimatedBuilder(
      animation: Listenable.merge([_slamController, _colorController]),
      builder: (context, _) {
        // Horizontal slam position
        final slamT = _slamController.value;
        final dx = slamT < 1.0 ? _slamCurve(slamT) * 80 : 0.0; // 80px travel

        // Color: bright accent → dimmed
        final colorT = _colorController.value;
        final color = Color.lerp(
          widget.accentColor,
          widget.accentColor.withValues(alpha: 0.6),
          colorT,
        )!;

        // Scale punch on impact (slight grow at overshoot point)
        final scale = slamT < 1.0
            ? 1.0 + 0.08 * math.sin(slamT * math.pi)
            : 1.0;

        return Transform.translate(
          offset: Offset(dx, 0),
          child: Transform.scale(
            scale: scale,
            alignment: Alignment.centerLeft,
            child: Text(
              _displayValue,
              style: spinStyle.copyWith(
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        );
      },
    );
  }

  /// Spinning state: candidates scroll vertically, offset to the right.
  Widget _buildSpinning(TextStyle spinStyle) {
    return AnimatedBuilder(
      animation: _scrollController,
      builder: (context, _) {
        final t = _scrollController.value;

        // Offset spinning text to the right of the destination box
        const rightOffset = 40.0;

        if (!_isScrolling || t >= 1.0) {
          return Transform.translate(
            offset: const Offset(rightOffset, 0),
            child: Text(_displayValue, style: spinStyle),
          );
        }

        // Vertical scroll: outgoing moves up, incoming from below
        return Stack(
          children: [
            Transform.translate(
              offset: Offset(rightOffset, -16 * t),
              child: Text(_outgoingValue, style: spinStyle),
            ),
            Transform.translate(
              offset: Offset(rightOffset, 16 * (1 - t)),
              child: Text(_displayValue, style: spinStyle),
            ),
          ],
        );
      },
    );
  }
}
