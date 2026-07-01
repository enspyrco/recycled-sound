// Guards the trust-boundary contract of the mobile owner-edit screen (#6, A):
// editing a pending incoming/ device may CHANGE only the owner-editable identity
// fields (brand/model/style/battery); the clinical/triage fields (tubing, power,
// colour) must ride through updateIncoming UNCHANGED, so the Firestore owner rule
// (onlyAllowedFieldsChanged, which is delta-sensitive) accepts the write.

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

  @override
  Future<void> updateIncoming(
    String id, {
    required String brand,
    required String model,
    required Style type,
    required BatterySize batterySize,
    required Tubing tubing,
    required PowerSource powerSource,
    required String colour,
    required String location,
    required String servicingNotes,
    required double servicingCost,
    QaStatus? qaStatus,
    List<ClinicalField>? needsInputFields,
    List<String> unrecognisedNeedsInput = const [],
  }) async {
    recorded = {
      'brand': brand,
      'model': model,
      'type': type,
      'batterySize': batterySize,
      'tubing': tubing,
      'powerSource': powerSource,
      'colour': colour,
    };
  }
}

void main() {
  testWidgets(
      'saving an edit changes brand/model but passes clinical fields through '
      'unchanged (owner-safe write, #6)', (tester) async {
    const device = Device(
      id: 'dev-1',
      brand: 'Phonak',
      model: 'Audeo',
      type: Style.bte,
      batterySize: BatterySize.size312,
      tubing: Tubing.slim,
      powerSource: PowerSource.battery,
      colour: 'Beige',
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
    // The clinical/triage fields must be the device's ORIGINAL values —
    // unchanged, so the owner rule accepts the write.
    expect(repo.recorded!['tubing'], Tubing.slim);
    expect(repo.recorded!['powerSource'], PowerSource.battery);
    expect(repo.recorded!['colour'], 'Beige');
  });
}
