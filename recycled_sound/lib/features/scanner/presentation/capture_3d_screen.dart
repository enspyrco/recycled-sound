import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../data/object_capture_channel.dart';
import '../data/point_cloud.dart';
import 'widgets/point_cloud_viewer.dart';

/// 3D capture screen with two modes:
///
/// **Mode A (ObjectCaptureView):** Apple's native 3D capture UI with
/// built-in point cloud — if ObjectCaptureSession.isSupported.
///
/// **Mode B (arkit_plugin depth):** LiDAR depth frame point cloud built
/// frame-by-frame — fallback for devices that support LiDAR but not
/// Object Capture, or when Object Capture fails.
class Capture3dScreen extends StatefulWidget {
  const Capture3dScreen({super.key, this.deviceName});

  final String? deviceName;

  @override
  State<Capture3dScreen> createState() => _Capture3dScreenState();
}

enum _Mode { checking, objectCapture, depthCloud, viewing, notSupported }

class _Capture3dScreenState extends State<Capture3dScreen> {
  final _capture = ObjectCaptureChannel.instance;
  _Mode _mode = _Mode.checking;

  // ── Object Capture state ──────────────────────────────────────────────
  String _ocState = 'idle'; // Object Capture session state
  String _guidance = 'Point at the hearing aid';
  int _shotsTaken = 0;
  bool _sessionStarted = false;

