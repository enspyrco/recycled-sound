import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/firebase_providers.dart';
import '../data/auth_service.dart';
import '../data/models/user_profile.dart';
import '../data/user_profile_repository.dart';

final authServiceProvider = Provider<AuthService>((ref) {
  return AuthService(auth: ref.watch(firebaseAuthProvider));
});

final userProfileRepositoryProvider = Provider<UserProfileRepository>((ref) {
  return UserProfileRepository(firestore: ref.watch(firestoreProvider));
});

/// Live stream of the Firebase Auth user. Emits null when signed out,
/// an anonymous user when bootstrapped without sign-in, and the upgraded
/// user after sign-up/sign-in.
final authStateProvider = StreamProvider<User?>((ref) {
  return ref.watch(authServiceProvider).authStateChanges();
});

/// Stream of the currently signed-in user's profile document. Emits null
/// when no user (or an anonymous user with no profile doc).
final currentUserProfileProvider = StreamProvider<UserProfile?>((ref) {
  final user = ref.watch(authStateProvider).valueOrNull;
  if (user == null || user.isAnonymous) {
    return Stream<UserProfile?>.value(null);
  }
  return ref.watch(userProfileRepositoryProvider).watchById(user.uid);
});
