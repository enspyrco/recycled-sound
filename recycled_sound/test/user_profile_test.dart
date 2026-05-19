import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/auth/data/auth_service.dart';
import 'package:recycled_sound/features/auth/data/models/user_profile.dart';
import 'package:recycled_sound/features/auth/data/user_profile_repository.dart';

void main() {
  group('UserRole.fromWire', () {
    test('maps known wire values', () {
      expect(UserRole.fromWire('donor'), UserRole.donor);
      expect(UserRole.fromWire('recipient'), UserRole.recipient);
      expect(UserRole.fromWire('audiologist'), UserRole.audiologist);
      expect(UserRole.fromWire('admin'), UserRole.admin);
    });

    test('defaults unknown / null to anonymous', () {
      expect(UserRole.fromWire(null), UserRole.anonymous);
      expect(UserRole.fromWire(''), UserRole.anonymous);
      expect(UserRole.fromWire('superuser'), UserRole.anonymous);
    });
  });

  group('UserProfile.fromFirestore', () {
    late FakeFirebaseFirestore firestore;

    setUp(() {
      firestore = FakeFirebaseFirestore();
    });

    test('parses populated profile with all fields', () async {
      await firestore.collection('users').doc('u1').set({
        'email': 'a@b.com',
        'displayName': 'Alice',
        'role': 'recipient',
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 1, 1)),
      });
      final snap = await firestore.collection('users').doc('u1').get();
      final p = UserProfile.fromFirestore(snap);
      expect(p.uid, 'u1');
      expect(p.email, 'a@b.com');
      expect(p.displayName, 'Alice');
      expect(p.role, UserRole.recipient);
      expect(p.createdAt!.toUtc(), DateTime.utc(2026, 1, 1));
    });

    test('empty doc falls back to anonymous role + empty strings', () async {
      await firestore.collection('users').doc('u2').set({});
      final snap = await firestore.collection('users').doc('u2').get();
      final p = UserProfile.fromFirestore(snap);
      expect(p.email, '');
      expect(p.displayName, '');
      expect(p.role, UserRole.anonymous);
      expect(p.createdAt, isNull);
    });
  });

  group('UserProfileRepository', () {
    late FakeFirebaseFirestore firestore;
    late UserProfileRepository repo;

    setUp(() {
      firestore = FakeFirebaseFirestore();
      repo = UserProfileRepository(firestore: firestore);
    });

    test('createOnSignup writes the doc keyed by uid', () async {
      const profile = UserProfile(
        uid: 'u-new',
        email: 'n@e.com',
        displayName: 'New',
        role: UserRole.donor,
      );
      await repo.createOnSignup(profile);
      final snap = await firestore.collection('users').doc('u-new').get();
      expect(snap.exists, isTrue);
      expect(snap.data()!['role'], 'donor');
      expect(snap.data()!['email'], 'n@e.com');
      expect(snap.data()!['displayName'], 'New');
    });

    test('watchById emits null for missing doc', () async {
      final p = await repo.watchById('does-not-exist').first;
      expect(p, isNull);
    });

    test('watchById emits the profile when present', () async {
      await firestore.collection('users').doc('u3').set({
        'email': 'c@d.com',
        'displayName': 'Carol',
        'role': 'donor',
      });
      final p = await repo.watchById('u3').first;
      expect(p, isNotNull);
      expect(p!.email, 'c@d.com');
      expect(p.role, UserRole.donor);
    });
  });

  group('AuthErrorKind', () {
    test('maps Firebase codes to typed kinds', () {
      expect(AuthErrorKind.fromCode('invalid-email'),
          AuthErrorKind.invalidEmail);
      expect(AuthErrorKind.fromCode('user-not-found'),
          AuthErrorKind.userNotFound);
      expect(AuthErrorKind.fromCode('wrong-password'),
          AuthErrorKind.wrongPassword);
      expect(AuthErrorKind.fromCode('invalid-credential'),
          AuthErrorKind.wrongPassword);
      expect(AuthErrorKind.fromCode('weak-password'),
          AuthErrorKind.weakPassword);
      expect(AuthErrorKind.fromCode('email-already-in-use'),
          AuthErrorKind.emailAlreadyInUse);
      expect(AuthErrorKind.fromCode('network-request-failed'),
          AuthErrorKind.networkRequestFailed);
      expect(AuthErrorKind.fromCode('too-many-requests'),
          AuthErrorKind.tooManyRequests);
      expect(AuthErrorKind.fromCode('operation-not-allowed'),
          AuthErrorKind.operationNotAllowed);
      expect(AuthErrorKind.fromCode('whatever'), AuthErrorKind.unknown);
    });

    test('every kind has a non-empty user message', () {
      for (final k in AuthErrorKind.values) {
        expect(k.userMessage, isNotEmpty,
            reason: '$k must have a user-facing message');
      }
    });
  });

  group('AuthOutcome sealed type', () {
    test('AuthSuccess carries the user', () {
      final user = _FakeUser(uid: 'u');
      final outcome = AuthSuccess(user);
      expect(outcome.user.uid, 'u');
    });

    test('AuthFailure carries the kind', () {
      const outcome = AuthFailure(AuthErrorKind.weakPassword);
      expect(outcome.kind, AuthErrorKind.weakPassword);
    });
  });
}

/// Minimal stand-in for FirebaseAuth's [User] — only need uid for the test.
class _FakeUser implements User {
  _FakeUser({required this.uid});

  @override
  final String uid;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
