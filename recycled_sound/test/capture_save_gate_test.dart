import 'dart:async';
import 'dart:math';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:recycled_sound/features/capture/presentation/capture_screen.dart';
import 'package:recycled_sound/features/capture/providers/upload_job.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';

import 'support/google_fonts_test_asset.dart';

/// Behavioural tests for CaptureScreen's save gate (#288, follow-up to #104).
///
/// The widget test in capture_camera_lifecycle_test pins the box-number ENTRY
/// UI; this pins the *save-gate invariant*: a capture with photos but no box
/// number is blocked, and once a box is entered the upload is kicked with the
/// box carried into the device. We drive the real production `_save` through a
/// fake camera whose `takePicture` returns a dummy file (so a shutter tap
/// populates `_captured`) and a recording [UploadJobController] that captures
/// what `start` was called with instead of running a real upload.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fontReady = installGoogleFontsAssetMock();

  late _ShutterCameraPlatform fake;
  // Nullable, not late: the override closure only runs when the upload provider
  // is first READ. A blocked save never reads it, so `recorder` staying null is
  // itself proof that no upload was kicked.
  _RecordingUploadController? recorder;

  // The real _capture fires _runOcr, which opens the ML Kit recognizer, and
  // CaptureScreen.dispose() then closes it — both hit a platform channel that
  // isn't registered in the harness. Stub it: processImage returns empty text,
  // close is a no-op. (OCR reading nothing is the right test posture anyway —
  // we're exercising the save gate, not OCR.)
  const ocrChannel = MethodChannel('google_mlkit_text_recognizer');

  setUp(() {
    fake = _ShutterCameraPlatform();
    recorder = null;
    CameraPlatform.instance = fake;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ocrChannel, (call) async {
      if (call.method.contains('start')) {
        return <String, dynamic>{'text': '', 'blocks': <dynamic>[]};
      }
      return null; // close + anything else
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ocrChannel, null);
  });

  Future<void> pump(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/capture',
      routes: [
        GoRoute(path: '/capture', builder: (_, _) => const CaptureScreen()),
        GoRoute(
          path: '/capture/uploading',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('UPLOADING SCREEN'))),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uploadJobProvider.overrideWith((ref) {
            final r = _RecordingUploadController(ref);
            recorder = r;
            return r;
          }),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
  }

  /// Let the camera reach ready on the real loop, then commit the state.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
  }

  Future<void> takeOneShot(WidgetTester tester) async {
    // The shutter is the round capture button — the only camera_alt icon in the
    // live UI. Tapping it runs the real _capture → takePicture path.
    await tester.tap(find.byIcon(Icons.camera_alt));
    await settle(tester);
  }

  testWidgets(
      'saving with photos but no box opens the dialog; cancelling blocks the '
      'save with a nudge and never starts an upload', (tester) async {
    await pump(tester);
    await settle(tester); // camera ready

    await takeOneShot(tester);

    // Save with no box entered → the details dialog is forced open.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Device details'), findsOneWidget);

    // Cancel without entering a box.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // Blocked: the nudge shows, no upload kicked, still on the capture screen.
    expect(find.text('Enter the box number before saving'), findsOneWidget);
    expect(recorder?.started ?? false, isFalse,
        reason: 'an empty box must not start an upload (provider never read)');
    expect(find.text('UPLOADING SCREEN'), findsNothing);
  }, skip: !fontReady);

  testWidgets(
      'with a box entered, save starts the upload carrying the box and routes '
      'to the progress screen', (tester) async {
    await pump(tester);
    await settle(tester);

    await takeOneShot(tester);

    // Enter the box up front via the details bar.
    await tester.tap(find.text('Tap to add box number (required)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'b07');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // Now save → upload kicked with the trimmed/uppercased box, and we route on.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(recorder?.started, isTrue);
    expect(recorder?.box, 'B07');
    expect(recorder?.draft?.location, 'B07',
        reason: 'the box must land on the device as its location');
    expect(recorder?.paths, isNotEmpty,
        reason: 'the captured shot is handed to the upload by slot key');
    expect(find.text('UPLOADING SCREEN'), findsOneWidget);
  }, skip: !fontReady);

  testWidgets('a tapped colour swatch carries onto the saved device (#22)',
      (tester) async {
    await pump(tester);
    await settle(tester);

    await takeOneShot(tester);

    // Open details, enter the box, then pick a colour from the swatches rather
    // than typing it (the swatch names match the register's ColourClassifier
    // palette, so the value is consistent).
    await tester.tap(find.text('Tap to add box number (required)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'B07');
    await tester.tap(find.text('Black')); // a palette swatch label
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(recorder?.draft?.colour, 'Black',
        reason: 'the chosen swatch name is the device colour');
  }, skip: !fontReady);
}

/// Records what [start] was called with instead of running a real upload.
class _RecordingUploadController extends UploadJobController {
  _RecordingUploadController(super.ref);

  bool started = false;
  DraftDevice? draft;
  Map<String, String>? paths;
  String? box;

  @override
  Future<void> start({
    required DraftDevice draft,
    required Map<String, String> namedPhotoPaths,
    required String box,
  }) async {
    started = true;
    this.draft = draft;
    paths = namedPhotoPaths;
    this.box = box;
  }
}

/// A ready-immediately fake camera whose [takePicture] returns a dummy file so
/// a shutter tap populates the capture screen's `_captured` map.
class _ShutterCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  int _nextId = 0;
  final Map<int, StreamController<CameraInitializedEvent>> _events = {};
  final _errors = StreamController<CameraErrorEvent>.broadcast();

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
  Future<XFile> takePicture(int cameraId) async =>
      XFile('/tmp/fake_capture.jpg');

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
