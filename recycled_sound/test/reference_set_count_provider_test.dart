// Verifies the coverage-HUD provider (referenceSetCountProvider) plumbs its
// (brand, model) family key through to IncomingDeviceRepository.countReferenceSetsFor
// — the diversity nudge surfaced on the confirm screen. The underlying count
// logic is exercised in incoming_device_repository_test.dart; this proves the
// Riverpod wiring (family key → repo call → value out).

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:recycled_sound/features/devices/data/incoming_device_repository.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';

void main() {
  late FakeFirebaseFirestore firestore;
  late IncomingDeviceRepository repo;
  late ProviderContainer container;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    repo = IncomingDeviceRepository(
      firestore: firestore,
      storage: MockFirebaseStorage(),
      auth: MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'user-abc', email: 'a@b.com'),
      ),
    );
    container = ProviderContainer(
      overrides: [incomingDeviceRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
  });

  test('returns the repo count for the (brand, model) family key', () async {
    await repo.createIncoming(
        const DraftDevice(brand: 'Phonak', model: 'P90', photos: ['gs://a']));

    final count = await container.read(
      referenceSetCountProvider((brand: 'Phonak', model: 'P90')).future,
    );

    expect(count, 1, reason: 'family key reaches countReferenceSetsFor');
  });

  test('returns 0 for a model with no photographed sets (diversity target)',
      () async {
    await repo.createIncoming(
        const DraftDevice(brand: 'Phonak', model: 'P90', photos: ['gs://a']));

    final count = await container.read(
      referenceSetCountProvider((brand: 'Oticon', model: 'Nera2')).future,
    );

    expect(count, 0, reason: 'an uncaptured model reads as 0 — capture adds new coverage');
  });
}
