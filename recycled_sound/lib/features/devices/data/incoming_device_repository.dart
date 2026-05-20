import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'models/device.dart';

/// Known [FirebaseException] states a persist call can surface to the UI.
///
/// Mirrors the `AuthErrorKind` pattern from the email/password auth PR: parse
/// the open-ended `code` String into a closed, typed set at this boundary so
/// the widget switches over variants instead of inlining brittle string
/// comparisons. New Firestore error codes fall through to [unknown] rather
/// than crashing the volunteer's intake flow.
enum PersistErrorKind {
  /// Rules rejected the write — e.g. `createdBy` didn't match the caller, or
  /// the caller lacks the required role.
  permissionDenied,

  /// Backend unreachable / client offline.
  unavailable,

  /// Quota or rate limit hit.
  resourceExhausted,

  /// Anything else (or a non-Firebase error).
  unknown;

  /// Parse the `code` field of a [FirebaseException] into a typed kind.
  static PersistErrorKind fromCode(String code) => switch (code) {
        'permission-denied' => permissionDenied,
        'unavailable' || 'deadline-exceeded' || 'network-request-failed' =>
          unavailable,
        'resource-exhausted' => resourceExhausted,
        _ => unknown,
      };

  /// Human-readable copy for clinic volunteers. Kept short — surfaces in a
  /// snackbar.
  String get userMessage => switch (this) {
        permissionDenied =>
          "You don't have access to add this device. Ask an admin.",
        unavailable => "You're offline. Reconnect and try again.",
        resourceExhausted =>
          'The register is at capacity right now. Contact an admin.',
        unknown => 'Failed to save. Please try again.',
      };
}

/// Read/write access to the `incoming/` collection — the scanner's write-target
/// for newly-identified devices awaiting audiologist triage.
///
/// Photos land in Storage at `incoming/{incomingId}/photos/{idx}.jpg`; the
/// Firestore doc holds their gs:// URIs in the `photos` array so clients can
/// resolve them with [FirebaseStorage.refFromURL].
class IncomingDeviceRepository {
  IncomingDeviceRepository({
    required FirebaseFirestore firestore,
    required FirebaseStorage storage,
    required FirebaseAuth auth,
  })  : _firestore = firestore,
        _storage = storage,
        _auth = auth;

  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage;
  final FirebaseAuth _auth;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('incoming');

  /// Create a new incoming device record from an unpersisted [DraftDevice].
  ///
  /// Allocates a fresh doc id, uploads each local photo to Storage under
  /// `incoming/{id}/photos/`, then writes the Firestore document with the
  /// resulting gs:// URIs merged into the draft's `photos` field. Returns the
  /// new document id.
  ///
  /// Takes a [DraftDevice], not a [Device]: the caller has no id to give
  /// (Firestore allocates it here), and the DraftDevice→Device promotion via
  /// [DraftDevice.toDevice] is also where `createdBy` gets pinned for the
  /// rules layer. Modelling the pre-persist state with a sentinel `id: ''`
  /// would let a never-persisted record masquerade as a real one.
  ///
  /// **Atomicity.** Photo uploads run in parallel (one slow network round-trip
  /// instead of N serial ones). If *any* upload fails, or the Firestore write
  /// that follows fails, every object that *did* upload is deleted before the
  /// error propagates — so a partial failure leaves no orphaned Storage
  /// objects and no half-written record. The happy path is unchanged: upload
  /// all photos, then one `set`.
  Future<String> createIncoming(
    DraftDevice draft, {
    List<String> localPhotoPaths = const [],
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw StateError('Must be signed in to create an incoming device');
    }

    final ref = _col.doc();
    final id = ref.id;

    // Storage refs we successfully wrote — kept so we can compensate
    // (delete them) if a later step throws, closing the orphaned-object window.
    final uploaded = <Reference>[];
    try {
      // Parallel uploads: ~max(upload latency) instead of sum of all.
      final uploads = <Future<String>>[];
      for (var i = 0; i < localPhotoPaths.length; i++) {
        final storageRef = _storage.ref('incoming/$id/photos/$i.jpg');
        uploads.add(_uploadPhoto(storageRef, localPhotoPaths[i], uploaded));
      }
      final photoUris = await Future.wait(uploads);

      final device = draft.toDevice(
        id: id,
        photos: [...draft.photos, ...photoUris],
      );
      await ref.set(device.toFirestore(createdBy: uid));
      return id;
    } catch (_) {
      // Compensating cleanup. Best-effort: a delete failing here must not mask
      // the original error, so each is caught and swallowed individually.
      await Future.wait(
        uploaded.map(
          (r) => r.delete().catchError((_) {}),
        ),
      );
      rethrow;
    }
  }

