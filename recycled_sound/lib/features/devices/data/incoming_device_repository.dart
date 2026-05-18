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

  /// Stream of all incoming records, newest first.
  ///
  /// Security rules limit visibility: regular users see only what they
  /// created; audiologists/admins see everything.
  Stream<List<Device>> watchIncoming() => _col
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((q) => q.docs.map(Device.fromFirestore).toList());

  /// Stream of a single incoming record. Emits `null` if the doc doesn't
  /// exist (e.g. promoted into `devices/` and deleted, or never written).
  Stream<Device?> watchIncomingById(String id) => _col
      .doc(id)
      .snapshots()
      .map((s) => s.exists ? Device.fromFirestore(s) : null);
}
