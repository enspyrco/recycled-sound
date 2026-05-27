import 'dart:io';

import 'package:camera/camera.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../devices/data/incoming_device_repository.dart';
import '../../devices/data/models/device.dart';
import '../../devices/providers/device_providers.dart';
import '../data/focus_control.dart';
import 'capture_slot.dart';
import 'widgets/capture_guide_hand.dart';

/// Guided photo-capture flow — a peer to the scanner (`/scan`).
///
/// Steps the volunteer through [CaptureSlot.sequence], one shot per slot, then
/// saves the set to a new `incoming/` device via
/// [IncomingDeviceRepository.createIncoming], which uploads each local file
/// atomically to `scans/{uid}/incoming/{id}/{slotName}.jpg`. The filename is
/// the *slot identity*, not a position — so skipping a slot can never shift
/// another slot's photo onto the wrong anatomical label.
///
/// Camera lifecycle mirrors the scanner: a [WidgetsBindingObserver] tears the
/// controller down on background and rebuilds on resume, so the camera never
/// leaks. Unlike the scanner, there is no image stream — this flow only needs
/// preview + [CameraController.takePicture].
class CaptureScreen extends ConsumerStatefulWidget {
  const CaptureScreen({super.key});

  @override
  ConsumerState<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends ConsumerState<CaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _cameraReady = false;
  String? _cameraError;
  bool _isCapturing = false;
  bool _saving = false;
  bool _disposed = false;

  /// Active slot the volunteer is shooting.
  int _currentIndex = 0;

  /// Captured local file paths, keyed by slot index. Sparse: a slot may be
  /// skipped, so we key by index rather than using a list.
  final Map<int, String> _captured = {};

