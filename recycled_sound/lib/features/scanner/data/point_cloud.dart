// Excluded from coverage: 3D point-cloud builder; consumes ARKit LiDAR depth frames
// coverage:ignore-file
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// A 3D point with colour from the LiDAR depth map.
class CloudPoint {
  const CloudPoint(this.x, this.y, this.z, this.r, this.g, this.b);

  final double x, y, z;
  final int r, g, b;
}

/// Accumulates depth frames into a 3D point cloud.
///
/// Each call to [addFrame] back-projects depth pixels to 3D world
/// coordinates using the camera intrinsics and pose, then downsamples
/// to keep the total point count manageable for real-time rendering.
class PointCloudBuilder {
  PointCloudBuilder({this.maxPoints = 50000, this.voxelSize = 0.002});

  /// Maximum points to keep (oldest are pruned).
  final int maxPoints;

  /// Voxel grid size in metres for deduplication.
  final double voxelSize;

  final List<CloudPoint> _points = [];
  final Set<int> _voxelKeys = {};

  List<CloudPoint> get points => _points;
  int get count => _points.length;

  /// Bounding box centre — used to centre the cloud for rendering.
  Vector3 get centre {
    if (_points.isEmpty) return Vector3.zero();
    var minX = double.infinity, maxX = double.negativeInfinity;
    var minY = double.infinity, maxY = double.negativeInfinity;
    var minZ = double.infinity, maxZ = double.negativeInfinity;
    for (final p in _points) {
      if (p.x < minX) minX = p.x;
      if (p.x > maxX) maxX = p.x;
      if (p.y < minY) minY = p.y;
      if (p.y > maxY) maxY = p.y;
      if (p.z < minZ) minZ = p.z;
      if (p.z > maxZ) maxZ = p.z;
    }
    return Vector3(
      (minX + maxX) / 2,
      (minY + maxY) / 2,
      (minZ + maxZ) / 2,
    );
  }

  /// Bounding box radius — used for auto-scaling.
  double get radius {
    if (_points.isEmpty) return 0.1;
    final c = centre;
    var maxDist = 0.0;
    for (final p in _points) {
      final d = math.sqrt(
        (p.x - c.x) * (p.x - c.x) +
            (p.y - c.y) * (p.y - c.y) +
            (p.z - c.z) * (p.z - c.z),
      );
      if (d > maxDist) maxDist = d;
    }
    return maxDist.clamp(0.01, 10.0);
  }

  /// Add a depth frame to the cloud.
  ///
  /// [depthData] is a Float32List of depth values (metres), row-major.
  /// [depthWidth] and [depthHeight] are the depth map dimensions.
  /// [fx], [fy], [cx], [cy] are camera intrinsics.
  /// [cameraPose] is the 4x4 world transform of the camera.
  /// [imageBytes] optional BGRA image for point colours.
  void addFrame({
    required Float32List depthData,
    required int depthWidth,
    required int depthHeight,
    required double fx,
    required double fy,
    required double cx,
    required double cy,
    required Matrix4 cameraPose,
    Uint8List? imageBytes,
    int imageWidth = 0,
    int imageHeight = 0,
  }) {
    // Subsample — take every Nth pixel. Smaller step = more detail.
    // At close range (15-50cm) we want fine detail for small objects.
    final step = math.max(2, math.sqrt(depthWidth * depthHeight / 5000).round());

    for (var py = 0; py < depthHeight; py += step) {
      for (var px = 0; px < depthWidth; px += step) {
        final depth = depthData[py * depthWidth + px];
        if (depth.isNaN || depth.isInfinite) continue;
        // Only capture 15–50cm — hand-held distance.
        // Cuts out desk, walls, background. Focuses on the hearing aid.
        if (depth <= 0.15 || depth > 0.50) continue;

        // Back-project to camera space
        final camX = (px - cx) * depth / fx;
        final camY = (py - cy) * depth / fy;
        final camZ = depth;

        // Transform to world space
        final worldPoint = cameraPose.transformed3(
          Vector3(camX, camY, camZ),
        );

        // Voxel deduplication
        final voxelKey = _voxelKey(worldPoint.x, worldPoint.y, worldPoint.z);
        if (_voxelKeys.contains(voxelKey)) continue;
        _voxelKeys.add(voxelKey);

        // Sample colour from image if available
        int r = 180, g = 220, b = 255; // default: light blue
        if (imageBytes != null && imageWidth > 0 && imageHeight > 0) {
          final imgX = (px * imageWidth / depthWidth).round().clamp(0, imageWidth - 1);
          final imgY = (py * imageHeight / depthHeight).round().clamp(0, imageHeight - 1);
          final offset = (imgY * imageWidth + imgX) * 4;
          if (offset + 3 < imageBytes.length) {
            // BGRA format
            b = imageBytes[offset];
            g = imageBytes[offset + 1];
            r = imageBytes[offset + 2];
          }
        }

        _points.add(CloudPoint(worldPoint.x, worldPoint.y, worldPoint.z, r, g, b));
      }
    }

    // Prune oldest points if over limit
    if (_points.length > maxPoints) {
      final excess = _points.length - maxPoints;
      _points.removeRange(0, excess);
    }
  }

  int _voxelKey(double x, double y, double z) {
    final vx = (x / voxelSize).round();
    final vy = (y / voxelSize).round();
    final vz = (z / voxelSize).round();
    // Simple spatial hash
    return vx * 73856093 ^ vy * 19349663 ^ vz * 83492791;
  }

  void clear() {
    _points.clear();
    _voxelKeys.clear();
  }
}
