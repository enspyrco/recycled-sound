// Excluded from coverage: boot-screen pulse animation; AnimationController-driven
// coverage:ignore-file
import 'package:flutter/material.dart';

/// Horizontal gauge fading green → orange → red as `load` rises 0.0 → 1.0.
///
/// When [coolDownNeeded] is true the gauge pulses to draw the eye — the OS
/// is telling us we're one step away from forced throttling, which on a
/// frame-budget-sensitive scanner is information the user should *see*.
class ThermalGauge extends StatefulWidget {
  const ThermalGauge({
    super.key,
    required this.load,
    required this.label,
    required this.subLabel,
    required this.coolDownNeeded,
    this.height = 14,
  });

  final double load;
  final String label;
  final String subLabel;
  final bool coolDownNeeded;
  final double height;

  @override
  State<ThermalGauge> createState() => _ThermalGaugeState();
}

class _ThermalGaugeState extends State<ThermalGauge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    if (widget.coolDownNeeded) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant ThermalGauge old) {
    super.didUpdateWidget(old);
    // Run the pulse only while cooldown is needed — otherwise the controller
    // ticks at 60Hz on a screen designed to be lightweight, which is exactly
    // the cosmetic-feature-eats-frame-budget anti-pattern the project's
    // CLAUDE.md frame-budget governance bans.
    if (widget.coolDownNeeded && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.coolDownNeeded && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 1.0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final clamped = widget.load.clamp(0.0, 1.0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              widget.label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: Color(0xFF6B7280),
              ),
            ),
            Text(
              widget.subLabel,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: widget.coolDownNeeded
                    ? const Color(0xFFB91C1C)
                    : const Color(0xFF374151),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        AnimatedBuilder(
          animation: _pulse,
          builder: (context, _) {
            // Pulse only when cooldown is needed; otherwise hold steady at 1.0.
            final pulseFactor =
                widget.coolDownNeeded ? (0.55 + 0.45 * _pulse.value) : 1.0;
            return SizedBox(
              height: widget.height,
              child: Stack(
                children: [
                  // Gradient track.
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(widget.height / 2),
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFF10B981), // green
                          Color(0xFFFBBF24), // amber
                          Color(0xFFF97316), // orange
                          Color(0xFFEF4444), // red
                        ],
                        stops: [0.0, 0.45, 0.75, 1.0],
                      ),
                    ),
                  ),
                  // Mask: cover the unfilled portion with a translucent grey.
                  Align(
                    alignment: Alignment.centerRight,
                    child: FractionallySizedBox(
                      widthFactor: 1.0 - clamped,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFFE5E7EB),
                          borderRadius: BorderRadius.only(
                            topRight: Radius.circular(widget.height / 2),
                            bottomRight: Radius.circular(widget.height / 2),
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Indicator marker.
                  FractionallySizedBox(
                    widthFactor: clamped,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Opacity(
                        opacity: pulseFactor,
                        child: Container(
                          width: 3,
                          decoration: const BoxDecoration(
                            color: Color(0xFF111827),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}