  // ── Depth cloud state (fallback) ──────────────────────────────────────
  ARKitController? _arkitController;
  final _cloud = PointCloudBuilder(maxPoints: 80000, voxelSize: 0.0005);
  Timer? _captureTimer;
  int _framesCaptured = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _checkSupport();
  }

  Future<void> _checkSupport() async {
    // Try Object Capture first
    final supported = await _capture.isSupported();
    if (supported) {
      _capture.startListening();
      _capture.onStateChanged = (s) {
        if (mounted) setState(() => _ocState = s);
      };
      _capture.onProgress = (shots, _) {
        if (mounted) setState(() => _shotsTaken = shots);
      };
      _capture.onGuidance = (g) {
        if (mounted) setState(() => _guidance = g);
      };
      _capture.onModelReady = (path) {
        if (mounted) setState(() => _ocState = 'done');
      };

      if (mounted) setState(() => _mode = _Mode.objectCapture);
      setState(() => _sessionStarted = true);
      try {
        await _capture.startSession();
      } catch (e) {
        // Object Capture failed — fall back to depth cloud
        if (mounted) setState(() => _mode = _Mode.depthCloud);
      }
    } else {
      // No Object Capture — use depth cloud fallback
      if (mounted) setState(() => _mode = _Mode.depthCloud);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _captureTimer?.cancel();
    _arkitController?.dispose();
    _capture.cancel();
    _capture.stopListening();
    super.dispose();
  }

  // ── Depth cloud methods ───────────────────────────────────────────────

  void _onARKitViewCreated(ARKitController controller) {
    _arkitController = controller;
    setState(() => _guidance = 'Point at the hearing aid and slowly orbit');

    _captureTimer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      _captureDepthFrame();
    });
  }

  Future<void> _captureDepthFrame() async {
    if (_disposed || _arkitController == null) return;
    if (_mode != _Mode.depthCloud) return;

    try {
      final snapshot = await _arkitController!.snapshotWithDepthData();
      if (snapshot == null || _disposed) return;

      final depthList = snapshot['depthMap'];
      final depthWidth = snapshot['depthWidth'] as int?;
      final depthHeight = snapshot['depthHeight'] as int?;
      final intrinsics = snapshot['intrinsics'] as String?;

      if (depthList == null || depthWidth == null || depthHeight == null) return;

      final Float32List depthData;
      if (depthList is Float32List) {
        depthData = depthList;
      } else if (depthList is List) {
        depthData = Float32List.fromList(
          depthList.map((e) => (e as num).toDouble()).toList(),
        );
      } else {
        return;
      }

      double fx = 500, fy = 500;
      double cx = depthWidth / 2, cy = depthHeight / 2;
      if (intrinsics != null) {
        final parts = intrinsics.split(RegExp(r'[\s,]+'));
        if (parts.length >= 4) {
          final pfx = double.tryParse(parts[0]);
          final pfy = double.tryParse(parts[1]);
          final pcx = double.tryParse(parts[2]);
          final pcy = double.tryParse(parts[3]);
          if (pfx != null && pfx.isFinite && pfx > 0) fx = pfx;
          if (pfy != null && pfy.isFinite && pfy > 0) fy = pfy;
          if (pcx != null && pcx.isFinite) cx = pcx;
          if (pcy != null && pcy.isFinite) cy = pcy;
        }
      }

      final pov = await _arkitController!.pointOfViewTransform();
      final cameraPose = pov ?? Matrix4.identity();

      _cloud.addFrame(
        depthData: depthData,
        depthWidth: depthWidth,
        depthHeight: depthHeight,
        fx: fx,
        fy: fy,
        cx: cx,
        cy: cy,
        cameraPose: cameraPose,
      );

      if (!_disposed && mounted) {
        setState(() {
          _framesCaptured++;
          _guidance = '${_cloud.count} points from $_framesCaptured frames';
        });
      }
    } catch (e) {
      if (mounted && _framesCaptured == 0) {
        setState(() => _guidance = 'Depth error: $e');
      }
    }
  }

  void _finishDepthScan() {
    _captureTimer?.cancel();
    setState(() {
      _mode = _Mode.viewing;
      _guidance = '${_cloud.count} points — spin it!';
    });
  }

  void _rescan() {
    _cloud.clear();
    setState(() {
      _mode = _Mode.depthCloud;
      _framesCaptured = 0;
      _guidance = 'Point at the hearing aid';
    });
    _captureTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _captureDepthFrame(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        top: false,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Main content by mode
            if (_mode == _Mode.checking)
              const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              )
            else if (_mode == _Mode.objectCapture && _sessionStarted && Platform.isIOS)
              const UiKitView(
                viewType: 'object-capture-view',
                creationParamsCodec: StandardMessageCodec(),
              )
            else if (_mode == _Mode.depthCloud)
              ARKitSceneView(
                configuration: ARKitConfiguration.depthTracking,
                onARKitViewCreated: _onARKitViewCreated,
              )
            else if (_mode == _Mode.viewing)
              PointCloudViewer(cloud: _cloud, pointSize: 2.5)
            else if (_mode == _Mode.notSupported)
              _buildNotSupported(),

            // Header
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 8,
              right: 8,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: AppColors.white),
                    onPressed: () => context.pop(),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _mode == _Mode.viewing ? '3D MODEL' : '3D SCAN',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.white,
                            letterSpacing: 2.0,
                          ),
                        ),
                        if (widget.deviceName != null)
                          Text(
                            widget.deviceName!,
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              color: AppColors.white.withValues(alpha: 0.6),
                            ),
                          ),
                      ],
                    ),
                  ),
                  // Mode badge
                  if (_mode == _Mode.depthCloud || _mode == _Mode.objectCapture)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _mode == _Mode.objectCapture ? 'OBJECT CAPTURE' : 'LIDAR DEPTH',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: AppColors.white,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                ],
              ),
            ),

            // Bottom controls
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xDD000000)],
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(20, 32, 20, 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _guidance.toUpperCase(),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: Color(0x99FFFFFF),
                        letterSpacing: 1.0,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),

                    // Depth cloud progress
                    if (_mode == _Mode.depthCloud) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: (_cloud.count / 30000).clamp(0.0, 1.0),
                          backgroundColor: const Color(0x22FFFFFF),
                          color: _cloud.count > 10000
                              ? AppColors.success
                              : AppColors.primary,
                          minHeight: 3,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_cloud.count > 5000)
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _finishDepthScan,
                            icon: const Icon(Icons.threed_rotation, size: 18),
                            label: Text('View 3D Model (${_cloud.count} points)'),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.success,
                              foregroundColor: AppColors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                    ],

                    // Object Capture controls
                    if (_mode == _Mode.objectCapture && _shotsTaken >= 3)
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () async {
                            setState(() => _guidance = 'Processing...');
                            await _capture.finish();
                          },
                          icon: const Icon(Icons.check, size: 18),
                          label: Text('Finish ($_shotsTaken shots)'),
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.success,
                            foregroundColor: AppColors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),

                    // Viewing controls
                    if (_mode == _Mode.viewing)
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _rescan,
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('Rescan'),
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0x33FFFFFF),
                                foregroundColor: AppColors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => context.pop(),
                              icon: const Icon(Icons.check, size: 18),
                              label: const Text('Done'),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppColors.primary,
                                foregroundColor: AppColors.white,
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotSupported() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.view_in_ar, color: AppColors.textMuted, size: 48),
            SizedBox(height: 16),
            Text(
              '3D Capture Not Available',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: AppColors.white),
            ),
            SizedBox(height: 8),
            Text(
              'Requires iPhone 12 Pro or later with LiDAR.',
              style: TextStyle(color: Color(0x99FFFFFF)),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
