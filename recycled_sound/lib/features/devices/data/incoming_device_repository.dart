import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'package:recycled_sound/core/clinical_field.dart';

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
  ///
  /// Covers BOTH surfaces this persist call touches: Firestore codes
  /// (`permission-denied`, `unavailable`, …) and Cloud Storage codes, which
  /// arrive plugin-prefixed (`storage/unauthorized`, `storage/quota-exceeded`,
  /// `storage/retry-limit-exceeded`). The prefix is stripped first so both
  /// spellings land on the same kind — a Storage upload failure inside
  /// `createIncoming` is just as much a "persist failure" as a Firestore write.
  static PersistErrorKind fromCode(String code) {
    // Normalize `storage/unauthorized` → `unauthorized` etc. Firestore codes
    // are unprefixed, so this is a no-op for them.
    final bare = code.contains('/') ? code.split('/').last : code;
    return switch (bare) {
      'permission-denied' || 'unauthorized' || 'unauthenticated' =>
        permissionDenied,
      'unavailable' ||
      'deadline-exceeded' ||
      'network-request-failed' ||
      'retry-limit-exceeded' =>
        unavailable,
      'resource-exhausted' || 'quota-exceeded' => resourceExhausted,
      _ => unknown,
    };
  }

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

/// The audiologist's review-screen edits, merged onto an incoming doc inside
/// [IncomingDeviceRepository.promoteToDevice]'s transaction so the gate sees
/// (and the write commits) one consistent result. [needsInputFields] is the
/// still-unresolved recognised set — the review screen shrinks it as fields are
/// resolved; [unrecognisedNeedsInput] preserves blocker keys we couldn't type.
///
/// **Identity fields (brand/model/type/batterySize) are editable here (#783).**
/// Before #783 the audiologist could only *override* a flagged identity field —
/// assert authority to promote a known-wrong AI read, never correct it. These
/// four carry the audiologist's corrected value so a flagged identity field has
/// a real *resolution* path: the corrected value is persisted AND the flag drops
/// out of [needsInputFields], so the gate sees it resolved rather than overridden.
class ReviewEdits {
  const ReviewEdits({
    required this.brand,
    required this.model,
    required this.type,
    required this.batterySize,
    required this.tubing,
    required this.powerSource,
    required this.colour,
    required this.location,
    required this.servicingNotes,
    required this.servicingCost,
    this.needsInputFields = const [],
    this.unrecognisedNeedsInput = const [],
  });

  /// The four scanner-read identity fields the audiologist may now correct
  /// (#783). brand/model stay free-text; [type] (Style) and [batterySize] are
  /// typed closed-set pickers (#15). Carry the AI's read unchanged when the
  /// audiologist doesn't edit.
  final String brand;
  final String model;
  final Style type;
  final BatterySize batterySize;

  final Tubing tubing;
  final PowerSource powerSource;
  final String colour;
  final String location;
  final String servicingNotes;
  final double servicingCost;
  final List<ClinicalField> needsInputFields;
  final List<String> unrecognisedNeedsInput;
}

