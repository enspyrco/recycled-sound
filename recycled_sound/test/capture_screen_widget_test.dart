import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:recycled_sound/features/capture/presentation/capture_screen.dart';
import 'package:recycled_sound/features/capture/presentation/widgets/sweep_guide.dart';

/// Widget tests for CaptureScreen rendering (#287, #487).
///
/// Covers the visible states the screen can be in without a real camera: the
/// loading spinner before the controller is ready, the idle video-sweep UI once
/// a fake platform reports the camera initialized, and the idle→recording
/// transition when the record button is tapped. The fake here is "happy path":
/// its initializeCamera resolves immediately (no gating), unlike the lifecycle
/// test which parks it.
///
/// The [SweepGuide] turntable precaches 24 asset frames; under the real event
/// loop (`runAsync`) those loads execute against the headless flutter_test
/// asset bundle and error — an *expected* condition the widget handles via
/// errorBuilder (production loads them fine). [ignoreTurntableAssetErrors]
/// filters only those at the `FlutterError.onError` source, delegating every
/// other error to the binding so genuine failures still fail the test.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _ReadyCameraPlatform fake;

  setUp(() {
    fake = _ReadyCameraPlatform();
    CameraPlatform.instance = fake;
  });

  Widget wrap() => const ProviderScope(
        child: MaterialApp(home: CaptureScreen()),
      );

  /// Bring the fake camera to ready on the real event loop, then pump a frame
  /// so the published-controller setState commits and the live UI renders.
  Future<void> settleReady(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }

  testWidgets('shows a loading spinner before the camera is ready',
      (tester) async {
    await tester.pumpWidget(wrap());
    // First frame: init is async, controller not yet published.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders the idle video-sweep UI once the camera is ready',
      (tester) async {
    ignoreTurntableAssetErrors();
    await tester.pumpWidget(wrap());
    await settleReady(tester);

    // The live camera UI is up (no spinner blocking the body) and the sweep
    // guidance + record prompt are present.
    expect(find.byType(CameraPreview), findsOneWidget);
    expect(find.byType(SweepGuide), findsOneWidget);
    expect(find.text('Video sweep · no live ID'), findsOneWidget);
    expect(find.text('Tap to record the sweep'), findsOneWidget);
    // Idle, so no in-progress affordance yet.
    expect(find.text('Tap to finish'), findsNothing);
  });

  testWidgets('tapping record starts the sweep and shows the finish control',
      (tester) async {
    ignoreTurntableAssetErrors();
    await tester.pumpWidget(wrap());
    await settleReady(tester);

    // The label is not the tap target — only the circular button is — so tap
    // it by key. startVideoRecording → startVideoCapturing is async; flush.
    await tester.tap(find.byKey(const Key('sweep-record-button')));
    await tester.pump();
    await tester.pump();

    expect(fake.startedRecording, isTrue,
        reason: 'tapping record must start the platform video capture');
    expect(find.text('Tap to finish'), findsOneWidget);
    expect(find.text('Tap to record the sweep'), findsNothing);
  });
}

/// Suppress the SweepGuide turntable's expected asset-load errors at the
/// `FlutterError.onError` source (the 24 frames aren't in the headless
/// flutter_test bundle; production loads them and errorBuilder degrades to an
/// icon). Delegates all OTHER errors to the binding's reporter, and restores
/// the original handler at test teardown.
void ignoreTurntableAssetErrors() {
  final prior = FlutterError.onError;
  FlutterError.onError = (details) {
    final s = details.exceptionAsString();
    if (s.contains('Unable to load asset') ||
        s.contains('failed to precache')) {
      return;
    }
    prior?.call(details);
  };
  addTearDown(() => FlutterError.onError = prior);
}

/// A fake [CameraPlatform] whose camera initializes immediately and supports
/// video capture — used for the render + record-transition tests where we only
/// care about the steady "ready" UI and the start-recording state flip.
class _ReadyCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  int _nextId = 0;
  final Map<int, StreamController<CameraInitializedEvent>> _events = {};

  /// Flips true once [startVideoCapturing] (the call CameraController.
  /// startVideoRecording delegates to) runs.
  bool startedRecording = false;

  @override
  Future<List<CameraDescription>> availableCameras() async => const [
        CameraDescription(
          name: 'back',
          lensDirection: CameraLensDirection.back,
          sensorOrientation: 90,
        ),
      ];

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async {
    final id = _nextId++;
    _events[id] = StreamController<CameraInitializedEvent>.broadcast();
    return id;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      _events[cameraId]!.stream;

  // A never-emitting, never-closing stream: the controller does `.first` on
  // this, and an *empty* stream would make `.first` throw "No element".
  final _errors = StreamController<CameraErrorEvent>.broadcast();

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream<DeviceOrientationChangedEvent>.empty();

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    _events[cameraId]!.add(
      CameraInitializedEvent(
        cameraId,
        1920,
        1080,
        ExposureMode.auto,
        true,
        FocusMode.auto,
        true,
      ),
    );
  }

  @override
  Future<void> setFocusMode(int cameraId, FocusMode mode) async {}

  @override
  Future<void> setFocusPoint(int cameraId, Point<double>? point) async {}

  // CameraController.startVideoRecording() delegates to startVideoCapturing.
  @override
  Future<void> startVideoCapturing(VideoCaptureOptions options) async {
    startedRecording = true;
  }

  @override
  Future<XFile> stopVideoRecording(int cameraId) async {
    startedRecording = false;
    return XFile('/tmp/fake_sweep.mp4');
  }

  @override
  Widget buildPreview(int cameraId) => const SizedBox.shrink();

  @override
  Future<void> dispose(int cameraId) async {
    await _events.remove(cameraId)?.close();
  }
}