  CaptureSlot get _currentSlot => CaptureSlot.sequence[_currentIndex];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _stopCamera();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // Tear the camera down on background — but only if one is live.
      if (_controller != null) _stopCamera();
    } else if (state == AppLifecycleState.resumed) {
      // Rebuild on resume when we have no live controller. The previous guard
      // returned early whenever _controller was null — which is *exactly* the
      // post-background state _stopCamera() leaves us in — so the camera never
      // recovered after a lock screen, notification, or the permission dialog.
      if (_controller == null) _initCamera();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw Exception('No cameras available');
      if (_disposed) return;

      final controller = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (_disposed) {
        await controller.dispose();
        return;
      }

      // Prefer the native `.near` autofocus range restriction for these
      // small, close-held subjects. If it applies, we deliberately do NOT
      // also drive focus mode/point from Dart — both sides locking the shared
      // AVCaptureDevice could race. Fall back to centre AF only when the
      // native path is unavailable (Android, older iPhones, simulator).
      final nearApplied = await FocusControl.setNearFocus();
      if (!nearApplied) {
        try {
          await controller.setFocusMode(FocusMode.auto);
          await controller.setFocusPoint(const Offset(0.5, 0.5));
        } catch (_) {
          // Some devices/simulators reject focus config — non-fatal.
        }
      }

      setState(() {
        _controller = controller;
        _cameraReady = true;
        _cameraError = null;
      });
    } catch (e) {
      if (_disposed) return;
      setState(() => _cameraError = e.toString());
    }
  }

  Future<void> _stopCamera() async {
    final c = _controller;
    _controller = null;
    _cameraReady = false;
    await c?.dispose();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (_isCapturing || controller == null || !controller.value.isInitialized) {
      return;
    }
    setState(() => _isCapturing = true);
    try {
      final xFile = await controller.takePicture();
      if (!mounted || _disposed) return;
      HapticFeedback.lightImpact();
      setState(() {
        _captured[_currentIndex] = xFile.path;
        // Advance to the next un-shot slot if one remains.
        if (_currentIndex < CaptureSlot.sequence.length - 1) {
          _currentIndex++;
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Capture failed: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  void _selectSlot(int index) => setState(() => _currentIndex = index);

  void _retakeCurrent() => setState(() => _captured.remove(_currentIndex));

  /// Captured local paths keyed by slot *identity* (the enum name), not
  /// position. The storage filename is derived from this key, so a skipped
  /// slot can never shift another slot's photo onto the wrong label.
  Map<String, String> get _capturedBySlot => {
        for (var i = 0; i < CaptureSlot.sequence.length; i++)
          if (_captured[i] != null) CaptureSlot.sequence[i].name: _captured[i]!,
      };

  Future<void> _save() async {
    final slotPhotos = _capturedBySlot;
    if (slotPhotos.isEmpty || _saving) return;
    setState(() => _saving = true);

    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final repo = ref.read(incomingDeviceRepositoryProvider);

    // Capture has no scan result, so identification fields start blank; the
    // record exists to hold the photos and gets its specs filled in later.
    const draft = DraftDevice(brand: '', model: '');

    try {
      final id = await repo.createIncoming(draft, namedPhotoPaths: slotPhotos);
      messenger.showSnackBar(
        SnackBar(
          content: Text('Saved ${slotPhotos.length} photos · $id'),
          backgroundColor: AppColors.success,
        ),
      );
      router.go('/devices/$id');
    } on FirebaseException catch (e) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(PersistErrorKind.fromCode(e.code).userMessage),
          backgroundColor: AppColors.error,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _saving = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(PersistErrorKind.unknown.userMessage),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: _cameraError != null
            ? _ErrorView(message: _cameraError!)
            : !_cameraReady || _controller == null
                ? const Center(child: CircularProgressIndicator())
                : _buildCamera(context),
      ),
    );
  }

  Widget _buildCamera(BuildContext context) {
    final capturedCount = _captured.length;
    final total = CaptureSlot.sequence.length;
    final hasCurrentShot = _captured[_currentIndex] != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        Center(child: CameraPreview(_controller!)),

        // Top bar: close + progress.
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => context.go('/'),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$capturedCount / $total',
                  style: AppTypography.body.copyWith(color: Colors.white),
                ),
              ),
            ],
          ),
        ),

        // Slot guidance — the cartoony hand coaches the orientation, the text
        // names the shot.
        Positioned(
          top: 64,
          left: 16,
          right: 16,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CaptureGuideHand(slot: _currentSlot),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _currentSlot.title,
                      style: AppTypography.h2.copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _currentSlot.hint,
                      style: AppTypography.body.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // Bottom controls: thumbnail strip + capture/retake + save.
        Positioned(
          bottom: 16,
          left: 0,
          right: 0,
          child: Column(
            children: [
              _SlotStrip(
                captured: _captured,
                currentIndex: _currentIndex,
                onSelect: _selectSlot,
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Retake (only when current slot already has a shot).
                  SizedBox(
                    width: 72,
                    child: hasCurrentShot
                        ? TextButton(
                            onPressed: _retakeCurrent,
                            child: const Text(
                              'Retake',
                              style: TextStyle(color: Colors.white),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  _ShutterButton(
                    busy: _isCapturing,
                    onTap: _capture,
                  ),
                  // Save (enabled once at least one photo exists).
                  SizedBox(
                    width: 72,
                    child: capturedCount > 0
                        ? TextButton(
                            onPressed: _saving ? null : _save,
                            child: _saving
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Text(
                                    'Save',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Horizontal strip of slot chips — captured slots show a check, the active
/// slot is ringed. Tapping jumps to that slot (to re-shoot or fill a skip).
class _SlotStrip extends StatelessWidget {
  const _SlotStrip({
    required this.captured,
    required this.currentIndex,
    required this.onSelect,
  });

  final Map<int, String> captured;
  final int currentIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: CaptureSlot.sequence.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final slot = CaptureSlot.sequence[i];
          final shot = captured[i];
          final active = i == currentIndex;
          return GestureDetector(
            onTap: () => onSelect(i),
            child: Container(
              width: 56,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: active ? AppColors.accent : Colors.white24,
                  width: active ? 2 : 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    shot != null ? Icons.check_circle : Icons.circle_outlined,
                    color: shot != null ? AppColors.success : Colors.white54,
                    size: 20,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    slot.title,
                    style: AppTypography.caption.copyWith(
                      color: Colors.white,
                      fontSize: 9,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white,
          border: Border.all(color: AppColors.accent, width: 4),
        ),
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(20),
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: AppColors.accent,
                ),
              )
            : const Icon(Icons.camera_alt, color: AppColors.accent, size: 32),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography, color: Colors.white54, size: 48),
            const SizedBox(height: 16),
            Text(
              'Camera unavailable',
              style: AppTypography.h3.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              style: AppTypography.caption.copyWith(color: Colors.white54),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => context.go('/'),
              child: const Text('Back'),
            ),
          ],
        ),
      ),
    );
  }
}