/// Read/write access to the `incoming/` collection — the scanner's write-target
/// for newly-identified devices awaiting audiologist triage.
///
/// Photos land in Storage at `captures/{uid}/{deviceId}/{slot}.jpg`, where
/// `{deviceId}` is this `incoming/{id}` doc's id. The Firestore doc holds their
/// gs:// URIs in the `photos` array so clients can resolve them with
/// [FirebaseStorage.refFromURL].
///
/// **Why `captures/{uid}/...`.** uid is the OUTER path segment so it acts as
/// the storage-rules security boundary (the rule gates on the path alone —
/// no cross-service `firestore.get` needed). `captures/` is the durable intake
/// bucket, deliberately distinct from the transient `scans/` snapshots the
/// live scanner writes mid-session. The redundant `incoming/` path segment of
/// the old `scans/{uid}/incoming/{id}/` shape is dropped — the doc id already
/// scopes the device.
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
  /// `captures/{uid}/{deviceId}/`, then writes the Firestore document with the
  /// resulting gs:// URIs merged into the draft's `photos` field. Returns the
  /// new document id.
  ///
  /// Takes a [DraftDevice], not a [Device]: the caller has no id to give
  /// (Firestore allocates it here), and the DraftDevice→Device promotion via
  /// [DraftDevice.toDevice] is also where `createdBy` gets pinned for the
  /// rules layer. Modelling the pre-persist state with a sentinel `id: ''`
  /// would let a never-persisted record masquerade as a real one.
  ///
  /// **Photo path: `captures/{uid}/{deviceId}/…`, NOT `incoming/{id}/photos/…`.**
  /// The `incoming/{id}/photos` Storage rule gates writes via a cross-service
  /// `firestore.get` of the doc's `createdBy`. That cross-service lookup does
  /// not resolve in production (verified 2026-05-21: an anonymous user with
  /// the doc present and `createdBy == uid` still gets `storage/unauthorized`),
  /// so every non-elevated upload there is denied. The `captures/{uid}/**` rule
  /// is pure-uid (no Firestore lookup) and works, and gives STRICTER isolation
  /// (each user owns their own prefix). `captures/` is the DURABLE intake bucket,
  /// distinct from the transient scan-mode `scans/` snapshots. So capture photos
  /// live under `captures/{uid}/{deviceId}/…`; the device doc references URIs.
  /// `contentType` is set explicitly so the rule's `image/.*` predicate holds
  /// regardless of how the platform infers it from the file.
  ///
  /// **Atomicity.** Uploads run in parallel (one slow round-trip instead of N
  /// serial). If *any* upload fails, or the Firestore write that follows
  /// fails, every object that *did* upload is deleted before the error
  /// propagates — and since these objects live under the caller's own
  /// `scans/{uid}/` prefix, the creator can actually delete them, so a partial
  /// failure leaves no orphaned objects AND no record (the doc isn't written
  /// until all uploads succeed). The happy path: upload all, then one `set`.
  /// [localPhotoPaths] are uploaded under positional filenames (`0.jpg`,
  /// `1.jpg`, …) — used by the scanner, which has no slot semantics.
  /// [namedPhotoPaths] maps a stable key (the [CaptureSlot] name) to a local
  /// path and uploads under `{key}.jpg`. Prefer the named form when the
  /// filename must encode *which* photo it is: a positional scheme silently
  /// mislabels photos when an earlier slot is skipped and the list compacts.
  Future<String> createIncoming(
    DraftDevice draft, {
    List<String> localPhotoPaths = const [],
    Map<String, String> namedPhotoPaths = const {},
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
        // captures/{uid}/{deviceId}/{slot}.jpg — uid is the security boundary,
        // the doc id is the device, `$i` is the slot/index filename.
        final storageRef = _storage.ref('captures/$uid/$id/$i.jpg');
        uploads.add(_uploadPhoto(storageRef, localPhotoPaths[i], uploaded));
      }
      // Slot-keyed uploads: the filename IS the slot identity, so a skipped
      // slot never shifts another photo's label.
      for (final entry in namedPhotoPaths.entries) {
        final storageRef =
            _storage.ref('captures/$uid/$id/${entry.key}.jpg');
        uploads.add(_uploadPhoto(storageRef, entry.value, uploaded));
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

  /// Upload one local file (as image/jpeg) and record its [Reference] in
  /// [uploaded] (so a later failure can compensate by deleting it). Returns
  /// the gs:// URI. The explicit `contentType` keeps the Storage rule's
  /// `image/.*` predicate satisfied independent of file-extension inference.
  Future<String> _uploadPhoto(
    Reference storageRef,
    String localPath,
    List<Reference> uploaded,
  ) async {
    await storageRef.putFile(
      File(localPath),
      SettableMetadata(contentType: 'image/jpeg'),
    );
    uploaded.add(storageRef);
    return 'gs://${storageRef.bucket}/${storageRef.fullPath}';
  }

  /// Remove one photo from an incoming device — drops the gs:// URI from the
  /// doc's `photos` array, then best-effort deletes the Storage object.
  ///
  /// **Doc-first, by design.** The Firestore `photos` array is the authoritative
  /// list of "which photos exist" (the boundary-between-two-truths rule: pick
  /// the authoritative surface and derive the other). Removing the URI first
  /// means the UI — which streams the doc — updates immediately and can never
  /// render a thumbnail whose object has already been deleted (a 404). The
  /// Storage delete that follows is best-effort: if it fails, the object is
  /// orphaned (a cheap, sweepable cost) rather than leaving a dangling
  /// reference (a user-visible broken image). An already-missing object
  /// (`object-not-found`) is fine — a re-delete then just cleans the array.
  ///
  /// [photoRef] is whatever is stored in `photos` — a `gs://` URI or an https
  /// download URL; [FirebaseStorage.refFromURL] accepts both.
  Future<void> deletePhoto(String deviceId, String photoRef) async {
    await _col.doc(deviceId).update({
      'photos': FieldValue.arrayRemove([photoRef]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    // Best-effort: the doc is already consistent. A failed object delete
    // (including an already-missing object) leaves at worst a sweepable
    // orphan, never a dangling reference, so it must not fail the call. The
    // refFromURL parse is inside the guard too — a malformed photoRef must not
    // escape after the array is already cleaned (the doc-first invariant).
    try {
      await _storage.refFromURL(photoRef).delete();
    } catch (_) {
      // Swallow — orphan cleanup is a separate concern.
    }
  }

  /// Delete an entire incoming device — the Firestore doc and every photo
  /// blob beneath the caller's `captures/{uid}/{deviceId}/` prefix.
  ///
  /// **Photos first, then doc — best-effort on Storage.** Mirrors the
  /// rollback intent of [createIncoming] from the opposite direction: the
  /// recoverable side of the boundary (Storage objects, sweepable orphans)
  /// runs first; the authoritative side (the Firestore doc, the only thing
  /// the UI streams) flips last. If a blob delete fails mid-loop, we log the
  /// failure and still delete the doc — the volunteer cannot realistically
  /// retry a half-deleted device, and a leftover blob is a separate
  /// sweep-job concern (cf. [deletePhoto]'s "object 404 is fine" stance).
  /// If the Firestore delete itself fails (rules rejection, offline) we
  /// rethrow — the user-visible record is still there and the action did
  /// nothing the user can see.
  ///
  /// Storage path is the per-uid `captures/{uid}/{deviceId}/` prefix used by
  /// the in-app capture flow (see [createIncoming]'s doc-comment for why the
  /// cross-service-gated `incoming/{id}/photos/` path was abandoned). The
  /// server-side cascade (cascadeIncomingDelete) ALSO fires on the doc delete
  /// below and sweeps legacy prefixes for pre-migration data; this client
  /// sweep targets the current `captures/` path.
  /// [listAll] is bounded by the small per-device photo count (≤ a handful of
  /// slot photos) — no pagination needed at this scale.
  Future<void> deleteIncoming(String id) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw StateError('Must be signed in to delete an incoming device');
    }
    // Best-effort photo sweep. Listing the prefix can itself fail (e.g.
    // offline) — that's still an acceptable degenerate, the doc-delete
    // below is the authoritative half.
    try {
      final listing = await _storage.ref('captures/$uid/$id').listAll();
      await Future.wait(
        listing.items.map((r) => r.delete().catchError((_) {})),
      );
    } catch (_) {
      // Swallow — orphan cleanup is a separate concern, identical reasoning
      // to [deletePhoto].
    }
    await _col.doc(id).delete();
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

  /// Persist the audiologist's review edits onto an `incoming/{id}` doc.
  ///
  /// A focused review update — the scanner-read identity fields (since #783), the
  /// human-determined clinical fields, location, servicing notes/cost, and an
  /// optional [qaStatus] flip.
  ///
  /// **Identity fields are always rewritten from the review screen (#783).** This
  /// call historically excluded brand/model/type/batterySize to avoid clobbering
  /// the scanner's read. #783 reverses that: the review screen IS the audiologist's
  /// authority over these fields, so it writes all four every time. An unedited
  /// field round-trips its existing value (a no-op write); a corrected field
  /// persists the new value; a flagged-but-uncorrected field persists the empty
  /// string ([IncomingReviewDetailScreen] de-sentinels `'Unknown'` → `''`) while
  /// its flag stays in [needsInputFields]. Integrity is enforced at the BACKEND:
  /// the `devices/` rules reject any promotion where a clinical field is
  /// empty/sentinel but not declared a blocker (value↔flag consistency, #89), so
  /// an empty identity value can only cross the boundary as a declared+overridden
  /// blocker. `year` stays read-only — not a [ClinicalField], never gates.
  ///
  /// Enums serialize via their `.wire` form so the stored strings match the
  /// model's `fromWire` parse and the scanner/confirm-screen contract.
  /// `updatedAt` is bumped server-side. Only audiologists/admins may write the
  /// `incoming/` doc's review fields; the rules layer rejects other callers.
  ///
  /// When [needsInputFields] is provided it OVERWRITES the doc's flag set — the
  /// review screen passes the shrunk set as the audiologist resolves fields, so
  /// a resolved flag drops out of the "needs input" list (and the promotion gate
  /// sees it as resolved). [unrecognisedNeedsInput] is re-appended verbatim so a
  /// tolerant read→write never destroys a blocker key we couldn't interpret.
  /// Omit [needsInputFields] (null) to leave the persisted set untouched.
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
    final data = <String, dynamic>{
      // Identity fields are always rewritten — the review screen is the
      // audiologist's authority over them. Backend value↔flag consistency (#89)
      // is what protects an empty value from crossing into devices/ unflagged.
      'brand': brand,
      'model': model,
      'type': type.wire,
      'batterySize': batterySize.wire,
      'tubing': tubing.wire,
      'powerSource': powerSource.wire,
      'colour': colour,
      'location': location,
      'servicingNotes': servicingNotes,
      'servicingCost': servicingCost,
      'updatedAt': FieldValue.serverTimestamp(),
      if (qaStatus != null) 'qaStatus': qaStatus.wire,
      if (needsInputFields != null)
        'needsInputFields': [
          ...needsInputFields.toWireList(),
          ...unrecognisedNeedsInput,
        ],
    };
    await _col.doc(id).update(data);
  }

  /// Triage promotion: copy an incoming doc into `devices/{id}` (with
  /// `qaStatus` flipped to passed) and delete the original. Runs as a
  /// batched write so the two sides land atomically.
  ///
  /// Only audiologists/admins have write access to `devices/`; the rules layer
  /// rejects this call for any other caller AND independently enforces the gate
  /// (a flagged `devices/` doc requires a self-attributed `qaOverride`).
  ///
  /// **GATE-ENFORCED TRUST BOUNDARY — runs in a single transaction.** Within one
  /// [FirebaseFirestore.runTransaction] the doc is read, the audiologist's
  /// [edits] are merged onto it, and [Device.reviewForPromotion] is computed on
  /// that MERGED result — so the verdict, the audit record, and the bytes
  /// written all agree (no detached `update()`→`get()` window that could clobber
  /// edits or gate against a stale read; the earlier split-call shape had both
  /// failure modes — Kelvin/Carnot, PR #87 cage-match).
  ///
  /// A [Promotable] verdict promotes cleanly. A [NeedsResolution] verdict
  /// promotes ONLY when [allowOverride] is true — and then a [QaOverride] is
  /// stamped from the VERDICT'S OWN `unresolved`/`unrecognised` sets (never
  /// caller-supplied field lists), so the audit trail cannot misdescribe what
  /// was actually overridden. With blockers and no override this throws: there
  /// is no path from scanner/volunteer uncertainty into the curated register
  /// without either resolved fields or a recorded, attributable human decision.
  ///
  /// [edits] is null for the queue's clean quick-Approve (no review edits to
  /// merge); the gate still runs and a still-flagged doc fails closed.
  Future<void> promoteToDevice(
    String incomingId, {
    ReviewEdits? edits,
    bool allowOverride = false,
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      // 'unknown' is not an attribution for a clinical audit record — fail
      // closed rather than stamp an unattributable override (Carnot, #87).
      throw StateError('Must be signed in to promote a device');
    }
    await _firestore.runTransaction((tx) async {
      final ref = _col.doc(incomingId);
      final src = await tx.get(ref);
      if (!src.exists) {
        throw StateError('No incoming/$incomingId to promote');
      }
      final data = Map<String, dynamic>.from(src.data() ?? const {});
      if (edits != null) {
        // Identity corrections (#783) merge in alongside the clinical fields, so
        // the gate below evaluates [reviewForPromotion] on the value the
        // audiologist actually corrected to — a brand the audiologist fixed is
        // resolved (dropped from needsInputFields) and promotes clean, not via
        // override.
        data['brand'] = edits.brand;
        data['model'] = edits.model;
        data['type'] = edits.type.wire;
        data['batterySize'] = edits.batterySize.wire;
        data['tubing'] = edits.tubing.wire;
        data['powerSource'] = edits.powerSource.wire;
        data['colour'] = edits.colour;
        data['location'] = edits.location;
        data['servicingNotes'] = edits.servicingNotes;
        data['servicingCost'] = edits.servicingCost;
        data['needsInputFields'] = [
          ...edits.needsInputFields.toWireList(),
          ...edits.unrecognisedNeedsInput,
        ];
      }

      // Gate on the MERGED result via the same partition the model uses, so the
      // verdict reflects exactly what is about to be written.
      final blockers = ClinicalField.partition(data['needsInputFields']);
      final verdict = Device(
        id: incomingId,
        brand: '',
        model: '',
        needsInputFields: blockers.known,
        unrecognisedNeedsInput: blockers.unknown,
      ).reviewForPromotion();

      switch (verdict) {
        case Promotable():
          // Every flag resolved — clean promotion, no override record even if
          // allowOverride was passed.
          break;
        case NeedsResolution(:final unresolved, :final unrecognised):
          if (!allowOverride) {
            throw StateError(
              'Refusing to promote incoming/$incomingId: '
              '${unresolved.map((f) => f.wire).toList()} + $unrecognised '
              'unresolved and override not authorised.',
            );
          }
          // Stamp the VERDICT's own sets — the source of truth — not anything
          // the caller passed.
          data['qaOverride'] = QaOverride(
            overriddenBy: uid,
            overriddenAt: DateTime.now(),
            fields: unresolved,
            unrecognised: unrecognised,
          ).toFirestore();
      }
      data['qaStatus'] = QaStatus.passed.wire;
      data['updatedAt'] = FieldValue.serverTimestamp();
      tx.set(_devicesCol.doc(incomingId), data);
      tx.delete(ref);
    });
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
