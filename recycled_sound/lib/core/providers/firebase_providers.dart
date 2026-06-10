// Excluded from coverage: Firebase service-singleton providers; trivial wiring
// coverage:ignore-file
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/scanner/data/device_catalog.dart';
import '../../features/scanner/data/embedding_search.dart';
import '../../features/scanner/data/scanner_repository.dart';

/// Firebase service providers. Canonical home for SDK singletons —
/// feature-level provider files should import from here, never redefine.

final firebaseAuthProvider = Provider<FirebaseAuth>((ref) {
  return FirebaseAuth.instance;
});

final firebaseStorageProvider = Provider<FirebaseStorage>((ref) {
  return FirebaseStorage.instance;
});

final firestoreProvider = Provider<FirebaseFirestore>((ref) {
  return FirebaseFirestore.instance;
});

final firebaseFunctionsProvider = Provider<FirebaseFunctions>((ref) {
  return FirebaseFunctions.instanceFor(region: 'australia-southeast1');
});

/// On-device CLIP embedding search — singleton, loaded once at first scan.
final embeddingSearchProvider = Provider<EmbeddingSearch>((ref) {
  return EmbeddingSearch.instance;
});

/// Device catalog — singleton, loaded once at first scan.
final deviceCatalogProvider = Provider<DeviceCatalog>((ref) {
  return DeviceCatalog.instance;
});

/// Scanner repository with full hybrid pipeline.
final scannerRepositoryProvider = Provider<ScannerRepository>((ref) {
  return ScannerRepository(
    auth: ref.watch(firebaseAuthProvider),
    storage: ref.watch(firebaseStorageProvider),
    functions: ref.watch(firebaseFunctionsProvider),
    embeddingSearch: ref.watch(embeddingSearchProvider),
    deviceCatalog: ref.watch(deviceCatalogProvider),
  );
});
