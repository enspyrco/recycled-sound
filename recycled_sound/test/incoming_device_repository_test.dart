// CollectionReference / DocumentReference / Query are sealed in cloud_firestore
// 5.x. We implement them here only to build a thin decorator that fails one
// specific call site (incoming/{id}.set) while delegating everything else —
// strictly a test-double pattern, not a real subtype. Suppress the warning
// instead of pulling in mocktail/mockito as a dev-dependency for one test.
// ignore_for_file: subtype_of_sealed_class

import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/devices/data/incoming_device_repository.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';

/// Storage mock whose `putFile` throws once the [failAfter]-th upload starts,
/// to exercise the partial-upload rollback path. The non-failing refs delegate
/// to a real [MockFirebaseStorage] so successful uploads land in (and can be
/// compensated-deleted from) [storedFilesMap].
class _FailingStorage extends MockFirebaseStorage {
  _FailingStorage({required this.failAfter});

  /// Throw on the upload at this 0-based index (and beyond).
  final int failAfter;
  int _uploads = 0;

  @override
  Reference ref([String? path]) {
    final delegate = super.ref(path);
    return _FailingReference(delegate, () => _uploads++ >= failAfter);
  }
}

/// Decorator that forwards every [Reference] member to [_delegate] except
/// [putFile], which throws when [_shouldFail] returns true.
class _FailingReference implements Reference {
  _FailingReference(this._delegate, this._shouldFail);

  final Reference _delegate;
  final bool Function() _shouldFail;

  @override
  UploadTask putFile(File file, [SettableMetadata? metadata]) {
    if (_shouldFail()) {
      throw FirebaseException(plugin: 'storage', code: 'unauthorized');
    }
    return _delegate.putFile(file, metadata);
  }

  @override
  String get bucket => _delegate.bucket;

  @override
  String get fullPath => _delegate.fullPath;

  @override
  Future<void> delete() => _delegate.delete();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      reflectInvocation(_delegate, invocation);
}

/// Forward an [Invocation] to [target]. Kept tiny — the repo only touches
/// putFile/bucket/fullPath/delete, all overridden above; this catches anything
/// the mock framework probes.
dynamic reflectInvocation(Object target, Invocation invocation) =>
    (target as dynamic).noSuchMethod(invocation);

/// Firestore decorator whose `incoming/{newId}.set(...)` throws — used to
/// exercise the post-upload Firestore-write rollback path.
///
/// Mirrors the [_FailingStorage] strategy: wrap a real
/// [FakeFirebaseFirestore], intercept only the one call site we need to fail
/// (here: the doc-ref `.set` on the `incoming` collection), delegate every-
/// thing else. Lets us assert the compensating-delete fires and no Firestore
/// doc lingers, without pulling in mocktail/mockito just for this one test.
class _FailingFirestore implements FirebaseFirestore {
  _FailingFirestore(this._delegate);
  final FakeFirebaseFirestore _delegate;

  @override
  CollectionReference<Map<String, dynamic>> collection(String path) {
    final inner = _delegate.collection(path);
    if (path == 'incoming') return _FailingCollectionRef(inner);
    return inner;
  }

  @override
  WriteBatch batch() => _delegate.batch();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      reflectInvocation(_delegate, invocation);
}

class _FailingCollectionRef implements CollectionReference<Map<String, dynamic>> {
  _FailingCollectionRef(this._delegate);
  final CollectionReference<Map<String, dynamic>> _delegate;

  @override
  DocumentReference<Map<String, dynamic>> doc([String? path]) {
    final inner = _delegate.doc(path);
    return _FailingDocRef(inner);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      reflectInvocation(_delegate, invocation);
}

class _FailingDocRef implements DocumentReference<Map<String, dynamic>> {
  _FailingDocRef(this._delegate);
  final DocumentReference<Map<String, dynamic>> _delegate;

  @override
  String get id => _delegate.id;

