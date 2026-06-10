// Excluded from coverage: Firebase Storage + Cloud Functions orchestration; needs emulator
// coverage:ignore-file
import 'dart:io';
import 'dart:typed_data';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../providers/scanner_providers.dart';
import 'device_catalog.dart';
import 'embedding_search.dart';
import 'models/scan_result.dart';
import 'scan_fusion.dart';

/// Repository for the hearing aid scanner feature.
///
/// Orchestrates the hybrid scanner pipeline:
/// 1. Upload image to Firebase Storage
/// 2. Call CLIP Cloud Function + Vision API Cloud Function in parallel
/// 3. Run on-device cosine similarity search with CLIP vector
/// 4. Fuse CLIP results + Vision results into a confident ScanResult
class ScannerRepository {
  ScannerRepository({
    required FirebaseAuth auth,
    required FirebaseStorage storage,
    required FirebaseFunctions functions,
    required EmbeddingSearch embeddingSearch,
    required DeviceCatalog deviceCatalog,
  })  : _auth = auth,
        _storage = storage,
        _functions = functions,
        _fusion = ScanFusion(
          embeddingSearch: embeddingSearch,
          deviceCatalog: deviceCatalog,
        ),
        _embeddingSearch = embeddingSearch,
        _deviceCatalog = deviceCatalog;

  final FirebaseAuth _auth;
  final FirebaseStorage _storage;
  final FirebaseFunctions _functions;
  final ScanFusion _fusion;
  final EmbeddingSearch _embeddingSearch;
  final DeviceCatalog _deviceCatalog;

  /// Analyze a hearing aid photo using the hybrid scanner pipeline.
  ///
  /// [imagePath] is the local file path from the camera/gallery.
  /// [onProgress] is called with status messages for the analysing screen.
  Future<ScanResult> analyzeImage(
    String imagePath, {
    void Function(String status)? onProgress,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      throw StateError('Must be signed in to scan');
    }

    // Ensure on-device assets are loaded
    onProgress?.call('Loading device database…');
    await Future.wait([
      _embeddingSearch.loadFromAsset(),
      _deviceCatalog.loadFromAsset(),
    ]);

    // 1. Upload image to Firebase Storage
    onProgress?.call('Uploading image…');
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final ref = _storage.ref('scans/${user.uid}/$timestamp.jpg');
    await ref.putFile(File(imagePath));
    final gsUrl =
        'gs://${ref.storage.bucket}/${ref.fullPath}';

    // 2. Call CLIP + Vision API in parallel
    onProgress?.call('Identifying hearing aid…');
    final clipCallable = _functions.httpsCallable(
      'clip_encode',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
    );
    final visionCallable = _functions.httpsCallable(
      'analyzeHearingAid',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );

    final results = await Future.wait([
      clipCallable.call<Map<String, dynamic>>({'imageUrl': gsUrl}),
      visionCallable.call<Map<String, dynamic>>({'imageUrl': gsUrl}),
    ]);

    final clipData = results[0].data;
    final visionData = results[1].data;

    // 3. Parse CLIP embedding into Float32List
    final rawEmbedding = clipData['embedding'] as List<dynamic>;
    final clipEmbedding = Float32List.fromList(
      rawEmbedding.map((e) => (e as num).toDouble()).toList(),
    );

    // 4. Fuse results
    onProgress?.call('Matching specifications…');
    final scanId = visionData['scanId'] as String? ?? 'scan-$timestamp';
    final downloadUrl = await ref.getDownloadURL();

    return _fusion.fuse(
      clipEmbedding: clipEmbedding,
      visionResult: visionData,
      imageUrl: downloadUrl,
      scanId: scanId,
    );
  }

  /// Submit corrections for a completed scan.
  Future<void> submitCorrections({
    required String scanId,
    required List<Correction> corrections,
    required String userId,
    required String userRole,
  }) async {
    // TODO: Wire up Firestore batch write to scans/{scanId}/corrections
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }

  /// Create a device in the register from a scan result.
  Future<String> addToRegister(ScanResult result) async {
    // TODO: Wire up Firestore write to devices collection
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return 'mock-device-id';
  }
}
