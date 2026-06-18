import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/capture/providers/upload_job.dart';
import 'package:recycled_sound/features/devices/data/incoming_device_repository.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';

/// A repository test-double that lets a test script `createIncoming`'s
/// behaviour: drive its [onProgress] callback (via [onCreate]), decide the
/// returned device id, or make it throw. It subclasses the real repo only to
/// satisfy the provider's type — every method the controller touches is
/// overridden, so the mock Firebase handles passed to `super` are never used.
class _ScriptedRepo extends IncomingDeviceRepository {
  _ScriptedRepo({this.onCreate, this.idToReturn = 'dev-1', this.throwError})
      : super(
          firestore: FakeFirebaseFirestore(),
          storage: MockFirebaseStorage(),
          auth: MockFirebaseAuth(
            signedIn: true,
            mockUser: MockUser(uid: 'u-1'),
          ),
        );

  /// Invoked inside [createIncoming] with the real onProgress callback and the
  /// named paths, so a test can simulate byte ticks before the call returns.
  final void Function(
    void Function(String key, int sent, int total)? onProgress,
    Map<String, String> paths,
  )? onCreate;
  final String idToReturn;
  final Object? throwError;
  int createCalls = 0;

  @override
  Future<String> createIncoming(
    DraftDevice draft, {
    List<String> localPhotoPaths = const [],
    Map<String, String> namedPhotoPaths = const {},
    void Function(String key, int bytesTransferred, int totalBytes)? onProgress,
  }) async {
    createCalls++;
    onCreate?.call(onProgress, namedPhotoPaths);
    if (throwError != null) throw throwError!;
    return idToReturn;
  }
}

void main() {
  const draft = DraftDevice(brand: 'Phonak', model: 'P90');
  const paths = {'left_medial': '/a.jpg', 'right_scale': '/b.jpg'};

  ProviderContainer containerWith(_ScriptedRepo repo) {
    final c = ProviderContainer(
      overrides: [incomingDeviceRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    return c;
  }

  group('PhotoProgress', () {
    test('fraction is the byte ratio while running, clamped to 0..1', () {
      expect(const PhotoProgress(key: 'k', transferred: 50, total: 100).fraction,
          0.5);
      // Over-report can't exceed 1.
      expect(
          const PhotoProgress(key: 'k', transferred: 200, total: 100).fraction,
          1);
    });

    test('fraction is 0 with no total and not done, 1 once done', () {
      expect(const PhotoProgress(key: 'k').fraction, 0);
      // A tiny file can finish before any byte tick arrives.
      expect(const PhotoProgress(key: 'k', done: true).fraction, 1);
    });

    test('copyWith preserves the key and overrides only given fields', () {
      const p = PhotoProgress(key: 'left_medial');
      final q = p.copyWith(transferred: 10, total: 20, done: true);
      expect(q.key, 'left_medial');
      expect(q.transferred, 10);
      expect(q.total, 20);
      expect(q.done, isTrue);
    });
  });

  group('UploadJob aggregates', () {
    test('overall is the mean per-photo fraction; 0 when empty', () {
      expect(
        const UploadJob(phase: UploadPhase.uploading, box: 'B', photos: [])
            .overall,
        0,
      );
      const job = UploadJob(phase: UploadPhase.uploading, box: 'B', photos: [
        PhotoProgress(key: 'a', transferred: 100, total: 100, done: true),
        PhotoProgress(key: 'b', transferred: 0, total: 100),
      ]);
      expect(job.overall, 0.5);
      expect(job.total, 2);
      expect(job.completed, 1);
    });
  });

  group('UploadJobController.start', () {
    test('drives uploading→success, stamps deviceId, marks all photos done',
        () async {
      final repo = _ScriptedRepo(idToReturn: 'dev-42');
      final container = containerWith(repo);
      final controller = container.read(uploadJobProvider.notifier);

      await controller.start(
          draft: draft, namedPhotoPaths: paths, box: 'B07');

      final job = container.read(uploadJobProvider)!;
      expect(job.phase, UploadPhase.success);
      expect(job.box, 'B07');
      expect(job.deviceId, 'dev-42');
      expect(job.total, 2);
      expect(job.completed, 2, reason: 'success marks every photo done');
      expect(job.photos.every((p) => p.done), isTrue);
    });

    test('per-file progress ticks update the matching row and flip done at 100%',
        () async {
      late ProviderContainer container;
      final repo = _ScriptedRepo(onCreate: (onProgress, p) {
        // Mid-upload: half of left_medial sent.
        onProgress!('left_medial', 50, 100);
        final mid = container.read(uploadJobProvider)!;
        expect(mid.phase, UploadPhase.uploading);
        final row = mid.photos.firstWhere((x) => x.key == 'left_medial');
        expect(row.transferred, 50);
        expect(row.done, isFalse);
        // Topping out flips done so "N of 14" ticks before the job settles.
        onProgress('left_medial', 100, 100);
        expect(
            container
                .read(uploadJobProvider)!
                .photos
                .firstWhere((x) => x.key == 'left_medial')
                .done,
            isTrue);
      });
      container = containerWith(repo);

      await container
          .read(uploadJobProvider.notifier)
          .start(draft: draft, namedPhotoPaths: paths, box: 'B07');
    });

    test('a FirebaseException becomes an error phase with mapped user copy',
        () async {
      final repo = _ScriptedRepo(
        throwError:
            FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
      );
      final container = containerWith(repo);

      await container
          .read(uploadJobProvider.notifier)
          .start(draft: draft, namedPhotoPaths: paths, box: 'B07');

      final job = container.read(uploadJobProvider)!;
      expect(job.phase, UploadPhase.error);
      expect(job.errorMessage,
          PersistErrorKind.fromCode('unavailable').userMessage);
    });

    test('a non-Firebase throw becomes a generic connection error', () async {
      final repo = _ScriptedRepo(throwError: StateError('boom'));
      final container = containerWith(repo);

      await container
          .read(uploadJobProvider.notifier)
          .start(draft: draft, namedPhotoPaths: paths, box: 'B07');

      final job = container.read(uploadJobProvider)!;
      expect(job.phase, UploadPhase.error);
      expect(job.errorMessage,
          'Upload failed. Check your connection and try again.');
    });
  });

  group('UploadJobController.retry / clear', () {
    test('retry is a no-op before any start', () async {
      final repo = _ScriptedRepo();
      final container = containerWith(repo);
      await container.read(uploadJobProvider.notifier).retry();
      expect(container.read(uploadJobProvider), isNull);
      expect(repo.createCalls, 0);
    });

    test('retry re-runs the last upload (reusing the captured photos)',
        () async {
      final repo = _ScriptedRepo();
      final container = containerWith(repo);
      final controller = container.read(uploadJobProvider.notifier);

      await controller.start(
          draft: draft, namedPhotoPaths: paths, box: 'B07');
      await controller.retry();

      expect(repo.createCalls, 2, reason: 'retry walks createIncoming again');
      expect(container.read(uploadJobProvider)!.phase, UploadPhase.success);
    });

    test('clear() drops the finished job so it cannot flash on re-entry',
        () async {
      final repo = _ScriptedRepo();
      final container = containerWith(repo);
      final controller = container.read(uploadJobProvider.notifier);

      await controller.start(
          draft: draft, namedPhotoPaths: paths, box: 'B07');
      expect(container.read(uploadJobProvider), isNotNull);

      controller.clear();
      expect(container.read(uploadJobProvider), isNull);
    });
  });
}
