// Excluded from coverage: camera composition stack; wraps live preview widgets
// coverage:ignore-file
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// State of a captured feature through its lifecycle.
enum CaptureState { capturing, uploading, processing, done, error }

/// A single captured feature with its upload/processing state.
class CapturedFeature {
  CapturedFeature({
    required this.id,
    required this.label,
    required this.field,
    this.imagePath,
    this.state = CaptureState.capturing,
    this.uploadProgress = 0.0,
  });

  final String id;

  /// Display label, e.g. "OTICON". Mutable to allow corrections.
  String label;

  /// Which field this is: "MAKE", "MODEL", etc.
  final String field;

  /// Local path to captured image.
  String? imagePath;

  CaptureState state;

  /// Upload progress 0.0–1.0.
  double uploadProgress;
}

/// Stack of captured feature thumbnails on the right edge of the scanner.
///
/// Each thumbnail shows the field name, detected value, and upload status.
/// New captures slide in from the left with a scale animation.
class CaptureStack extends StatelessWidget {
  const CaptureStack({super.key, required this.captures});

  final List<CapturedFeature> captures;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < captures.length; i++)
          _CaptureCard(
            capture: captures[i],
            index: i,
          ),
      ],
    );
  }
}

class _CaptureCard extends StatefulWidget {
  const _CaptureCard({required this.capture, required this.index});

  final CapturedFeature capture;
  final int index;

  @override
  State<_CaptureCard> createState() => _CaptureCardState();
}

class _CaptureCardState extends State<_CaptureCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;
  late final Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    _scaleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutBack),
    );
    _slideAnimation =
        Tween<Offset>(begin: const Offset(-1.0, 0.0), end: Offset.zero)
            .animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
    );

    // Stagger the entrance based on index
    Future.delayed(Duration(milliseconds: widget.index * 50), () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capture = widget.capture;

    final statusIcon = switch (capture.state) {
      CaptureState.capturing => Icons.camera_alt,
      CaptureState.uploading => Icons.cloud_upload_outlined,
      CaptureState.processing => Icons.auto_awesome,
      CaptureState.done => Icons.check_circle,
      CaptureState.error => Icons.error_outline,
    };

    final statusColor = switch (capture.state) {
      CaptureState.done => AppColors.success,
      CaptureState.error => AppColors.error,
      _ => const Color(0x99FFFFFF),
    };

    return SlideTransition(
      position: _slideAnimation,
      child: ScaleTransition(
        scale: _scaleAnimation,
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xCC000000),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: capture.state == CaptureState.done
                  ? AppColors.success.withValues(alpha: 0.5)
                  : const Color(0x33FFFFFF),
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Upload progress ring or status icon
              if (capture.state == CaptureState.uploading)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    value: capture.uploadProgress,
                    strokeWidth: 1.5,
                    color: AppColors.primary,
                    backgroundColor: const Color(0x33FFFFFF),
                  ),
                )
              else
                Icon(statusIcon, size: 14, color: statusColor),
              const SizedBox(width: 6),
              // Field name
              Text(
                capture.field,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                  color: Color(0x77FFFFFF),
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 6),
              // Value
              Text(
                capture.label,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: capture.state == CaptureState.done
                      ? AppColors.success
                      : AppColors.white,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
