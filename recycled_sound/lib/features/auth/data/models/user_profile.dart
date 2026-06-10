import 'package:cloud_firestore/cloud_firestore.dart';

/// User's role in the Recycled Sound system.
///
/// Audiologist and admin are NOT self-assignable at signup — they're
/// granted by an existing admin (see `users/{uid}.role` server-side update
/// guarded by the firestore rules). The signup screen only exposes
/// [donor] and [recipient].
enum UserRole {
  donor('donor'),
  recipient('recipient'),
  audiologist('audiologist'),
  admin('admin'),
  anonymous('anonymous');

  const UserRole(this.wire);

  /// On-the-wire string stored in Firestore.
  final String wire;

  static UserRole fromWire(String? s) => switch (s) {
        'recipient' => recipient,
        'audiologist' => audiologist,
        'admin' => admin,
        'donor' => donor,
        _ => anonymous,
      };
}

/// Profile document at `users/{uid}` — created on signup, mirrors the
/// Firebase Auth uid for joins.
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.email,
    required this.displayName,
    required this.role,
    this.createdAt,
  });

  final String uid;
  final String email;
  final String displayName;
  final UserRole role;
  final DateTime? createdAt;

  factory UserProfile.fromFirestore(
    DocumentSnapshot<Map<String, dynamic>> snap,
  ) {
    final d = snap.data() ?? const <String, dynamic>{};
    final ts = d['createdAt'];
    return UserProfile(
      uid: snap.id,
      email: (d['email'] as String?) ?? '',
      displayName: (d['displayName'] as String?) ?? '',
      role: UserRole.fromWire(d['role'] as String?),
      createdAt: ts is Timestamp ? ts.toDate() : null,
    );
  }

  /// Serialize for a fresh signup write. Only callable for self (rules pin
  /// `uid == auth.uid`); role escalation requires audiologist/admin write.
  Map<String, dynamic> toFirestoreNew() => {
        'email': email,
        'displayName': displayName,
        'role': role.wire,
        'createdAt': FieldValue.serverTimestamp(),
      };
}