  @override
  Future<void> set(Map<String, dynamic> data, [SetOptions? options]) {
    throw FirebaseException(
      plugin: 'cloud_firestore',
      code: 'unavailable',
      message: 'simulated write failure',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      reflectInvocation(_delegate, invocation);
}

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
      const draft = DraftDevice(brand: 'Phonak', model: 'P90');
      final id = await repo.createIncoming(draft);

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
        () => unauth.createIncoming(const DraftDevice(brand: 'X', model: 'Y')),
        throwsA(isA<StateError>()),
      );
    });

    test('promotes draft to Device and merges uploaded photo URIs', () async {
      // No localPhotoPaths here — MockFirebaseStorage's putFile is a no-op on
      // the in-memory store, so we exercise the draft.toDevice boundary and
      // confirm pre-existing draft photos survive.
      const draft = DraftDevice(
        brand: 'Oticon',
        model: 'More 1',
        type: 'BTE',
        batterySize: '13',
        photos: ['gs://existing/scan.jpg'],
      );
      final id = await repo.createIncoming(draft);

      final data = (await firestore.collection('incoming').doc(id).get()).data()!;
      expect(data['type'], 'BTE');
      expect(data['batterySize'], '13');
      expect(data['photos'], contains('gs://existing/scan.jpg'));
      // The id lives in the doc key, never in the payload.
      expect(data.containsKey('id'), isFalse);
    });

    test('merges real gs:// URIs into photos and preserves draft photos '
        'on happy-path multi-upload', () async {
      // The existing 'promotes draft to Device and merges uploaded photo URIs'
      // test deliberately passes no localPhotoPaths, so it never asserts that
      // a *successful* upload actually merges its gs:// URI into the persisted
      // photos array. This test closes that gap: real temp files in, real
      // putFile calls through MockFirebaseStorage, real URI strings out.
      //
      // MockFirebaseStorage's bucket is the literal string 'some-bucket'
      // (see firebase_storage_mocks_base.dart). NOTE: this mock's Reference.
      // fullPath returns 'gs://{bucket}{path}' (firebase_storage_mocks 0.7.0
      // quirk — real Firebase returns just the slash-path 'incoming/{id}/…'),
      // so the URI the repo synthesises with 'gs://${bucket}/${fullPath}'
      // looks like 'gs://some-bucket/gs://some-bucketincoming/…' under the
      // mock and 'gs://some-bucket/incoming/…' against real Storage.
      //
      // The point of THIS test isn't to validate the URI shape in production
      // (real-Firebase integration tests would do that), it's to prove that
      // each successful upload produces ONE deterministic URI and that those
      // URIs end up appended to draft.photos in upload order. The expectations
      // below intentionally encode the mock's quirk to keep the test green;
      // when the mock or repo is fixed, swap them out.
      final tmp = await Directory.systemTemp.createTemp('happy_path_test');
      addTearDown(() => tmp.delete(recursive: true));
      final a = File('${tmp.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
      final b = File('${tmp.path}/b.jpg')..writeAsBytesSync([4, 5, 6]);
      final c = File('${tmp.path}/c.jpg')..writeAsBytesSync([7, 8, 9]);

      const draft = DraftDevice(
        brand: 'Phonak',
        model: 'P90',
        photos: ['gs://existing/prior-scan.jpg'],
      );

      final id = await repo.createIncoming(
        draft,
        localPhotoPaths: [a.path, b.path, c.path],
      );

      final data = (await firestore.collection('incoming').doc(id).get()).data()!;
      final photos = (data['photos'] as List).cast<String>();

      // The pre-existing draft photo survives — it's not clobbered by the
      // new uploads, it's prepended.
      expect(photos.first, 'gs://existing/prior-scan.jpg',
          reason: 'draft.photos must come before freshly-uploaded URIs');

      // Each upload contributes one URI in order, indexed by position.
      expect(photos, hasLength(4));
      expect(photos[1],
          'gs://some-bucket/gs://some-bucketscans/user-abc/incoming/$id/0.jpg');
      expect(photos[2],
          'gs://some-bucket/gs://some-bucketscans/user-abc/incoming/$id/1.jpg');
      expect(photos[3],
          'gs://some-bucket/gs://some-bucketscans/user-abc/incoming/$id/2.jpg');

      // And the files actually landed in the mock store — proves we're
      // testing real putFile traffic, not a no-op codepath.
      expect(storage.storedFilesMap, hasLength(3));
      expect(
        storage.storedFilesMap.keys,
        containsAll([
          'scans/user-abc/incoming/$id/0.jpg',
          'scans/user-abc/incoming/$id/1.jpg',
          'scans/user-abc/incoming/$id/2.jpg',
        ]),
      );
    });

    test('rolls back uploaded photos and writes no doc when an upload fails',
        () async {
      // Two photos; the SECOND upload throws. The first will have landed in
      // storage and must be deleted by the compensating cleanup.
      final tmp = await Directory.systemTemp.createTemp('rollback_test');
      addTearDown(() => tmp.delete(recursive: true));
      final a = File('${tmp.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
      final b = File('${tmp.path}/b.jpg')..writeAsBytesSync([4, 5, 6]);

      final failing = _FailingStorage(failAfter: 1);
      final failingRepo = IncomingDeviceRepository(
        firestore: firestore,
        storage: failing,
        auth: auth,
      );

      await expectLater(
        failingRepo.createIncoming(
          const DraftDevice(brand: 'Phonak', model: 'P90'),
          localPhotoPaths: [a.path, b.path],
        ),
        throwsA(isA<FirebaseException>()),
      );

      // No orphaned Storage objects.
      expect(failing.storedFilesMap, isEmpty,
          reason: 'the one successful upload must be compensated-deleted');
      // No half-written Firestore record.
      final docs = await firestore.collection('incoming').get();
      expect(docs.docs, isEmpty,
          reason: 'doc write never runs when uploads fail');
    });

    test('rolls back uploaded photos when the Firestore write fails',
        () async {
      // PR #33's catch block is symmetric — it triggers on ANY throw inside
      // the try block, including the Firestore .set after all uploads land.
      // The upload-failure test above covers the first branch; this covers
      // the second: every upload succeeds, then .set throws, and the
      // already-uploaded photos must still be compensated-deleted.
      //
      // We can't use fake_cloud_firestore as-is — its DocumentReference.set
      // always succeeds. Wrap it in _FailingFirestore (above) which throws
      // on incoming/{id}.set while delegating everything else.
      final tmp = await Directory.systemTemp.createTemp('write_fail_test');
      addTearDown(() => tmp.delete(recursive: true));
      final a = File('${tmp.path}/a.jpg')..writeAsBytesSync([1, 2, 3]);
      final b = File('${tmp.path}/b.jpg')..writeAsBytesSync([4, 5, 6]);

      final failingFirestore = _FailingFirestore(firestore);
      final failingRepo = IncomingDeviceRepository(
        firestore: failingFirestore,
        storage: storage,
        auth: auth,
      );

      await expectLater(
        failingRepo.createIncoming(
          const DraftDevice(brand: 'Phonak', model: 'P90'),
          localPhotoPaths: [a.path, b.path],
        ),
        throwsA(
          isA<FirebaseException>()
              .having((e) => e.code, 'code', 'unavailable'),
        ),
      );

      // Both uploads succeeded before .set threw — both must be deleted.
      expect(storage.storedFilesMap, isEmpty,
          reason:
              'all successful uploads must be compensated-deleted when the '
              'Firestore write that follows fails');
      // And nothing got written to Firestore.
      final docs = await firestore.collection('incoming').get();
      expect(docs.docs, isEmpty);
    });

    test('named photos upload under slot-identity filenames, not positions',
        () async {
      // Sparse capture: 'scale' and 'lateral' shot, 'medial' (which sits
      // between them in slot order) skipped. The storage filename must be the
      // slot NAME — if it were a compacted position, 'lateral' would land at
      // index 1 and be mislabelled 'medial'. This is the regression guard.
      final tmp = await Directory.systemTemp.createTemp('slot_test');
      addTearDown(() => tmp.delete(recursive: true));
      final scale = File('${tmp.path}/scale.jpg')..writeAsBytesSync([1]);
      final lateral = File('${tmp.path}/lateral.jpg')..writeAsBytesSync([2]);

      final id = await repo.createIncoming(
        const DraftDevice(brand: 'Phonak', model: 'P90'),
        namedPhotoPaths: {'scale': scale.path, 'lateral': lateral.path},
      );

      final paths = storage.storedFilesMap.keys.toList();
      expect(paths.any((p) => p.endsWith('incoming/$id/scale.jpg')), isTrue,
          reason: 'scale photo keyed by slot name');
      expect(paths.any((p) => p.endsWith('incoming/$id/lateral.jpg')), isTrue,
          reason: 'lateral photo keyed by slot name, not compacted index');
      // The compacted positional name the old scheme produced must NOT appear.
      expect(paths.any((p) => p.endsWith('incoming/$id/1.jpg')), isFalse,
          reason: 'no positional filenames — that was the mislabelling bug');

      final data =
          (await firestore.collection('incoming').doc(id).get()).data()!;
      expect((data['photos'] as List).length, 2);
    });
  });

  group('PersistErrorKind.fromCode', () {
    test('maps known Firestore codes to typed kinds', () {
      expect(PersistErrorKind.fromCode('permission-denied'),
          PersistErrorKind.permissionDenied);
      expect(PersistErrorKind.fromCode('unavailable'),
          PersistErrorKind.unavailable);
      expect(PersistErrorKind.fromCode('deadline-exceeded'),
          PersistErrorKind.unavailable);
      expect(PersistErrorKind.fromCode('network-request-failed'),
          PersistErrorKind.unavailable);
      expect(PersistErrorKind.fromCode('resource-exhausted'),
          PersistErrorKind.resourceExhausted);
    });

    test('maps plugin-prefixed Cloud Storage codes to the same kinds', () {
      // createIncoming uploads photos, so a Storage failure surfaces here too —
      // and Storage codes arrive `storage/`-prefixed.
      expect(PersistErrorKind.fromCode('storage/unauthorized'),
          PersistErrorKind.permissionDenied);
      expect(PersistErrorKind.fromCode('storage/unauthenticated'),
          PersistErrorKind.permissionDenied);
      expect(PersistErrorKind.fromCode('storage/retry-limit-exceeded'),
          PersistErrorKind.unavailable);
      expect(PersistErrorKind.fromCode('storage/quota-exceeded'),
          PersistErrorKind.resourceExhausted);
    });

    test('falls through to unknown for unrecognised codes', () {
      expect(PersistErrorKind.fromCode('not-a-real-code'),
          PersistErrorKind.unknown);
      expect(PersistErrorKind.fromCode(''), PersistErrorKind.unknown);
    });

    test('every kind has non-empty user copy', () {
      for (final kind in PersistErrorKind.values) {
        expect(kind.userMessage, isNotEmpty);
      }
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

  group('deleteIncoming', () {
    test('deletes the Firestore doc (authoritative half) and attempts the '
        'per-uid scans/ sweep', () async {
      // `firebase_storage_mocks` 0.7.0 quirk (mirrors the gs:// URI quirk
      // captured in PR #46): MockReference.delete() doesn't remove items
      // from MockFirebaseStorage's in-memory store, so we can't directly
      // assert the blob sweep happened. What we CAN assert is the
      // authoritative half — the Firestore doc is gone — and that the
      // sweep code path ran without throwing. The Storage half is verified
      // in integration / on-device testing; cf. [[feedback_silent_skip_is_worse_than_loud_fail]]
      // for the broader principle (the gate must catch what it claims to,
      // even when the mock can't simulate the second half).
      const draft = DraftDevice(brand: 'Phonak', model: 'P90');
      final id = await repo.createIncoming(draft);
      const uid = 'user-abc';
      // Seed photo blobs at the per-uid sweep path so listAll() returns
      // items the delete loop can iterate over — exercises the code path
      // even though the mock's delete is a no-op.
      await storage.ref('scans/$uid/incoming/$id/lateral.jpg').putString('x');
      await storage.ref('scans/$uid/incoming/$id/medial.jpg').putString('y');

      expect((await firestore.collection('incoming').doc(id).get()).exists,
          isTrue);

      await repo.deleteIncoming(id);

      // Authoritative half: the doc the UI streams is gone.
      expect((await firestore.collection('incoming').doc(id).get()).exists,
          isFalse);
    });

    test('throws StateError when no signed-in user', () async {
      final unauth = IncomingDeviceRepository(
        firestore: firestore,
        storage: storage,
        auth: MockFirebaseAuth(signedIn: false),
      );
      expect(
        () => unauth.deleteIncoming('any-id'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
