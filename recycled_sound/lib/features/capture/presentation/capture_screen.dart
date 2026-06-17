import 'package:camera/camera.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
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
import 'widgets/sweep_guide.dart';

/// Guided video-sweep capture flow — a peer to the scanner (`/scan`).
///
/// The volunteer records ONE slow ~10-15s rotation of the hearing aid in front
/// of the camera while mirroring the [SweepGuide] turntable, then the clip is
/// saved to a new device via [IncomingDeviceRepository.createIncomingVideo],
/// which uploads it to `captures/{uid}/{deviceId}/sweep_{ts}.mp4`. This is the
/// deployment-faithful successor to the legacy 6-still [CaptureSlot] sequence:
/// the live scanner sees a continuous frame stream, so a rotating sweep matches
/// what the scanner actually sees and is a superset of the stills (individual
/// frames can be extracted offline with `ffmpeg -vf fps=2`). The [CaptureSlot]
/// enum is retained as a legacy type for any still-based consumers; this screen
/// no longer drives it.
///
/// Camera lifecycle mirrors the scanner: a [WidgetsBindingObserver] tears the
/// controller down on background and rebuilds on resume, so the camera never
/// leaks. Unlike the scanner, there is no image stream — this flow drives
/// preview + [CameraController.startVideoRecording]/`stopVideoRecording`, whose
/// encoding is hardware-accelerated and off the UI thread. Backgrounding
/// mid-sweep disposes the controller and abandons the in-progress clip (the
/// recording resets on resume).
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

  /// True while a video sweep is actively recording (between
  /// `startVideoRecording` and `stopVideoRecording`). Drives the [SweepGuide]
  /// turntable + progress ring and the start/stop button state.
  bool _recording = false;

  /// True while the recorded clip is uploading + the device doc is being
  /// written. Locks the UI so a second tap can't double-submit.
  bool _uploading = false;
  bool _disposed = false;

  /// How long one capture sweep runs — the [SweepGuide] progress ring fills
  /// once over this, then auto-stops + uploads. ~12s gives several readable
  /// passes of the sideways medial-face label.
  static const Duration _sweepDuration = Duration(seconds: 12);

  /// Camera lifecycle uses TWO guards that answer different questions:
  ///
  /// [_initGen] — a monotonic token answering "is my result still wanted?".
  /// Each init captures the value live at schedule time; a teardown bumps it.
  /// An init whose token is stale after an `await` disposes its half-built
  /// controller and bails, so it never publishes after a background.
  ///
  /// [_cameraOp] — a chained future answering "is the camera free to use?".
  /// Every init/teardown is appended to it, so they run strictly one at a
  /// time. Without this, a resume could call `initialize()` while a superseded
  /// init's `initialize()`/`dispose()` is still touching the native device —
  /// a transient camera-in-use error. The token alone can't prevent that; it
  /// only stops the stale result from being kept.
  int _initGen = 0;
  Future<void> _cameraOp = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleInit();
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _scheduleStop();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _scheduleStop();
    } else if (state == AppLifecycleState.resumed) {
      _scheduleInit();
    }
  }

  /// Claim a fresh generation NOW (so any in-flight init is immediately stale)
  /// and append the init behind whatever camera op is already running.
  ///
  /// The trailing `catchError` is load-bearing: a bare `.then` chain stays
  /// permanently rejected if ANY queued op throws (e.g. a native `dispose()`
  /// failing mid-transition), and every later callback would then silently
  /// never run — the camera would be dead for good. Swallowing here keeps the
  /// queue self-healing; per-op errors are already surfaced via `_cameraError`.
  void _scheduleInit() {
    final gen = ++_initGen;
    _cameraOp = _cameraOp.then((_) => _initCamera(gen)).catchError((_) {});
  }

  /// Invalidate the current generation NOW, then append the teardown. The
  /// synchronous bump means an init already awaiting sees the staleness at its
  /// next checkpoint even before the chained teardown runs.
  void _scheduleStop() {
    _initGen++;
    _cameraOp = _cameraOp.then((_) => _stopCamera()).catchError((_) {});
  }

  Future<void> _initCamera(int gen) async {
    // Superseded before we even started, or a controller is already live.
    if (_disposed || gen != _initGen || _controller != null) return;

    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (_disposed || gen != _initGen) return;
      if (cameras.isEmpty) throw Exception('No cameras available');

      // Pick the rear ULTRA-WIDE lens preferentially: hearing aids are held
      // ~5–8 cm from the lens to fill the frame, which is well inside the
      // wide-angle camera's ~10 cm minimum focus distance. The ultra-wide
      // camera (iPhone 11+, all 12+ models) does macro down to ~2 cm — the
      // same lens iOS's own Camera app uses for "Macro mode". Falling back
      // through wide → first-back → first preserves behaviour on older non-Pro
      // iPhones that lack ultra-wide.
      //
      // Enumeration order is not a contract, so filter by `lensType` /
      // `lensDirection` rather than indexing. `firstOrNull` keeps the
      // priority cascade a flat null-coalesce chain — each predicate runs
      // at most once.
      final backCameras = cameras
          .where((c) => c.lensDirection == CameraLensDirection.back)
          .toList(growable: false);
      final desc = backCameras
              .where((c) => c.lensType == CameraLensType.ultraWide)
              .firstOrNull ??
          backCameras
              .where((c) => c.lensType == CameraLensType.wide)
              .firstOrNull ??
          backCameras.firstOrNull ??
          cameras.first;

      controller = CameraController(
        desc,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (_disposed || gen != _initGen) {
        await _safeDispose(controller);
        return;
      }

      // Prefer the native `.near` autofocus range restriction for these
      // small, close-held subjects. If it applies, we deliberately do NOT
      // also drive focus mode/point from Dart — both sides locking the shared
      // AVCaptureDevice could race. Fall back to centre AF only when the
      // native path is unavailable (Android, older iPhones, simulator).
      // On iOS the camera plugin reports `CameraDescription.name` as the
      // AVCaptureDevice uniqueID — pass it so `.near` is applied to the exact
      // lens we just opened, not a sibling lens guessed by the native side.
      // Use `defaultTargetPlatform` (not `dart:io` Platform) so this file
      // doesn't add yet another Web-incompatible reference; the channel
      // itself is iOS-only anyway and resolves to false elsewhere.
      final nearApplied = await FocusControl.setNearFocus(
        deviceUniqueId:
            defaultTargetPlatform == TargetPlatform.iOS ? desc.name : null,
      );
      if (_disposed || gen != _initGen) {
        await _safeDispose(controller);
        return;
      }
      if (!nearApplied) {
        try {
          await controller.setFocusMode(FocusMode.auto);
          await controller.setFocusPoint(const Offset(0.5, 0.5));
        } catch (_) {
          // Some devices/simulators reject focus config — non-fatal.
        }
        // These awaits are another background window — re-check before publish.
        if (_disposed || gen != _initGen) {
          await _safeDispose(controller);
          return;
        }
      }

      if (!mounted) {
        await _safeDispose(controller);
        return;
      }
      setState(() {
        _controller = controller;
        _cameraReady = true;
        _cameraError = null;
      });
    } catch (e) {
      // Dispose a controller we built but never published, then surface.
      if (controller != null && controller != _controller) {
        await _safeDispose(controller);
      }
      if (_disposed || gen != _initGen) return;
      if (mounted) setState(() => _cameraError = e.toString());
    }
  }

  Future<void> _stopCamera() async {
    // Generation was already bumped synchronously by _scheduleStop; this runs
    // serialized behind any in-flight init, so the device is free when we
    // dispose and the next scheduled init only starts after this returns.
    final c = _controller;
    if (c == null) return;
    _controller = null;
    _cameraReady = false;
    // Backgrounding mid-sweep abandons the in-progress clip — reset the flag so
    // the UI shows "ready to record" (not a stuck recording state) on resume.
    // Disposing a controller that is still recording is the plugin's concern;
    // _safeDispose swallows any error it raises.
    _recording = false;
    // Unmount CameraPreview BEFORE disposing the hardware, so the widget tree
    // never holds a disposed controller (an assertion crash on background).
    if (mounted) setState(() {});
    await _safeDispose(c);
  }

  /// Dispose a controller, swallowing any platform error. A failed dispose is
  /// best-effort cleanup; it must not escape and poison the [_cameraOp] queue
  /// or surface as a spurious capture error.
  Future<void> _safeDispose(CameraController controller) async {
    try {
      await controller.dispose();
    } catch (_) {
      // Best-effort — nothing actionable if the native release fails.
    }
  }

  /// Begin a video sweep. No-op unless the camera is ready and we're not
  /// already recording or uploading. The [SweepGuide] (driven by [_recording])
  /// starts demonstrating the rotation and fills its progress ring over
  /// [_sweepDuration], at which point [_finishSweep] auto-fires.
  Future<void> _startSweep() async {
    final controller = _controller;
    if (_recording ||
        _uploading ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    // Claim the recording state SYNCHRONOUSLY, before the await, so a bouncy
    // double-tap can't fire two concurrent startVideoRecording calls into the
    // plugin (a CameraException). The second tap sees `_recording == true` (and
    // the button has already flipped to Stop) and bails. If the hardware start
    // throws, release the claim. The SweepGuide ring starts a few hundred ms
    // before the hardware confirms — negligible against a ~12s sweep.
    setState(() => _recording = true);
    try {
      await controller.startVideoRecording();
      if (!mounted || _disposed) return;
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (mounted) {
        setState(() => _recording = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not start recording: $e'),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  /// Stop the recording and upload the clip. Fires from two paths: the
  /// volunteer tapping Stop (a shorter-but-valid clip), or [SweepGuide]'s
  /// `onComplete` when the ring fills. Guards re-entrancy: the second caller
  /// sees `_recording == false` and bails, so the clip is never stopped twice.
  Future<void> _finishSweep() async {
    final controller = _controller;
    if (!_recording || controller == null) return;
    setState(() {
      _recording = false;
      _uploading = true;
    });

    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final repo = ref.read(incomingDeviceRepositoryProvider);

    try {
      final clip = await controller.stopVideoRecording();
      HapticFeedback.lightImpact();

      // Capture has no scan result, so identification fields start blank; the
      // record exists to hold the sweep clip and gets its specs filled in later.
      const draft = DraftDevice(brand: '', model: '');
      final id =
          await repo.createIncomingVideo(draft, localVideoPath: clip.path);

      // If the volunteer tapped close (`context.go('/')`) while the upload was
      // in flight, the screen is gone — the clip + doc still persisted (good),
      // but we must NOT yank navigation back to the device or post a snackbar
      // on a defunct messenger. Leaving mid-upload = continue silently.
      if (!mounted || _disposed) return;
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Sweep saved'),
          backgroundColor: AppColors.success,
        ),
      );
      router.go('/devices/$id');
    } on FirebaseException catch (e) {
      if (!mounted || _disposed) return;
      setState(() => _uploading = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(PersistErrorKind.fromCode(e.code).userMessage),
          backgroundColor: AppColors.error,
        ),
      );
    } catch (_) {
      if (!mounted || _disposed) return;
      setState(() => _uploading = false);
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
    return Stack(
      fit: StackFit.expand,
      children: [
        Center(child: CameraPreview(_controller!)),

        // Top bar: close + mode label.
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
              // Mode reminder: this flow records a clip, it does not try to
              // read the device live. Naming that here prevents the "no info,
              // unlike scanning" confusion from the entry point onward.
              Flexible(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    'Video sweep · no live ID',
                    style:
                        AppTypography.caption.copyWith(color: Colors.white70),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Centre guidance: the 3D turntable demonstrates the rotation to mirror
        // and the ring shows sweep progress while recording. Purely cosmetic —
        // it never blocks or throws into the capture pipeline.
        Center(
          child: SweepGuide(
            running: _recording,
            sweepDuration: _sweepDuration,
            onComplete: _finishSweep,
          ),
        ),

        // Bottom control: Start → Stop → uploading spinner.
        Positioned(
          bottom: 32,
          left: 0,
          right: 0,
          child: Center(child: _buildSweepControl()),
        ),
      ],
    );
  }

  /// The single primary action, whose shape tracks the capture state:
  ///   * uploading → a labelled spinner (UI locked until navigation),
  ///   * recording → a red Stop button (ends the sweep early but valid),
  ///   * idle      → a Start button that begins the sweep.
  Widget _buildSweepControl() {
    if (_uploading) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white),
          ),
          const SizedBox(height: 8),
          Text(
            'Saving sweep…',
            style: AppTypography.caption.copyWith(color: Colors.white70),
          ),
        ],
      );
    }

    final recording = _recording;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          key: const Key('sweep-record-button'),
          onTap: recording ? _finishSweep : _startSweep,
          child: Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              border: Border.all(
                color: recording ? AppColors.error : AppColors.accent,
                width: 5,
              ),
            ),
            child: Center(
              child: recording
                  // A rounded square = the universal "stop recording" glyph.
                  ? Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: AppColors.error,
                        borderRadius: BorderRadius.circular(6),
                      ),
                    )
                  // A filled dot = the universal "start recording" glyph.
                  : Container(
                      width: 34,
                      height: 34,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppColors.error,
                      ),
                    ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          recording ? 'Tap to finish' : 'Tap to record the sweep',
          style: AppTypography.caption.copyWith(color: Colors.white70),
        ),
      ],
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
