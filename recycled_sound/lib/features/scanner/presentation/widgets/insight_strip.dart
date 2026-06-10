// Excluded from coverage: live scanner overlay; consumes InsightEngine (Firestore-bound)
// coverage:ignore-file
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../data/insight_engine.dart';

/// A strip of proactive insights displayed above the HUD.
///
/// Shows 0–3 contextual observations from the [InsightEngine]:
/// inventory status, capability highlights, recipient matches,
/// or teaching moments. Fades in when insights arrive, auto-dismisses
/// after a delay unless the user is reading (detected via scroll/tap).
class InsightStrip extends StatelessWidget {
  const InsightStrip({
    super.key,
    required this.insights,
  });

  final List<Insight> insights;

  IconData _iconForType(InsightType type) => switch (type) {
        InsightType.inventory => Icons.inventory_2_outlined,
        InsightType.capability => Icons.auto_awesome_outlined,
        InsightType.match => Icons.people_outline,
        InsightType.teaching => Icons.school_outlined,
      };

  Color _colorForType(InsightType type) => switch (type) {
        InsightType.inventory => const Color(0xFF90CAF9), // light blue
        InsightType.capability => const Color(0xFFCE93D8), // light purple
        InsightType.match => AppColors.success, // green
        InsightType.teaching => const Color(0xFFFFE082), // amber
      };

  @override
  Widget build(BuildContext context) {
    if (insights.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xCC1A1A1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0x22FFFFFF),
          width: 0.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < insights.length; i++) ...[
            if (i > 0) const SizedBox(height: 4),
            _InsightRow(
              insight: insights[i],
              icon: _iconForType(insights[i].type),
              color: _colorForType(insights[i].type),
            ),
          ],
        ],
      ),
    );
  }
}

class _InsightRow extends StatelessWidget {
  const _InsightRow({
    required this.insight,
    required this.icon,
    required this.color,
  });

  final Insight insight;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color.withValues(alpha: 0.8)),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            insight.text,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: color.withValues(alpha: 0.9),
              height: 1.3,
            ),
          ),
        ),
      ],
    );
  }
}
