// Excluded from coverage: CustomPainter animation tied to camera frame stream
// coverage:ignore-file
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Describes a single capture animation in progress.
class CaptureAnimation {
  CaptureAnimation({
    required this.id,
    required this.sourceRect,
    required this.label,
    this.imagePath,
  }) : createdAt = DateTime.now();

  final String id;

  /// Where the detection was on screen (camera overlay coordinates).
  final Rect sourceRect;

  final String label;
  final String? imagePath;
  final DateTime createdAt;
}

/// A completed thumbnail in the dock row.
class DockThumbnail {
  const DockThumbnail({
    required this.id,
    required this.label,
    this.imagePath,
  });

  final String id;
  final String label;
  final String? imagePath;
}

/// Orchestrates the capture animation sequence:
/// 1. Red border appears at detection location
/// 2. Border shrinks inward with trailing particles
/// 3. Flash white on capture
/// 4. Thumbnail slides to dock position
///
/// Sits as an overlay on top of the camera preview.
class CaptureAnimatorOverlay extends StatelessWidget {
  const CaptureAnimatorOverlay({
    super.key,
    required this.animations,
    required this.dockedThumbnails,
    required this.dockPosition,
  });

  /// Active animations in progress.
  final List<CaptureAnimation> animations;

  /// Completed thumbnails in the dock row.
  final List<DockThumbnail> dockedThumbnails;

  /// Where the dock row sits (bottom-right area).
  final Offset dockPosition;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Active capture animations
        for (final anim in animations)
          _CaptureSequence(key: ValueKey(anim.id), animation: anim),

        // Thumbnail dock row (bottom-right, above HUD + button)
        if (dockedThumbnails.isNotEmpty)
          Positioned(
            right: 12,
            bottom: 240, // above the HUD + Review button + capture controls
            child: _ThumbnailDock(thumbnails: dockedThumbnails),
          ),
      ],
    );
  }
}

/// Runs the full capture animation sequence for one detection.
class _CaptureSequence extends StatefulWidget {
  const _CaptureSequence({super.key, required this.animation});

  final CaptureAnimation animation;

  @override
  State<_CaptureSequence> createState() => _CaptureSequenceState();
}

