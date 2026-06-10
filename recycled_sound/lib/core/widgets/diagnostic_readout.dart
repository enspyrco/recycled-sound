// Excluded from coverage: boot-screen ticker; periodic timers loop pumpAndSettle
// coverage:ignore-file
import 'dart:async';

import 'package:flutter/material.dart';

/// Auto-cycling tickertape of `(label, value)` pairs.
///
/// Shows one fact at a time with a flash-in / fade-out so the loading screen
/// reads like a system diagnostic boot rather than dead waiting time.
class DiagnosticReadout extends StatefulWidget {
  const DiagnosticReadout({
    super.key,
    required this.entries,
    this.cycle = const Duration(milliseconds: 900),
  });

  final List<MapEntry<String, String>> entries;
  final Duration cycle;

  @override
  State<DiagnosticReadout> createState() => _DiagnosticReadoutState();
}

class _DiagnosticReadoutState extends State<DiagnosticReadout> {
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.cycle, (_) {
      if (!mounted || widget.entries.isEmpty) return;
      setState(() => _index = (_index + 1) % widget.entries.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.entries.isEmpty) {
      return const SizedBox.shrink();
    }
    // entries can shrink between rebuilds (cooldown clears, low-power
    // toggles off) so a stale _index can overshoot. Modulo wraps safely
    // without forcing a setState during build.
    final safeIndex = _index % widget.entries.length;
    final entry = widget.entries[safeIndex];
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.2),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: Container(
        key: ValueKey(_index),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              entry.key,
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.4,
                color: Color(0xFF6B7280),
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                entry.value,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF111827),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
