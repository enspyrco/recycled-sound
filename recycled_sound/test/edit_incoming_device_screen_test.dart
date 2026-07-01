// Guards the trust-boundary contract of the mobile owner-edit screen (#6, A):
// editing a pending incoming/ device writes ONLY the four owner-editable identity
// fields (brand/model/style/battery) via updateIncomingIdentity — the clinical/
// triage fields are not parameters, so they can't be touched (or drift) and the
// Firestore creator rule accepts the write by construction. Also: a reviewed
// (non-pending) device can't be edited at all.

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:recycled_sound/features/devices/data/incoming_device_repository.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/presentation/edit_incoming_device_screen.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';

/// Records the updateIncoming args instead of writing, and serves a fixed
/// device to the detail-by-id stream the edit screen watches.
class _RecordingRepo extends IncomingDeviceRepository {
  _RecordingRepo(this.device)
      : super(
          firestore: FakeFirebaseFirestore(),
          storage: MockFirebaseStorage(),
          auth: MockFirebaseAuth(
            signedIn: true,
            mockUser: MockUser(uid: 'owner-uid'),
          ),
        );

  final Device device;
  Map<String, Object?>? recorded;

  @override
  Stream<Device?> watchIncomingById(String id) => Stream.value(device);

  // The owner-edit screen writes through the identity-only method. Recording it
  // is the whole point: it can only carry the four owner-editable fields, so the
  // clinical fields are unwritable by construction (no pass-through to drift).
  @override
  Future<void> updateIncomingIdentity(
    String id, {
    required String brand,
    required String model,
    required Style type,
    required BatterySize batterySize,
  }) async {
    recorded = {
      'brand': brand,
      'model': model,
      'type': type,
      'batterySize': batterySize,
    };
  }
}

void main() {
  testWidgets(
      'saving an edit writes only the four owner-editable identity fields — '
      'clinical fields are unwritable by construction (owner-safe, #6)',
      (tester) async {
    const device = Device(
      id: 'dev-1',
      brand: 'Phonak',
      model: 'Audeo',
      type: Style.bte,
      batterySize: BatterySize.size312,
      tubing: Tubing.slim,
      powerSource: PowerSource.battery,
      colour: 'Beige',
      qaStatus: QaStatus.pendingQa,
    );
    final repo = _RecordingRepo(device);

    final router = GoRouter(
      initialLocation: '/devices/dev-1/edit',
      routes: [
        GoRoute(
          path: '/devices/:id/edit',
          builder: (c, s) =>
              EditIncomingDeviceScreen(deviceId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/devices/:id',
          builder: (c, s) => const Scaffold(body: Text('detail')),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          incomingDeviceRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // Change the brand only (first TextField = Brand, seeded 'Phonak').
    await tester.enterText(find.byType(TextField).first, 'Oticon');
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(repo.recorded, isNotNull);
    expect(repo.recorded!['brand'], 'Oticon', reason: 'edited field changes');
    expect(repo.recorded!['model'], 'Audeo', reason: 'untouched identity kept');
    expect(repo.recorded!['type'], Style.bte);
    expect(repo.recorded!['batterySize'], BatterySize.size312);
    // The write is identity-only: the clinical fields are not even parameters,
    // so they cannot be touched. That is the owner-safe guarantee by construction.
    expect(repo.recorded!.keys,
        unorderedEquals(['brand', 'model', 'type', 'batterySize']));
  });

  testWidgets('a reviewed (non-pending) device cannot be edited (#6)',
      (tester) async {
    const device = Device(
      id: 'dev-2',
      brand: 'Phonak',
      model: 'Audeo',
      qaStatus: QaStatus.passed,
    );
    final repo = _RecordingRepo(device);

    final router = GoRouter(
      initialLocation: '/devices/dev-2/edit',
      routes: [
        GoRoute(
          path: '/devices/:id/edit',
          builder: (c, s) =>
              EditIncomingDeviceScreen(deviceId: s.pathParameters['id']!),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [incomingDeviceRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('already been reviewed'), findsOneWidget);
    expect(find.text('Save changes'), findsNothing);
  });
}
