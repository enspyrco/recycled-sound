import 'package:firebase_auth/firebase_auth.dart';

/// Outcome of an auth-mutation call.
///
/// Sealed type so callers must handle every variant — a typo'd `String` error
/// code can't silently slip past the chip-variant switch the way it would
/// with a `try { … } catch (e)` that lumps every FirebaseAuthException into
/// a single "save failed" string.
sealed class AuthOutcome {
  const AuthOutcome();
}

final class AuthSuccess extends AuthOutcome {
  const AuthSuccess(this.user);
  final User user;
}

/// Known FirebaseAuth error states the UI should distinguish.
enum AuthErrorKind {
  invalidEmail,
  userNotFound,
  wrongPassword,
  weakPassword,
  emailAlreadyInUse,
  networkRequestFailed,
  tooManyRequests,
  operationNotAllowed,
  unknown;

  /// Parse the `code` field of a [FirebaseAuthException] into a typed kind.
  static AuthErrorKind fromCode(String code) => switch (code) {
        'invalid-email' => invalidEmail,
        'user-not-found' => userNotFound,
        'wrong-password' || 'invalid-credential' => wrongPassword,
        'weak-password' => weakPassword,
        'email-already-in-use' => emailAlreadyInUse,
        'network-request-failed' => networkRequestFailed,
        'too-many-requests' => tooManyRequests,
        'operation-not-allowed' => operationNotAllowed,
        _ => unknown,
      };

  /// Human-readable copy. Kept short — these surface in snackbars.
  String get userMessage => switch (this) {
        invalidEmail => "That email doesn't look right.",
        userNotFound => 'No account with that email.',
        wrongPassword => "Email or password didn't match.",
        weakPassword => 'Password is too weak. Use 8+ characters.',
        emailAlreadyInUse => 'An account with that email already exists.',
        networkRequestFailed => 'Offline. Reconnect and try again.',
        tooManyRequests => 'Too many attempts. Wait a minute, then retry.',
        operationNotAllowed => 'Email/password sign-in is disabled.',
        unknown => 'Something went wrong. Try again.',
      };
}

final class AuthFailure extends AuthOutcome {
  const AuthFailure(this.kind);
  final AuthErrorKind kind;
}

/// Wraps the auth side-effects so screens and tests work against a single
/// surface instead of poking FirebaseAuth.instance directly. The
/// anonymous-upgrade pattern preserves the in-flight anonymous uid so any
/// `incoming/` docs the user created while anonymous stay attached after
/// they sign up.
class AuthService {
  AuthService({required FirebaseAuth auth}) : _auth = auth;

  final FirebaseAuth _auth;

  /// Current Firebase user (may be anonymous, signed-in, or null).
  User? get currentUser => _auth.currentUser;

  /// Live stream of the auth state — emits on sign-in / sign-out /
  /// anonymous-upgrade.
  Stream<User?> authStateChanges() => _auth.authStateChanges();

  Future<AuthOutcome> signInWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      final cred = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      return AuthSuccess(cred.user!);
    } on FirebaseAuthException catch (e) {
      return AuthFailure(AuthErrorKind.fromCode(e.code));
    }
  }

  /// Create an account. If the caller is already signed in anonymously,
  /// the anonymous user is upgraded to email/password via
  /// [User.linkWithCredential] so the uid (and therefore any `incoming/`
  /// docs they already wrote) is preserved.
  Future<AuthOutcome> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    final trimmedEmail = email.trim();
    try {
      final existing = _auth.currentUser;
      if (existing != null && existing.isAnonymous) {
        final cred = EmailAuthProvider.credential(
          email: trimmedEmail,
          password: password,
        );
        final upgraded = await existing.linkWithCredential(cred);
        return AuthSuccess(upgraded.user!);
      }
      final cred = await _auth.createUserWithEmailAndPassword(
        email: trimmedEmail,
        password: password,
      );
      return AuthSuccess(cred.user!);
    } on FirebaseAuthException catch (e) {
      return AuthFailure(AuthErrorKind.fromCode(e.code));
    }
  }

  Future<void> signOut() => _auth.signOut();
}
