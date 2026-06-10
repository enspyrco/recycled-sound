// Excluded from coverage: live scanner progress overlay; bound to capture stream
// coverage:ignore-file
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Vertical progress bar on the left edge of the scanner.
///
/// Shows aggregate upload/processing progress for all captured features.
/// Fills from bottom to top, like a power meter charging up.
class ProgressRail extends StatelessWidget {
  const ProgressRail({
    super.key,
    required this.progress,
    required this.captureCount,
    required this.totalExpected,
  });

  /// Overall progress 0.0–1.0.
  final double progress;

  /// How many features have been captured so far.
  final int captureCount;

  /// How many total captures we expect (e.g., 2 for brand + model).
  final int totalExpected;

  @override
  Widget build(BuildContext context) {
    if (captureCount == 0) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Counter
        Text(
          '$captureCount/$totalExpected',
          style: const TextStyle(
            fontFamily: 'monospace',
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: Color(0x77FFFFFF),
          ),
        ),
        const SizedBox(height: 4),
        // Vertical bar
        SizedBox(
          width: 4,
          height: 120,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: RotatedBox(
              quarterTurns: -1, // bottom-to-top fill
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: const Color(0x22FFFFFF),
                color: progress >= 1.0
                    ? AppColors.success
                    : AppColors.primary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        // Status icon
        Icon(
          progress >= 1.0 ? Icons.check_circle : Icons.cloud_sync_outlined,
          size: 12,
          color: progress >= 1.0
              ? AppColors.success
              : const Color(0x55FFFFFF),
        ),
      ],
    );
  }
}
