import 'package:cloud_firestore/cloud_firestore.dart';

import 'models/user_profile.dart';

/// Read/write access to `users/{uid}` profile documents.
class UserProfileRepository {
  UserProfileRepository({required FirebaseFirestore firestore})
      : _firestore = firestore;

  final FirebaseFirestore _firestore;

  DocumentReference<Map<String, dynamic>> _doc(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Create the profile doc for a fresh signup. Caller MUST pass the
  /// Firebase Auth uid; the rules pin `request.auth.uid == uid` so a wrong
  /// uid fails at the rules layer.
  Future<void> createOnSignup(UserProfile profile) async {
    await _doc(profile.uid).set(profile.toFirestoreNew());
  }

  /// Live stream of a profile by uid. Emits null if the doc doesn't exist
  /// (typical for anonymous users — no signup means no profile).
  Stream<UserProfile?> watchById(String uid) => _doc(uid)
      .snapshots()
      .map((s) => s.exists ? UserProfile.fromFirestore(s) : null);
}
