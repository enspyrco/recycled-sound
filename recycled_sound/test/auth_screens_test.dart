import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recycled_sound/core/widgets/rs_button.dart';
import 'package:recycled_sound/features/auth/data/auth_service.dart';
import 'package:recycled_sound/features/auth/data/models/user_profile.dart';
import 'package:recycled_sound/features/auth/data/user_profile_repository.dart';
import 'package:recycled_sound/features/auth/presentation/login_screen.dart';
import 'package:recycled_sound/features/auth/presentation/signup_screen.dart';
import 'package:recycled_sound/features/auth/providers/auth_providers.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';

/// Test double that lets each test pick the AuthOutcome the screen will
/// receive when the user taps Sign In / Create Account. The real Firebase
/// SDK doesn't get touched.
class _StubAuthService implements AuthService {
  _StubAuthService({this.signInOutcome, this.signUpOutcome});

  final AuthOutcome? signInOutcome;
  final AuthOutcome? signUpOutcome;
  String? lastEmail;
  String? lastPassword;

  @override
  User? get currentUser => null;

  @override
  Stream<User?> authStateChanges() => const Stream.empty();

  @override
  Future<AuthOutcome> signInWithEmail({
    required String email,
    required String password,
  }) async {
    lastEmail = email;
    lastPassword = password;
    return signInOutcome ??
        AuthSuccess(MockUser(uid: 'u', email: email).toUser());
  }

  @override
  Future<AuthOutcome> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    lastEmail = email;
    lastPassword = password;
    return signUpOutcome ??
        AuthSuccess(MockUser(uid: 'u', email: email).toUser());
  }

  @override
  Future<void> signOut() async {}
}

extension on MockUser {
  User toUser() => this;
}

GoRouter _router(Widget root) => GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => root),
      GoRoute(path: '/signup', builder: (_, _) => const SignupScreen()),
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
    ]);

Widget _wrap(Widget root, {required AuthService stub}) {
  return ProviderScope(
    overrides: [
      authServiceProvider.overrideWithValue(stub),
      // SignupScreen.success path writes users/{uid} via the repository.
      // Override with a fake-firestore-backed repo so tests don't touch
      // FirebaseFirestore.instance.
      userProfileRepositoryProvider.overrideWithValue(
        UserProfileRepository(firestore: FakeFirebaseFirestore()),
      ),
    ],
    child: MaterialApp.router(routerConfig: _router(root)),
  );
}

void main() {
  testWidgets('LoginScreen renders welcome copy + inputs', (tester) async {
    await tester.pumpWidget(_wrap(const LoginScreen(),
        stub: _StubAuthService()));
    await tester.pumpAndSettle();

    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
  });

  testWidgets('LoginScreen successful sign-in calls AuthService', (tester) async {
    final stub = _StubAuthService();
    await tester.pumpWidget(_wrap(const LoginScreen(), stub: stub));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'you@example.com'), 'a@b.com');
    await tester.enterText(
        find.widgetWithText(TextField, 'Enter password'), 'hunter22');
    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle();

    expect(stub.lastEmail, 'a@b.com');
    expect(stub.lastPassword, 'hunter22');
  });

  testWidgets('LoginScreen surfaces wrong-password error', (tester) async {
    final stub = _StubAuthService(
        signInOutcome: const AuthFailure(AuthErrorKind.wrongPassword));
    await tester.pumpWidget(_wrap(const LoginScreen(), stub: stub));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle();

    expect(find.text("Email or password didn't match."), findsOneWidget);
  });

  testWidgets('SignupScreen renders all field labels', (tester) async {
    await tester.pumpWidget(_wrap(const SignupScreen(),
        stub: _StubAuthService()));
    await tester.pumpAndSettle();
    expect(find.text('Create Account'), findsWidgets);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets('SignupScreen role tile selects recipient', (tester) async {
    await tester.pumpWidget(_wrap(const SignupScreen(),
        stub: _StubAuthService()));
    await tester.pumpAndSettle();
    expect(find.text('Recipient'), findsOneWidget);
    await tester.tap(find.text('Recipient'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
  });

  testWidgets('SignupScreen short password trips local validation '
      'before calling auth', (tester) async {
    final stub = _StubAuthService();
    await tester.pumpWidget(_wrap(const SignupScreen(), stub: stub));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Test');
    await tester.enterText(fields.at(1), 'a@b.com');
    await tester.enterText(fields.at(2), 'short');
    await tester.ensureVisible(find.byType(RsButton));
    await tester.pump();
    await tester.tap(find.byType(RsButton));
    await tester.pump();

    // The stub was never reached — local validation rejected the password.
    expect(stub.lastEmail, isNull);
  });

  testWidgets('SignupScreen success path delegates to AuthService',
      (tester) async {
    final stub = _StubAuthService(
        signUpOutcome: const AuthFailure(AuthErrorKind.emailAlreadyInUse));
    await tester.pumpWidget(_wrap(const SignupScreen(), stub: stub));
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Test');
    await tester.enterText(fields.at(1), 'a@b.com');
    await tester.enterText(fields.at(2), 'longenough');
    await tester.ensureVisible(find.byType(RsButton));
    await tester.pump();
    await tester.tap(find.byType(RsButton));
    await tester.pumpAndSettle();

    // Stub WAS called — auth path was reached.
    expect(stub.lastEmail, 'a@b.com');
    expect(stub.lastPassword, 'longenough');
  });
}