  /// Upload one local file and record its [Reference] in [uploaded] (so a
  /// later failure can compensate by deleting it). Returns the gs:// URI.
  Future<String> _uploadPhoto(
    Reference storageRef,
    String localPath,
    List<Reference> uploaded,
  ) async {
    await storageRef.putFile(File(localPath));
    uploaded.add(storageRef);
    return 'gs://${storageRef.bucket}/${storageRef.fullPath}';
  }

  /// Stream of incoming records created by the current user, newest first.
  ///
  /// The `.where('createdBy', isEqualTo: uid)` clause is REQUIRED — Firestore
  /// rules are not post-filters. A non-admin query without this predicate is
  /// rejected at the rules layer even for documents the user is allowed to
  /// read individually. Audiologist/admin "review queue" queries use
  /// [watchAllIncoming] instead.
  Stream<List<Device>> watchMyIncoming() {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return const Stream.empty();
    return _col
        .where('createdBy', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((q) => q.docs.map(Device.fromFirestore).toList());
  }

  /// Stream of every incoming record, newest first. Only allowed at the
  /// rules layer for users with `auth.token.role in [audiologist, admin]`.
  /// Calling this without the role returns permission-denied — callers
  /// should branch on the user's profile/claim before subscribing.
  Stream<List<Device>> watchAllIncoming() => _col
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((q) => q.docs.map(Device.fromFirestore).toList());

  /// Triage promotion: copy an incoming doc into `devices/{id}` (with
  /// `qaStatus` flipped to passed) and delete the original. Runs as a
  /// batched write so the two sides land atomically.
  ///
  /// Only audiologists/admins have write access to `devices/`; the rule
  /// layer rejects this call for any other caller.
  Future<void> promoteToDevice(String incomingId) async {
    final src = await _col.doc(incomingId).get();
    if (!src.exists) {
      throw StateError('No incoming/$incomingId to promote');
    }
    final data = Map<String, dynamic>.from(src.data() ?? const {});
    data['qaStatus'] = QaStatus.passed.wire;
    data['updatedAt'] = FieldValue.serverTimestamp();
    final batch = _firestore.batch();
    batch.set(_firestore.collection('devices').doc(incomingId), data);
    batch.delete(_col.doc(incomingId));
    await batch.commit();
  }

  /// Stream of a single incoming record. Emits `null` if the doc doesn't
  /// exist (e.g. promoted into `devices/` and deleted, or never written).
  Stream<Device?> watchIncomingById(String id) => _col
      .doc(id)
      .snapshots()
      .map((s) => s.exists ? Device.fromFirestore(s) : null);

  CollectionReference<Map<String, dynamic>> get _devicesCol =>
      _firestore.collection('devices');

  /// Live stream of curated devices (post-triage register). Any authed
  /// user can read; only audiologists/admins write.
  Stream<List<Device>> watchAllDevices() => _devicesCol
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((q) => q.docs.map(Device.fromFirestore).toList());

  /// Stream of a single curated device by id.
  Stream<Device?> watchDeviceById(String id) => _devicesCol
      .doc(id)
      .snapshots()
      .map((s) => s.exists ? Device.fromFirestore(s) : null);
}
