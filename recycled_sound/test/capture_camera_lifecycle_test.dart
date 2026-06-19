import 'dart:async';
import 'dart:math';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:recycled_sound/features/capture/presentation/capture_screen.dart';
import 'package:recycled_sound/features/capture/presentation/capture_slot.dart';
import 'package:recycled_sound/features/capture/providers/capture_seed.dart';

import 'support/google_fonts_test_asset.dart';

/// Regression tests for the CaptureScreen camera lifecycle (#73).
///
/// CaptureScreen guards its camera with two mechanisms (see the doc on
/// `_initGen` / `_cameraOp` in capture_screen.dart):
///   * `_initGen` — a staleness token: an init whose token was bumped during an
///     `await` disposes its half-built controller instead of publishing it.
///   * `_cameraOp` — a chained-future mutex: every init/teardown is appended so
///     they run strictly one-at-a-time, with a trailing `.catchError` so a
///     thrown op (e.g. a native dispose failing) can't permanently reject the
///     queue and freeze the camera forever.
///
/// We drive the real production code through a [_FakeCameraPlatform] that counts
/// created vs disposed controllers, so "exactly one live controller" is a
/// direct assertion. `initializeCamera` can be *gated* on a [Completer] (to
/// hold an init in-flight for the staleness test) or run un-gated (so the
/// camera reaches ready deterministically).
///
/// `CameraController.initialize()` resolves through a broadcast-stream event,
/// whose delivery needs a REAL event loop, AND the screen's `setState` only
/// takes effect on a `tester.pump()`. So each phase is `runAsync(<real delay>)`
/// to drain the camera op chain, followed by a `pump()` to flush the new state
/// — see [_settle]. One giant `runAsync` without interleaved pumps stalls the
/// chain because the published controller is never committed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The capture UI uses AppTypography (GoogleFonts.inter()). When the camera
  // becomes ready and we pump the live UI under runAsync, google_fonts would
  // otherwise do a live HTTP font fetch (which fails offline). Feed it a bundled
  // font from the asset bundle instead. If the SDK font can't be located, every
  // test in this group is skipped (never left red).
  // false only if the SDK Roboto font couldn't be located — then the two
  // ready-UI-rendering tests are skipped rather than left red (they can't paint
  // GoogleFonts.inter() offline).
  final fontReady = installGoogleFontsAssetMock();

  late _FakeCameraPlatform fake;

  setUp(() {
    fake = _FakeCameraPlatform();
    CameraPlatform.instance = fake;
  });

  WidgetsBindingObserver observer(WidgetTester tester) =>
      tester.state(find.byType(CaptureScreen)) as WidgetsBindingObserver;

  Future<void> pumpCapture(WidgetTester tester, {String box = ''}) async {
    await tester.pumpWidget(
      ProviderScope(
        // Box-first reorg (#96): the box arrives via scanBoxProvider (set by the
        // home modal), not an in-screen dialog. Default '' exercises the
        // bypassed-modal state.
        overrides: [scanBoxProvider.overrideWith((ref) => box)],
        child: const MaterialApp(home: CaptureScreen()),
      ),
    );
  }

  /// Drain the camera op chain on the real event loop (releasing any parked
  /// gate first), then pump a frame so the screen's pending setState commits.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      fake.releaseGates();
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
  }

  testWidgets(
      'an inactive→resumed cycle leaves exactly ONE live controller',
      (tester) async {
    await pumpCapture(tester);

    // The initial init publishes one live controller.
    await settle(tester);
    expect(fake.liveControllerCount, 1,
        reason: 'initial init should publish exactly one controller');

    // Background then resume. _scheduleStop tears the live controller down;
    // _scheduleInit (from resume) builds a fresh one — serialized on the
    // _cameraOp queue so they can never overlap on the native device.
    observer(tester)
      ..didChangeAppLifecycleState(AppLifecycleState.inactive)
      ..didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle(tester);

    // Exactly one controller is live: the old one disposed, one new one
    // published. Never two (no leak), never zero (no freeze).
    expect(fake.liveControllerCount, 1,
        reason: 'a background/resume cycle must not leak a second controller');
    expect(fake.created, 2);
    expect(fake.disposed, 1);
  }, skip: !fontReady);

  testWidgets('_stopCamera during init disposes the in-flight controller',
      (tester) async {
    // Hold the very first init parked inside initializeCamera so we can
    // background *while it is still in flight*.
    fake.gateInits = true;

    await pumpCapture(tester);

    // Let the init advance until it parks in the gated initializeCamera.
    await tester.runAsync(() => fake.firstInitReachedGate);
    expect(fake.gatedInitializes, 1,
        reason: 'first init should be parked in initializeCamera');

    // Background only (no resume): _scheduleStop bumps the generation so the
    // parked init is now stale, then queues the teardown behind it.
    observer(tester).didChangeAppLifecycleState(AppLifecycleState.inactive);

    // Release the gate — the parked init resumes, sees its stale generation,
    // and disposes the half-built controller instead of publishing it.
    await settle(tester);

    expect(fake.created, 1, reason: 'only the one parked init ran');
    expect(fake.liveControllerCount, 0,
        reason: 'backgrounding mid-init must leave no live controller');
    expect(fake.disposed, 1,
        reason: 'the in-flight controller was disposed, not published');
  });

  testWidgets('a thrown dispose does NOT poison the _cameraOp queue',
      (tester) async {
    await pumpCapture(tester);

    // Bring the camera up first (controller 0 live).
    await settle(tester);
    expect(fake.liveControllerCount, 1);

    // Make controller 0's dispose throw — mirrors a native release failing
    // mid-transition. The trailing .catchError in _scheduleInit/_scheduleStop
    // must absorb it so later queued ops still run.
    fake.throwOnDisposeOfController = 0;

    // Background+resume: the stop disposes controller 0 (which THROWS), then
    // the resume's init is queued behind that thrown teardown.
    observer(tester)
      ..didChangeAppLifecycleState(AppLifecycleState.inactive)
      ..didChangeAppLifecycleState(AppLifecycleState.resumed);
    await settle(tester);

    // If the throw had poisoned the chained future, the resume's init would
    // never run and no second controller would exist. A self-healing queue
    // recovers and ends with exactly one live controller.
    expect(fake.created, 2,
        reason: 'a second init must still run after the thrown dispose');
    expect(fake.liveControllerCount, 1,
        reason: 'the queue self-heals: a thrown dispose does not freeze it');
  }, skip: !fontReady);

  // The box number is the only handle that ties a capture's photo set back
  // to its physical device in the register. Box-first reorg (#96): it is now
  // entered up front in the home box-first modal (stored in scanBoxProvider),
  // NOT in this screen — the in-screen details dialog is gone. The bar is now a
  // READ-ONLY summary: it shows the seeded box and, when somehow unset, a
  // restart nudge rather than a tappable call-to-action.
  testWidgets('details bar nudges back to home when the box is unset',
      (tester) async {
    // The box-first modal was bypassed — the bar nudges back to home, and the
    // removed in-screen details dialog is not reachable.
    await pumpCapture(tester);
    await settle(tester); // camera ready, live UI painted
    expect(find.text('No box number — restart from the home screen'),
        findsOneWidget);
    expect(find.text('Device details'), findsNothing);
  }, skip: !fontReady);

  testWidgets('details bar summarises the box once seeded from scanBoxProvider',
      (tester) async {
    // The normal path: the home modal stored the box in scanBoxProvider; the
    // bar reads it through and shows it, with no nudge.
    await pumpCapture(tester, box: 'B07');
    await settle(tester);
    expect(find.text('Box B07'), findsOneWidget);
    expect(find.text('No box number — restart from the home screen'),
        findsNothing);
  }, skip: !fontReady);

  // The flow models a PAIR: 14 steps = 7 orientations of the LEFT aid, then 7
  // of the RIGHT. This is the structural invariant the whole redesign rests on.
  test('pairSequence is left×7 then right×7, 14 steps', () {
    expect(CaptureSlot.pairSequence.length, 14);
    expect(CaptureSlot.pairSequence.first.side, AidSide.left);
    expect(CaptureSlot.pairSequence[6].side, AidSide.left);
    expect(CaptureSlot.pairSequence[7].side, AidSide.right);
    expect(CaptureSlot.pairSequence.last.side, AidSide.right);
    // Each side runs the same 7 orientations in the same order.
    expect(
      CaptureSlot.pairSequence.sublist(0, 7).map((s) => s.slot).toList(),
      CaptureSlot.sequence,
    );
    expect(
      CaptureSlot.pairSequence.sublist(7).map((s) => s.slot).toList(),
      CaptureSlot.sequence,
    );
  });

  // The volunteer starts on the LEFT aid at photo 1 of 14.
  testWidgets('capture flow opens on the LEFT aid, photo 1 of 14',
      (tester) async {
    await pumpCapture(tester);
    await settle(tester);
    expect(find.text('LEFT AID'), findsOneWidget);
    expect(find.textContaining('Photo 1 of 14'), findsOneWidget);
  }, skip: !fontReady);
}

