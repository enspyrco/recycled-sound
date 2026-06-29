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

/// How many reference photo-sets already exist for a given (brand, model) —
/// the coverage signal surfaced on the confirm screen so the volunteer can
/// chase DIVERSITY (capture models with few/no sets) instead of piling
/// redundant shots onto a well-covered model. Keyed on a (brand, model) record
/// so it recomputes as the confirm fields are edited. Counts only records WITH
/// photos, across both the curated register and the incoming queue.
///
/// `autoDispose` is load-bearing for CORRECTNESS, not just memory: without it a
/// key's count caches for the whole app session, so scan P90 (0 sets) → capture
/// photos → scan P90 again would still read "0" from the stale cache. Disposing
/// when unwatched (leaving the confirm screen) means the next scan re-queries
/// and reflects the just-captured set. Callers should key on TRIMMED values so
/// whitespace edits don't spawn redundant cache entries.
final referenceSetCountProvider =
    FutureProvider.autoDispose.family<int, ({String brand, String model})>((
  ref,
  key,
) {
  return ref
      .watch(incomingDeviceRepositoryProvider)
      .countReferenceSetsFor(key.brand, key.model);
});
