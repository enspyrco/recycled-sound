import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../devices/data/incoming_device_repository.dart';
import '../../devices/data/models/device.dart';
import '../../devices/providers/device_providers.dart';

/// Live byte-progress for one photo in an upload job, keyed by its slot key
/// (`left_medial`, `right_scale`, …) — the SAME key the repo uses for the
/// storage filename, so a row maps unambiguously to a file.
class PhotoProgress {
  const PhotoProgress({
    required this.key,
    this.transferred = 0,
    this.total = 0,
    this.done = false,
  });

  final String key;
  final int transferred;
  final int total;
  final bool done;

  /// 0..1. Falls back to 1 once [done] even if no byte event ever arrived
  /// (a small file can complete before `snapshotEvents` emits a running tick).
  double get fraction =>
      done ? 1 : (total > 0 ? (transferred / total).clamp(0, 1) : 0);

  PhotoProgress copyWith({int? transferred, int? total, bool? done}) =>
      PhotoProgress(
        key: key,
        transferred: transferred ?? this.transferred,
        total: total ?? this.total,
        done: done ?? this.done,
      );
}

enum UploadPhase { uploading, success, error }

/// Snapshot of an in-flight (or finished) device upload. Lives in a provider,
/// not the capture widget, so it survives the navigation from `/capture` to the
/// progress screen — the upload keeps running while the camera screen disposes.
class UploadJob {
  const UploadJob({
    required this.phase,
    required this.box,
    required this.photos,
    this.deviceId,
    this.errorMessage,
  });

  final UploadPhase phase;
  final String box;
  final List<PhotoProgress> photos;

  /// Set once the Firestore doc is written (on [UploadPhase.success]).
  final String? deviceId;
  final String? errorMessage;

  int get total => photos.length;
  int get completed => photos.where((p) => p.done).length;

  /// Mean per-photo fraction — the overall bar.
  double get overall => photos.isEmpty
      ? 0
      : photos.map((p) => p.fraction).reduce((a, b) => a + b) / photos.length;

  UploadJob copyWith({
    UploadPhase? phase,
    List<PhotoProgress>? photos,
    String? deviceId,
    String? errorMessage,
  }) =>
      UploadJob(
        phase: phase ?? this.phase,
        box: box,
        photos: photos ?? this.photos,
        deviceId: deviceId ?? this.deviceId,
        errorMessage: errorMessage ?? this.errorMessage,
      );
}

/// Drives a single device upload and exposes its progress.
///
/// [start] sets the `uploading` state SYNCHRONOUSLY (before the first await) so
/// the progress screen has a job to render the instant it builds, then delegates
/// the actual work to [IncomingDeviceRepository.createIncoming] — the one
/// transaction boundary (upload all → write doc → compensate on failure) is
/// unchanged; this only observes its per-file progress callback.
class UploadJobController extends StateNotifier<UploadJob?> {
  UploadJobController(this._ref) : super(null);

  final Ref _ref;

  // Retained so a failed upload can be retried without re-walking capture. A
  // retry mints a fresh device doc id (the failed attempt's partial objects are
  // already compensated-deleted in `createIncoming`), so retry never dupes.
  DraftDevice? _draft;
  Map<String, String> _paths = const {};
  String _box = '';

  Future<void> start({
    required DraftDevice draft,
    required Map<String, String> namedPhotoPaths,
    required String box,
  }) async {
    _draft = draft;
    _paths = namedPhotoPaths;
    _box = box;
    await _run();
  }

  /// Re-run the last upload after a failure. No-op if nothing was started.
  Future<void> retry() async {
    if (_draft != null) await _run();
  }

  Future<void> _run() async {
    final draft = _draft;
    if (draft == null) return;
    state = UploadJob(
      phase: UploadPhase.uploading,
      box: _box,
      photos: [for (final k in _paths.keys) PhotoProgress(key: k)],
    );

    final repo = _ref.read(incomingDeviceRepositoryProvider);
    try {
      final id = await repo.createIncoming(
        draft,
        namedPhotoPaths: _paths,
        onProgress: (key, sent, total) {
          final cur = state;
          if (cur == null) return;
          // Mark a photo done the moment its bytes top out, so the "N of 14"
          // count ticks up as each upload finishes (uploads run a couple at a
          // time) rather than jumping 0 -> 14 only when the whole job settles.
          final finished = total > 0 && sent >= total;
          state = cur.copyWith(
            photos: [
              for (final p in cur.photos)
                p.key == key
                    ? p.copyWith(transferred: sent, total: total, done: finished)
                    : p,
            ],
          );
        },
      );
      final cur = state;
      if (cur == null) return;
      state = cur.copyWith(
        phase: UploadPhase.success,
        deviceId: id,
        photos: [for (final p in cur.photos) p.copyWith(done: true)],
      );
    } on FirebaseException catch (e) {
      state = state?.copyWith(
        phase: UploadPhase.error,
        errorMessage: PersistErrorKind.fromCode(e.code).userMessage,
      );
    } catch (_) {
      state = state?.copyWith(
        phase: UploadPhase.error,
        errorMessage: 'Upload failed. Check your connection and try again.',
      );
    }
  }

  /// Forget the finished/failed job — call after navigating away so a stale
  /// job never flashes on the next entry to the progress screen.
  void clear() => state = null;
}

final uploadJobProvider =
    StateNotifierProvider<UploadJobController, UploadJob?>(
  (ref) => UploadJobController(ref),
);
