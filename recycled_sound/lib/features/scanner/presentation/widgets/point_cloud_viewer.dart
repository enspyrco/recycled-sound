// Excluded from coverage: 3D point-cloud rendering; LiDAR-fed CustomPainter
// coverage:ignore-file
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' hide Colors;

import '../../data/point_cloud.dart';

/// Interactive 3D point cloud viewer.
///
/// Renders a [PointCloudBuilder]'s points as coloured dots projected
/// from 3D to 2D. Supports touch-to-rotate (pan) and pinch-to-zoom.
/// Auto-rotates when not being touched.
class PointCloudViewer extends StatefulWidget {
  const PointCloudViewer({
    super.key,
    required this.cloud,
    this.autoRotate = true,
    this.pointSize = 2.0,
    this.backgroundColor = Colors.black,
  });

  final PointCloudBuilder cloud;
  final bool autoRotate;
  final double pointSize;
  final Color backgroundColor;

  @override
  State<PointCloudViewer> createState() => _PointCloudViewerState();
}

class _PointCloudViewerState extends State<PointCloudViewer>
    with SingleTickerProviderStateMixin {
  double _rotationX = 0.0; // pitch (vertical drag)
  double _rotationY = 0.0; // yaw (horizontal drag)
  double _zoom = 1.0;
  bool _userInteracting = false;

  late final AnimationController _autoRotateController;

  @override
  void initState() {
    super.initState();
    _autoRotateController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _autoRotateController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: (_) => _userInteracting = true,
      onPanEnd: (_) => _userInteracting = false,
      onPanUpdate: (details) {
        setState(() {
          _rotationY += details.delta.dx * 0.01;
          _rotationX += details.delta.dy * 0.01;
          _rotationX = _rotationX.clamp(-math.pi / 2, math.pi / 2);
        });
      },
      onScaleUpdate: (details) {
        if (details.pointerCount >= 2) {
          setState(() {
            _zoom = (_zoom * details.scale).clamp(0.3, 5.0);
          });
        }
      },
      child: AnimatedBuilder(
        animation: _autoRotateController,
        builder: (context, _) {
          // Auto-rotate when not being touched
          final autoAngle = widget.autoRotate && !_userInteracting
              ? _autoRotateController.value * 2 * math.pi
              : 0.0;

          return CustomPaint(
            painter: _PointCloudPainter(
              points: widget.cloud.points,
              centre: widget.cloud.centre,
              radius: widget.cloud.radius,
              rotationX: _rotationX,
              rotationY: _rotationY + autoAngle,
              zoom: _zoom,
              pointSize: widget.pointSize,
              backgroundColor: widget.backgroundColor,
            ),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _PointCloudPainter extends CustomPainter {
  _PointCloudPainter({
    required this.points,
    required this.centre,
    required this.radius,
    required this.rotationX,
    required this.rotationY,
    required this.zoom,
    required this.pointSize,
    required this.backgroundColor,
  });

  final List<CloudPoint> points;
  final Vector3 centre;
  final double radius;
  final double rotationX;
  final double rotationY;
  final double zoom;
  final double pointSize;
  final Color backgroundColor;

  @override
  void paint(Canvas canvas, Size size) {
    // Background
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = backgroundColor,
    );

    if (points.isEmpty) {
      // "Waiting for depth data" text
      final tp = TextPainter(
        text: const TextSpan(
          text: 'SCANNING...',
          style: TextStyle(
            color: Color(0x66FFFFFF),
            fontSize: 14,
            fontFamily: 'monospace',
            letterSpacing: 2.0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(size.width / 2 - tp.width / 2, size.height / 2 - tp.height / 2),
      );
      return;
    }

    final cx = size.width / 2;
    final cy = size.height / 2;
    final scale = (size.shortestSide / 2) * zoom / radius.clamp(0.01, 10.0);

    // Build rotation matrix
    final rotX = Matrix4.rotationX(rotationX);
    final rotY = Matrix4.rotationY(rotationY);
    final rotation = rotY.multiplied(rotX);

    // Project and depth-sort
    final projected = <_ProjectedPoint>[];
    for (final p in points) {
      // Centre the point
      final v = Vector3(p.x - centre.x, p.y - centre.y, p.z - centre.z);

      // Rotate
      final rotated = rotation.transformed3(v);

      // Simple perspective projection
      final depth = rotated.z;
      final perspectiveFactor = 1.0 / (1.0 + depth * 0.5);
      final screenX = cx + rotated.x * scale * perspectiveFactor;
      final screenY = cy - rotated.y * scale * perspectiveFactor; // flip Y

      // Skip points behind camera or off screen
      if (screenX < -50 ||
          screenX > size.width + 50 ||
          screenY < -50 ||
          screenY > size.height + 50) {
        continue;
      }

      projected.add(_ProjectedPoint(
        x: screenX,
        y: screenY,
        depth: depth,
        r: p.r,
        g: p.g,
        b: p.b,
        size: pointSize * perspectiveFactor,
      ));
    }

    // Sort back-to-front for proper occlusion
    projected.sort((a, b) => b.depth.compareTo(a.depth));

    // Draw points
    for (final p in projected) {
      // Depth-based alpha: closer points are brighter
      final alpha = (0.3 + 0.7 * (1.0 - (p.depth + radius) / (2 * radius)))
          .clamp(0.1, 1.0);

      canvas.drawCircle(
        Offset(p.x, p.y),
        p.size,
        Paint()
          ..color = Color.fromRGBO(p.r, p.g, p.b, alpha)
          ..style = PaintingStyle.fill,
      );
    }

    // Point count label
    final countText = TextPainter(
      text: TextSpan(
        text: '${points.length} POINTS',
        style: const TextStyle(
          color: Color(0x88FFFFFF),
          fontSize: 10,
          fontFamily: 'monospace',
          letterSpacing: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    countText.paint(canvas, Offset(12, size.height - 24));
  }

  @override
  bool shouldRepaint(covariant _PointCloudPainter old) => true;
}

class _ProjectedPoint {
  const _ProjectedPoint({
    required this.x,
    required this.y,
    required this.depth,
    required this.r,
    required this.g,
    required this.b,
    required this.size,
  });

  final double x, y, depth, size;
  final int r, g, b;
}
