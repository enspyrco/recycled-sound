import 'package:flutter/material.dart';

import '../capture_slot.dart';

/// Per-slot capture-guide animation: a pre-rendered clip of the hearing aid
/// rotating FROM its current orientation TO the next one as the volunteer
/// advances. The motion is genuinely position-to-position — when you step from
/// (say) `lateral` to `anterior`, the aid turns from the lateral pose into the
/// anterior pose, so it reads like turning one physical object in your hand
/// rather than a fresh device snapping into place each step.
///
/// Frames are pre-rendered in Blender from the CC-BY 3D model (Sergey Burov,
/// Sketchfab), realistic PBR materials. Two asset families under
/// `assets/capture_guide/anim/`:
///   * `t_{from}_{to}_NN.png` — the transition clip between two consecutive
///     slots in the capture cycle ([_cycle]).
///   * `rest_{slot}.png` — the settled pose, shown for the very first slot
///     (before any transition has happened) and for non-adjacent jumps.
///
/// Playing baked frames (the PR #96 turntable technique) keeps a true-3D look
/// with no runtime 3D engine, so it never competes with the camera for frames
/// (cosmetic-never-blocks-pipeline). Fail-soft: a missing frame falls back to a
/// hearing icon, never a broken-image glyph.
///
/// IMPORTANT: this widget must NOT be wrapped in a keyed [AnimatedSwitcher]
/// (which recreates it per slot) — it relies on [didUpdateWidget] seeing the
/// old slot to choose the transition. The parent passes a stable key.
class CaptureGuideHand extends StatefulWidget {
  const CaptureGuideHand({super.key, required this.slot, this.size = 120});

  final CaptureSlot slot;
  final double size;

  /// Frames per transition (matches the Blender render NFRAMES).
  static const int frames = 16;

  /// The fixed cyclic order the capture flow steps through (CaptureSlot enum
  /// order). Consecutive pairs — including inferior→scale — are the transitions
  /// we render and can play.
  static const List<CaptureSlot> _cycle = CaptureSlot.values;

  /// The transition asset list for an adjacent (from → to) step, or null if the
  /// pair isn't consecutive in the cycle (a jump / backward move).
  static List<String>? transitionFor(CaptureSlot from, CaptureSlot to) {
    final i = _cycle.indexOf(from);
    if (i == -1) return null;
    final next = _cycle[(i + 1) % _cycle.length];
    if (next != to) return null;
    return [
      for (var f = 0; f < frames; f++)
        'assets/capture_guide/anim/t_${from.name}_${to.name}_'
            '${f.toString().padLeft(2, '0')}.png',
    ];
  }

  static String restAsset(CaptureSlot s) =>
      'assets/capture_guide/anim/rest_${s.name}.png';

  @override
  State<CaptureGuideHand> createState() => _CaptureGuideHandState();
}

class _CaptureGuideHandState extends State<CaptureGuideHand>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// The sequence currently on screen. Either a transition clip (playing) or a
  /// single rest still (length 1, static).
  late List<String> _sequence;
  bool _precached = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      // ~1.05s per transition — deliberately unhurried so the rotation reads.
      duration: Duration(milliseconds: 66 * CaptureGuideHand.frames),
    );
    _sequence = [CaptureGuideHand.restAsset(widget.slot)];
    _controller.value = 1; // show the settled frame immediately
  }

  @override
  void didUpdateWidget(CaptureGuideHand old) {
    super.didUpdateWidget(old);
    if (old.slot == widget.slot) return;
    final transition =
        CaptureGuideHand.transitionFor(old.slot, widget.slot);
    if (transition != null) {
      _sequence = transition;
      _controller
        ..reset()
        ..forward();
    } else {
      // Non-adjacent jump (or backward): snap to the settled pose.
      _sequence = [CaptureGuideHand.restAsset(widget.slot)];
      _controller.value = 1;
    }
    setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_precached) return;
    _precached = true;
    // Warm every transition + rest still once, so no play-through flickers.
    // onError swallows a missing/undecodable frame (and the empty test asset
    // bundle) — the build-side Image.asset errorBuilder is the real fallback;
    // precache must never surface an uncaught exception.
    void warm(String asset) =>
        precacheImage(AssetImage(asset), context, onError: (_, _) {});
    for (final s in CaptureSlot.values) {
      warm(CaptureGuideHand.restAsset(s));
      final t = CaptureGuideHand.transitionFor(
          s, CaptureSlot.values[(s.index + 1) % CaptureSlot.values.length]);
      if (t != null) t.forEach(warm);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.07),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white24),
      ),
      child: widget.slot == CaptureSlot.scale
          ? Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(child: _player()),
                SizedBox(width: size * 0.06),
                Text('💳', style: TextStyle(fontSize: size * 0.34)),
              ],
            )
          : _player(),
    );
  }

  Widget _player() {
    final last = _sequence.length - 1;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final idx = (_controller.value * last).round().clamp(0, last);
        return Image.asset(
          _sequence[idx],
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => Center(
            child: Icon(Icons.hearing,
                size: widget.size * 0.4, color: Colors.white70),
          ),
        );
      },
    );
  }
}