/// A controllable fake [CameraPlatform] that tracks created/disposed controller
/// ids so a test can assert how many controllers are live.
///
/// When [gateInits] is true, `initializeCamera` parks on a per-call [Completer]
/// (released via [releaseGates]) so a test can hold an init in flight; when
/// false it resolves immediately and the camera reaches ready.
class _FakeCameraPlatform extends CameraPlatform
    with MockPlatformInterfaceMixin {
  int _nextId = 0;
  int created = 0;
  int disposed = 0;

  /// Park inits inside initializeCamera until released. Off by default.
  bool gateInits = false;

  /// Pending `initializeCamera` gates, one per parked init.
  final List<Completer<void>> _initGates = [];

  /// Completes the first time a *gated* init reaches the gate, so a test can
  /// act at the precise in-flight moment.
  final Completer<void> _firstGate = Completer<void>();
  Future<void> get firstInitReachedGate => _firstGate.future;

  /// Per-cameraId initialized-event streams the controller subscribes to during
  /// initialize().
  final Map<int, StreamController<CameraInitializedEvent>> _initializedEvents =
      {};

  // A never-emitting, never-closing stream: the controller does `.first` on
  // this, and an *empty* stream would make `.first` throw "No element".
  final _errors = StreamController<CameraErrorEvent>.broadcast();

  /// Ids that have been created but not yet disposed.
  final Set<int> _liveIds = {};

  /// If set, disposing the controller created at this 0-based creation index
  /// throws — simulating a native release failure mid-transition.
  int? throwOnDisposeOfController;

  /// How many inits are currently parked inside initializeCamera.
  int get gatedInitializes => _initGates.where((c) => !c.isCompleted).length;

  int get liveControllerCount => _liveIds.length;

  /// Complete every currently-parked init gate (idempotent).
  void releaseGates() {
    for (final c in List<Completer<void>>.from(_initGates)) {
      if (!c.isCompleted) c.complete();
    }
  }

  @override
  Future<List<CameraDescription>> availableCameras() async {
    return const [
      CameraDescription(
        name: 'back',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      ),
    ];
  }

  @override
  Future<int> createCameraWithSettings(
    CameraDescription cameraDescription,
    MediaSettings mediaSettings,
  ) async {
    final id = _nextId++;
    created++;
    _liveIds.add(id);
    _initializedEvents[id] =
        StreamController<CameraInitializedEvent>.broadcast();
    return id;
  }

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) {
    return _initializedEvents[cameraId]!.stream;
  }

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) => _errors.stream;

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() {
    return const Stream<DeviceOrientationChangedEvent>.empty();
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {
    if (gateInits) {
      // Park here until the test releases this gate — this is the in-flight
      // init window the lifecycle transition races against.
      final gate = Completer<void>();
      _initGates.add(gate);
      if (!_firstGate.isCompleted) _firstGate.complete();
      await gate.future;
    }
    // Emit the initialized event the controller's initialize() awaits before it
    // reports isInitialized == true.
    _initializedEvents[cameraId]?.add(
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
    final creationIndex = cameraId; // ids are assigned in creation order
    _liveIds.remove(cameraId);
    disposed++;
    unawaited(_initializedEvents.remove(cameraId)?.close());
    if (throwOnDisposeOfController == creationIndex) {
      throw CameraException('dispose-failed', 'native release failed');
    }
  }
}
