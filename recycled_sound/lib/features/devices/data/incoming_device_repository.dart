import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import 'models/device.dart';

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

  /// Create a new incoming device record.
  ///
  /// Allocates a fresh doc id, uploads each local photo to Storage under
  /// `incoming/{id}/photos/`, then writes the Firestore document with the
  /// resulting gs:// URIs merged into [device]'s `photos` field.
  ///
  /// Returns the new document id.
  Future<String> createIncoming(
    Device device, {
    List<String> localPhotoPaths = const [],
  }) async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) {
      throw StateError('Must be signed in to create an incoming device');
    }

    final ref = _col.doc();
    final id = ref.id;

    final photoUris = <String>[];
    for (var i = 0; i < localPhotoPaths.length; i++) {
      final local = localPhotoPaths[i];
      final storageRef = _storage.ref('incoming/$id/photos/$i.jpg');
      await storageRef.putFile(File(local));
      photoUris.add('gs://${storageRef.bucket}/${storageRef.fullPath}');
    }

    final withPhotos = Device(
      id: id,
      brand: device.brand,
      model: device.model,
      type: device.type,
      year: device.year,
      serialLeft: device.serialLeft,
      serialRight: device.serialRight,
      batterySize: device.batterySize,
      domeType: device.domeType,
      waxFilter: device.waxFilter,
      receiver: device.receiver,
      programmingInterface: device.programmingInterface,
      techLevel: device.techLevel,
      gainRange: device.gainRange,
      fittingRange: device.fittingRange,
      remoteFT: device.remoteFT,
      appCompatible: device.appCompatible,
      auracast: device.auracast,
      chargerType: device.chargerType,
      accessories: device.accessories,
      condition: device.condition,
      qaStatus: device.qaStatus,
      status: device.status,
      servicingNotes: device.servicingNotes,
      servicingCost: device.servicingCost,
      donorId: device.donorId,
      scanId: device.scanId,
      photos: [...device.photos, ...photoUris],
    );

    await ref.set(withPhotos.toFirestore(createdBy: uid));
    return id;
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
