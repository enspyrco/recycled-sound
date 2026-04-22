import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../data/object_capture_channel.dart';

/// 3D capture screen — embeds Apple's native ObjectCaptureView which
/// shows the live camera with built-in point cloud, object detection,
/// guided orbit indicators, and shot location markers.
///
/// All the heavy 3D rendering is done by Apple's RealityKit. Flutter
/// provides the HUD overlay, controls, and navigation.
class Capture3dScreen extends StatefulWidget {
  const Capture3dScreen({super.key, this.deviceName});

  final String? deviceName;

  @override
  State<Capture3dScreen> createState() => _Capture3dScreenState();
}

class _Capture3dScreenState extends State<Capture3dScreen> {
  final _capture = ObjectCaptureChannel.instance;

  String _state = 'idle';
  String _guidance = 'Point at the hearing aid';
  int _shotsTaken = 0;
  bool _isSupported = false;
  bool _checking = true;
  bool _sessionStarted = false;
  String? _modelPath;

  @override
  void initState() {
    super.initState();
    _capture.startListening();
    _capture.onStateChanged = (state) {
      if (mounted) setState(() => _state = state);
    };
    _capture.onProgress = (shots, _) {
      if (mounted) setState(() => _shotsTaken = shots);
    };
    _capture.onGuidance = (guidance) {
      if (mounted) setState(() => _guidance = guidance);
    };
    _capture.onModelReady = (path) {
      if (mounted) {
        setState(() {
          _modelPath = path;
          _state = 'done';
        });
      }
    };

    _checkAndStart();
  }

  Future<void> _checkAndStart() async {
    final supported = await _capture.isSupported();
    if (mounted) {
      setState(() {
        _isSupported = supported;
        _checking = false;
      });
    }
    if (supported) {
      // Start the session — this also registers the native platform view
      await _capture.startSession();
      if (mounted) setState(() => _sessionStarted = true);
    }
  }

  Future<void> _finishCapture() async {
    setState(() => _state = 'finishing');
    await _capture.finish();
  }

  @override
  void dispose() {
    _capture.cancel();
    _capture.stopListening();
    super.dispose();
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
            // Native ObjectCaptureView — Apple's built-in 3D capture UI
            // with point cloud, object detection, and guided orbit
            if (_sessionStarted && Platform.isIOS)
              const UiKitView(
                viewType: 'object-capture-view',
                creationParamsCodec: StandardMessageCodec(),
              )
            else if (_checking)
              const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              )
            else if (!_isSupported)
              _buildNotSupported()
            else
              Container(color: Colors.black),

            // Header overlay
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
                        const Text(
                          '3D SCAN',
                          style: TextStyle(
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
                  // Shot counter badge
                  if (_shotsTaken > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.success.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        '$_shotsTaken SHOTS',
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
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
                    // Guidance text from Apple's session
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
                    const SizedBox(height: 8),
                    // State badge
                    Text(
                      _state.toUpperCase(),
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10,
                        color: _state == 'capturing'
                            ? AppColors.success
                            : const Color(0x66FFFFFF),
                        letterSpacing: 1.0,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Finish button
                    if (_shotsTaken >= 3 &&
                        _state != 'finishing' &&
                        _state != 'done')
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _finishCapture,
                          icon: const Icon(Icons.check, size: 18),
                          label: const Text('Finish Capture'),
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

                    if (_state == 'finishing')
                      const Text(
                        'PROCESSING...',
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.primary,
                          letterSpacing: 2.0,
                        ),
                      ),

                    if (_state == 'done')
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => context.pop(_modelPath),
                          icon: const Icon(Icons.threed_rotation, size: 18),
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
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotSupported() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.view_in_ar, color: AppColors.textMuted, size: 48),
            const SizedBox(height: 16),
            Text(
              '3D Capture Not Available',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: AppColors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Requires iPhone 12 Pro or later with LiDAR.',
              style: TextStyle(
                color: AppColors.white.withValues(alpha: 0.6),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
