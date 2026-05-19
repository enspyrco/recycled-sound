import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/firebase_providers.dart';
import '../data/incoming_device_repository.dart';
import '../data/models/device.dart';

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

/// Live stream of incoming records visible to the current user (own only).
///
/// Audiologists/admins should use a separate query for triage review — see
/// future `incomingForReviewProvider`.
final incomingDevicesStreamProvider = StreamProvider<List<Device>>((ref) {
  return ref.watch(incomingDeviceRepositoryProvider).watchMyIncoming();
});

/// Live stream of a single incoming record by id.
final incomingDeviceByIdProvider =
    StreamProvider.family<Device?, String>((ref, id) {
  return ref.watch(incomingDeviceRepositoryProvider).watchIncomingById(id);
});

/// Audiologist/admin queue — every incoming doc, newest first. Returns
/// permission-denied if the caller doesn't have an elevated role; the UI
/// should branch on the user's role claim before subscribing.
final allIncomingDevicesProvider = StreamProvider<List<Device>>((ref) {
  return ref.watch(incomingDeviceRepositoryProvider).watchAllIncoming();
});

/// Curated device register, post-triage. Readable by any authed user.
final allDevicesProvider = StreamProvider<List<Device>>((ref) {
  return ref.watch(incomingDeviceRepositoryProvider).watchAllDevices();
});

/// Single curated device by id.
final deviceByIdProvider =
    StreamProvider.family<Device?, String>((ref, id) {
  return ref.watch(incomingDeviceRepositoryProvider).watchDeviceById(id);
});
