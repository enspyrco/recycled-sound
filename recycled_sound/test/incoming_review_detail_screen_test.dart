import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recycled_sound/features/admin/presentation/incoming_review_detail_screen.dart';
import 'package:recycled_sound/features/devices/data/incoming_device_repository.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';

/// Repository double that records the review-flow calls without touching a real
/// backend. Extends the real repo (constructed with the standard Firebase
/// mocks), matching the test-double style in `device_detail_screen_test.dart`.
class _RecordingRepository extends IncomingDeviceRepository {
  _RecordingRepository()
      : super(
          firestore: FakeFirebaseFirestore(),
          storage: MockFirebaseStorage(),
          auth: MockFirebaseAuth(),
        );

  int promoteCalls = 0;
  int updateCalls = 0;
  final List<QaStatus?> updateQaStatuses = [];
  // Captured edits from the last updateIncoming call.
  Tubing? lastTubing;
  PowerSource? lastPowerSource;
  String? lastColour;

  @override
  Future<void> updateIncoming(
    String id, {
    required Tubing tubing,
    required PowerSource powerSource,
    required String colour,
    required String location,
    required String servicingNotes,
    required double servicingCost,
    QaStatus? qaStatus,
  }) async {
    updateCalls++;
    updateQaStatuses.add(qaStatus);
    lastTubing = tubing;
    lastPowerSource = powerSource;
    lastColour = colour;
  }

  @override
  Future<void> promoteToDevice(String incomingId) async {
    promoteCalls++;
  }
}

const _id = 'dev1';

Device _device({
  Tubing tubing = Tubing.unspecified,
  PowerSource powerSource = PowerSource.unspecified,
  String colour = '',
  List<String> needsInputFields = const [],
  QaStatus qaStatus = QaStatus.pendingQa,
}) =>
    Device(
      id: _id,
      brand: 'Oticon',
      model: 'More 1',
      type: 'BTE',
      year: '2022',
      batterySize: '13',
      tubing: tubing,
      powerSource: powerSource,
      colour: colour,
      needsInputFields: needsInputFields,
      qaStatus: qaStatus,
    );

Future<_RecordingRepository> _pump(
  WidgetTester tester, {
  required Device device,
}) async {
  final repo = _RecordingRepository();
  final router = GoRouter(
    initialLocation: '/incoming/$_id/review',
    routes: [
      GoRoute(
        path: '/incoming',
        builder: (_, _) => const Scaffold(body: Text('QUEUE')),
      ),
      GoRoute(
        path: '/incoming/:id/review',
        builder: (_, state) => IncomingReviewDetailScreen(
          deviceId: state.pathParameters['id']!,
        ),
      ),
    ],
  );
  await tester.pumpWidget(ProviderScope(
    overrides: [
      incomingDeviceByIdProvider(_id).overrideWith((_) => Stream.value(device)),
      incomingDeviceRepositoryProvider.overrideWithValue(repo),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('renders device fields and the needsInputFields banner',
      (tester) async {
    await _pump(tester,
        device: _device(needsInputFields: ['tubing', 'colour']));

    expect(find.text('Oticon More 1'), findsOneWidget);
    expect(find.text('Identification'), findsOneWidget);
    expect(find.text('Audiologist review'), findsOneWidget);
    // Banner surfaces the flagged fields by friendly label (sorted).
    expect(find.textContaining('Needs your input (2)'), findsOneWidget);
    expect(find.textContaining('Colour, Tubing'), findsOneWidget);
  });

  testWidgets('no banner when nothing was flagged', (tester) async {
    await _pump(tester, device: _device());
    expect(find.textContaining('Needs your input'), findsNothing);
    expect(find.textContaining('All flagged fields resolved'), findsNothing);
  });

  testWidgets('Pass QA persists edits then promotes, navigating to the queue',
      (tester) async {
    final repo = await _pump(tester,
        device: _device(needsInputFields: ['colour']));

    // Resolve the flagged colour field.
    await tester.enterText(find.byType(TextField).first, 'Charcoal');
    await tester.pumpAndSettle();

    final pass = find.widgetWithText(FilledButton, 'Pass QA');
    await tester.ensureVisible(pass);
    await tester.tap(pass);
    await tester.pumpAndSettle();

    expect(repo.updateCalls, 1);
    expect(repo.promoteCalls, 1);
    // Pass leaves qaStatus to promoteToDevice — update is called without it.
    expect(repo.updateQaStatuses.single, isNull);
    expect(repo.lastColour, 'Charcoal');
    // Navigated back to the queue.
    expect(find.text('QUEUE'), findsOneWidget);
  });

  testWidgets('Fail QA sets failed without promoting and stays put',
      (tester) async {
    final repo = await _pump(tester, device: _device());

    final fail = find.widgetWithText(OutlinedButton, 'Fail QA');
    await tester.ensureVisible(fail);
    await tester.tap(fail);
    await tester.pumpAndSettle();

    expect(repo.updateCalls, 1);
    expect(repo.updateQaStatuses.single, QaStatus.failed);
    expect(repo.promoteCalls, 0);
    // No nav — still on the review screen.
    expect(find.text('QUEUE'), findsNothing);
    expect(find.text('Audiologist review'), findsOneWidget);
  });

  testWidgets('editing a segmented field is captured on save', (tester) async {
    final repo = await _pump(tester, device: _device());

    // Pick "Slim" tubing and "Battery" power source. "Battery" also appears as
    // the Identification spec-row label, so scope the tap to the power-source
    // segmented control.
    final slim = find.text('Slim');
    await tester.ensureVisible(slim);
    await tester.tap(slim);
    final battery = find.descendant(
      of: find.byType(SegmentedButton<PowerSource>),
      matching: find.text('Battery'),
    );
    await tester.ensureVisible(battery);
    await tester.tap(battery);
    await tester.pumpAndSettle();

    final fail = find.widgetWithText(OutlinedButton, 'Fail QA');
    await tester.ensureVisible(fail);
    await tester.tap(fail);
    await tester.pumpAndSettle();

    expect(repo.lastTubing, Tubing.slim);
    expect(repo.lastPowerSource, PowerSource.battery);
  });

  testWidgets('permission-denied shows the lock UI, not a crash',
      (tester) async {
    final router = GoRouter(
      initialLocation: '/incoming/$_id/review',
      routes: [
        GoRoute(
          path: '/incoming/:id/review',
          builder: (_, state) => IncomingReviewDetailScreen(
            deviceId: state.pathParameters['id']!,
          ),
        ),
      ],
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        incomingDeviceByIdProvider(_id).overrideWith(
          (_) => Stream.error(Exception('permission-denied')),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('audiologist or admin role'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });
}
