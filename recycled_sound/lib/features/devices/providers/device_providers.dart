import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/incoming_device_repository.dart';
import '../data/models/device.dart';

/// Firebase service singletons. Overridable in tests via ProviderScope.
final firestoreProvider =
    Provider<FirebaseFirestore>((_) => FirebaseFirestore.instance);
final firebaseStorageProvider =
    Provider<FirebaseStorage>((_) => FirebaseStorage.instance);
final firebaseAuthProvider =
    Provider<FirebaseAuth>((_) => FirebaseAuth.instance);

/// The incoming-device repository — scanner writes, list/detail reads.
final incomingDeviceRepositoryProvider = Provider<IncomingDeviceRepository>((
  ref,
) {
  return IncomingDeviceRepository(
    firestore: ref.watch(firestoreProvider),
    storage: ref.watch(firebaseStorageProvider),
    auth: ref.watch(firebaseAuthProvider),
  );
});

/// Live stream of all incoming records visible to the current user.
final incomingDevicesStreamProvider = StreamProvider<List<Device>>((ref) {
  return ref.watch(incomingDeviceRepositoryProvider).watchIncoming();
});

/// Live stream of a single incoming record by id.
final incomingDeviceByIdProvider =
    StreamProvider.family<Device?, String>((ref, id) {
  return ref.watch(incomingDeviceRepositoryProvider).watchIncomingById(id);
});