class _CaptureSequenceState extends State<_CaptureSequence>
    with TickerProviderStateMixin {
  late final AnimationController _shrinkController;
  late final AnimationController _flashController;
  late final AnimationController _slideController;

  // Particle positions (generated once)
  late final List<_Particle> _particles;

  static const _shrinkDuration = Duration(milliseconds: 500);
  static const _flashDuration = Duration(milliseconds: 150);
  static const _slideDuration = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();

    _shrinkController = AnimationController(
      vsync: this,
      duration: _shrinkDuration,
    );
    _flashController = AnimationController(
      vsync: this,
      duration: _flashDuration,
    );
    _slideController = AnimationController(
      vsync: this,
      duration: _slideDuration,
    );

    // Generate particles along the border
    final rng = math.Random(widget.animation.id.hashCode);
    _particles = List.generate(16, (i) {
      final side = i % 4; // 0=top, 1=right, 2=bottom, 3=left
      final pos = rng.nextDouble();
      return _Particle(
        side: side,
        position: pos,
        speed: 0.5 + rng.nextDouble() * 1.5,
        size: 2.0 + rng.nextDouble() * 3.0,
      );
    });

    _runSequence();
  }

  Future<void> _runSequence() async {
    // Phase 1: Shrink
    await _shrinkController.forward();
    // Phase 2: Flash
    await _flashController.forward();
    await _flashController.reverse();
    // Phase 3: Slide to dock
    await _slideController.forward();
  }

  @override
  void dispose() {
    _shrinkController.dispose();
    _flashController.dispose();
    _slideController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final source = widget.animation.sourceRect;
    final screenSize = MediaQuery.of(context).size;

    // Dock target: bottom-right
    final dockRect = Rect.fromLTWH(
      screenSize.width - 60,
      screenSize.height - 200,
      44,
      44,
    );

    return AnimatedBuilder(
      animation: Listenable.merge([
        _shrinkController,
        _flashController,
        _slideController,
      ]),
      builder: (context, _) {
        final shrinkT = Curves.easeInOut.transform(_shrinkController.value);
        final flashT = _flashController.value;
        final slideT = Curves.easeInOutCubic.transform(_slideController.value);

        // During shrink: source rect shrinks to a 44x44 thumbnail at centre
        final shrunkSize = 44.0;
        final currentRect = Rect.lerp(
          source,
          Rect.fromCenter(
            center: source.center,
            width: shrunkSize,
            height: shrunkSize,
          ),
          shrinkT,
        )!;

        // During slide: move from shrunk position to dock
        final finalRect = Rect.lerp(currentRect, dockRect, slideT)!;

        // Border colour: red → green as it shrinks
        final borderColor = Color.lerp(
          const Color(0xFFEF4444), // red
          AppColors.success,
          shrinkT,
        )!;

        // Border width shrinks
        final borderWidth = 2.5 - 1.0 * shrinkT;

        // Overall opacity: fade out at end of slide
        final opacity = slideT > 0.8 ? 1.0 - (slideT - 0.8) / 0.2 : 1.0;

        if (opacity <= 0) return const SizedBox.shrink();

        return Stack(
          children: [
            // Trailing particles (during shrink phase)
            if (_shrinkController.isAnimating)
              ...List.generate(_particles.length, (i) {
                final p = _particles[i];
                final particleT = (shrinkT * p.speed).clamp(0.0, 1.0);
                final particleOpacity =
                    (1.0 - particleT) * 0.8 * opacity;

                if (particleOpacity <= 0) return const SizedBox.shrink();

                // Calculate particle position along the current border
                final offset = _particleOffset(source, p, particleT);

                return Positioned(
                  left: offset.dx - p.size / 2,
                  top: offset.dy - p.size / 2,
                  child: Opacity(
                    opacity: particleOpacity,
                    child: Container(
                      width: p.size,
                      height: p.size,
                      decoration: BoxDecoration(
                        color: borderColor,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                );
              }),

            // The shrinking/sliding border + thumbnail
            Positioned.fromRect(
              rect: finalRect,
              child: Opacity(
                opacity: opacity,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: borderColor.withValues(alpha: opacity),
                      width: borderWidth,
                    ),
                    borderRadius: BorderRadius.circular(
                      4 + 4 * shrinkT, // rounds as it shrinks
                    ),
                    color: flashT > 0
                        ? Colors.white.withValues(alpha: flashT * 0.8)
                        : null,
                  ),
                  child: shrinkT > 0.8 &&
                          widget.animation.imagePath != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(
                            4 + 4 * shrinkT,
                          ),
                          child: Image.file(
                            File(widget.animation.imagePath!),
                            fit: BoxFit.cover,
                          ),
                        )
                      : null,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Calculate where a particle should be, drifting outward from the border.
  Offset _particleOffset(Rect rect, _Particle p, double t) {
    // Start position: along the border
    final Offset start;
    final Offset drift;

    switch (p.side) {
      case 0: // top edge
        start = Offset(rect.left + rect.width * p.position, rect.top);
        drift = Offset(0, -20 * t); // drift up
      case 1: // right edge
        start = Offset(rect.right, rect.top + rect.height * p.position);
        drift = Offset(20 * t, 0); // drift right
      case 2: // bottom edge
        start = Offset(rect.left + rect.width * p.position, rect.bottom);
        drift = Offset(0, 20 * t); // drift down
      default: // left edge
        start = Offset(rect.left, rect.top + rect.height * p.position);
        drift = Offset(-20 * t, 0); // drift left
    }

    return start + drift;
  }
}

class _Particle {
  const _Particle({
    required this.side,
    required this.position,
    required this.speed,
    required this.size,
  });

  final int side; // 0=top, 1=right, 2=bottom, 3=left
  final double position; // 0.0–1.0 along that side
  final double speed; // multiplier
  final double size; // pixel size
}

/// Horizontal row of completed thumbnails.
class _ThumbnailDock extends StatelessWidget {
  const _ThumbnailDock({required this.thumbnails});

  final List<DockThumbnail> thumbnails;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < thumbnails.length; i++) ...[
          if (i > 0) const SizedBox(width: 4),
          _DockTile(thumbnail: thumbnails[i]),
        ],
      ],
    );
  }
}

class _DockTile extends StatelessWidget {
  const _DockTile({required this.thumbnail});

  final DockThumbnail thumbnail;

  void _showFullImage(BuildContext context) {
    if (thumbnail.imagePath == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          color: const Color(0xEE000000),
          padding: const EdgeInsets.all(24),
          child: Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(thumbnail.imagePath!),
                fit: BoxFit.contain,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showFullImage(context),
      child: Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: AppColors.success.withValues(alpha: 0.6),
          width: 1.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (thumbnail.imagePath != null)
              Image.file(
                File(thumbnail.imagePath!),
                fit: BoxFit.cover,
              )
            else
              Container(
                color: const Color(0xFF1A1A1A),
                child: const Icon(
                  Icons.check,
                  color: AppColors.success,
                  size: 18,
                ),
              ),
            // Label overlay at bottom
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 1),
                color: const Color(0xCC000000),
                child: Text(
                  thumbnail.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 7,
                    fontWeight: FontWeight.w600,
                    color: AppColors.success,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }
}
