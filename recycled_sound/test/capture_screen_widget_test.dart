import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:recycled_sound/features/capture/presentation/capture_screen.dart';
import 'package:recycled_sound/features/capture/presentation/capture_slot.dart';

/// Widget tests for CaptureScreen rendering (#287).
///
/// Covers the two visible states the screen can be in without a real camera:
/// the loading spinner before the controller is ready, and — once a fake
/// platform reports the camera initialized — the live capture UI with its slot
/// strip. The fake here is "happy path": its initializeCamera resolves
/// immediately (no gating), unlike the lifecycle test which parks it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    CameraPlatform.instance = _ReadyCameraPlatform();
  });

  Widget wrap() => const ProviderScope(
        child: MaterialApp(home: CaptureScreen()),
      );

  testWidgets('shows a loading spinner before the camera is ready',
      (tester) async {
    await tester.pumpWidget(wrap());
    // First frame: init is async, controller not yet published.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('renders the capture UI with a slot chip per CaptureSlot once '
      'the camera is ready', (tester) async {
    await tester.pumpWidget(wrap());
    // CameraController.initialize() resolves through a broadcast-stream event,
    // whose delivery needs a REAL event loop — tester.pump() alone only drains
    // the fake-async microtask queue and the camera never reports ready. Settle
    // the init on the real loop, then pump one frame to publish the new state.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

    // The live camera UI is up (no spinner blocking the body).
    expect(find.byType(CameraPreview), findsOneWidget);

    // The slot strip renders one tappable chip per slot — and the chip shows
    // the slot's short title. The active (first) slot's title also appears in
    // the large guidance header, so every slot title is present at least once.
    for (final slot in CaptureSlot.sequence) {
      expect(find.text(slot.title), findsWidgets,
          reason: 'slot "${slot.name}" should render its title');
    }

    // Progress counter starts at 0 / total.
    expect(find.text('0 / ${CaptureSlot.sequence.length}'), findsOneWidget);
  });
}

/// A fake [CameraPlatform] whose camera initializes immediately — used for the
/// render tests where we only care about the steady "ready" UI.
class _ReadyCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  int _nextId = 0;
  final Map<int, StreamController<CameraInitializedEvent>> _events = {};

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

  @override
  Widget buildPreview(int cameraId) => const SizedBox.shrink();

  @override
  Future<void> dispose(int cameraId) async {
    await _events.remove(cameraId)?.close();
  }
}
