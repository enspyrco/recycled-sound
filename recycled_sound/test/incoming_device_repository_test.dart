import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/devices/data/incoming_device_repository.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';

void main() {
  late FakeFirebaseFirestore firestore;
  late MockFirebaseStorage storage;
  late MockFirebaseAuth auth;
  late IncomingDeviceRepository repo;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    storage = MockFirebaseStorage();
    auth = MockFirebaseAuth(
      signedIn: true,
      mockUser: MockUser(uid: 'user-abc', email: 'a@b.com'),
    );
    repo = IncomingDeviceRepository(
      firestore: firestore,
      storage: storage,
      auth: auth,
    );
  });

  group('createIncoming', () {
    test('writes doc with brand+model and stamps createdBy', () async {
      const device = Device(id: '', brand: 'Phonak', model: 'P90');
      final id = await repo.createIncoming(device);

      expect(id, isNotEmpty);
      final snap = await firestore.collection('incoming').doc(id).get();
      expect(snap.exists, isTrue);
      final data = snap.data()!;
      expect(data['brand'], 'Phonak');
      expect(data['model'], 'P90');
      expect(data['createdBy'], 'user-abc');
    });

    test('throws StateError when no signed-in user', () async {
      final unauth = IncomingDeviceRepository(
        firestore: firestore,
        storage: storage,
        auth: MockFirebaseAuth(signedIn: false),
      );
      expect(
        () => unauth.createIncoming(const Device(id: '', brand: 'X', model: 'Y')),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('watchMyIncoming', () {
    test('emits creator-filtered list newest first', () async {
      // Two docs by the current user, one by someone else. The someone-else
      // doc must NOT appear in the stream — rule + query both enforce it.
      await firestore.collection('incoming').doc('old').set({
        'brand': 'A',
        'model': '1',
        'createdBy': 'user-abc',
        'createdAt': DateTime.utc(2026, 1, 1),
      });
      await firestore.collection('incoming').doc('new').set({
        'brand': 'B',
        'model': '2',
        'createdBy': 'user-abc',
        'createdAt': DateTime.utc(2026, 6, 1),
      });
      await firestore.collection('incoming').doc('other').set({
        'brand': 'C',
        'model': '3',
        'createdBy': 'someone-else',
        'createdAt': DateTime.utc(2026, 3, 1),
      });

      final list = await repo.watchMyIncoming().first;
      expect(list, hasLength(2));
      expect(list.first.id, 'new');
      expect(list.last.id, 'old');
    });

    test('emits empty list when collection has nothing for this user',
        () async {
      final list = await repo.watchMyIncoming().first;
      expect(list, isEmpty);
    });

    test('emits empty stream when no signed-in user', () async {
      final unauth = IncomingDeviceRepository(
        firestore: firestore,
        storage: storage,
        auth: MockFirebaseAuth(signedIn: false),
      );
      expect(unauth.watchMyIncoming(), emitsDone);
    });
  });

  group('watchIncomingById', () {
    test('emits Device when doc exists', () async {
      await firestore.collection('incoming').doc('xyz').set({
        'brand': 'Widex',
        'model': 'Moment 440',
      });
      final d = await repo.watchIncomingById('xyz').first;
      expect(d, isNotNull);
      expect(d!.brand, 'Widex');
      expect(d.model, 'Moment 440');
    });

    test('emits null when doc is missing', () async {
      final d = await repo.watchIncomingById('does-not-exist').first;
      expect(d, isNull);
    });
  });

  group('watchAllIncoming', () {
    test('emits every doc regardless of createdBy', () async {
      await firestore.collection('incoming').doc('a').set({
        'brand': 'A',
        'createdBy': 'u1',
        'createdAt': DateTime.utc(2026, 1, 1),
      });
      await firestore.collection('incoming').doc('b').set({
        'brand': 'B',
        'createdBy': 'u2',
        'createdAt': DateTime.utc(2026, 2, 1),
      });
      final list = await repo.watchAllIncoming().first;
      expect(list, hasLength(2));
    });
  });

  group('promoteToDevice', () {
    test('copies incoming/{id} -> devices/{id} with qaStatus=passed '
        'and deletes the source', () async {
      await firestore.collection('incoming').doc('p1').set({
        'brand': 'Oticon',
        'model': 'More 1',
        'createdBy': 'u1',
        'qaStatus': 'pending_qa',
      });

      await repo.promoteToDevice('p1');

      final src = await firestore.collection('incoming').doc('p1').get();
      expect(src.exists, isFalse, reason: 'incoming source should be deleted');

      final dst = await firestore.collection('devices').doc('p1').get();
      expect(dst.exists, isTrue);
      expect(dst.data()!['brand'], 'Oticon');
      expect(dst.data()!['model'], 'More 1');
      expect(dst.data()!['qaStatus'], 'passed',
          reason: 'promotion flips qaStatus to passed');
    });

    test('throws StateError when no such incoming doc', () async {
      expect(() => repo.promoteToDevice('does-not-exist'),
          throwsA(isA<StateError>()));
    });
  });

  group('watchAllDevices', () {
    test('emits curated devices newest first', () async {
      await firestore.collection('devices').doc('d1').set({
        'brand': 'Phonak',
        'createdAt': DateTime.utc(2026, 1, 1),
      });
      await firestore.collection('devices').doc('d2').set({
        'brand': 'Oticon',
        'createdAt': DateTime.utc(2026, 6, 1),
      });
      final list = await repo.watchAllDevices().first;
      expect(list, hasLength(2));
      expect(list.first.id, 'd2');
    });
  });

  group('watchDeviceById', () {
    test('emits curated device when present', () async {
      await firestore.collection('devices').doc('d1').set({
        'brand': 'Phonak',
        'model': 'P90',
      });
      final d = await repo.watchDeviceById('d1').first;
      expect(d, isNotNull);
      expect(d!.brand, 'Phonak');
    });

    test('emits null when missing', () async {
      final d = await repo.watchDeviceById('nope').first;
      expect(d, isNull);
    });
  });
}
