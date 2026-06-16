import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recycled_sound/core/providers/firebase_providers.dart';
import 'package:recycled_sound/features/admin/presentation/admin_shell.dart';
import 'package:recycled_sound/features/admin/presentation/device_register_screen.dart';
import 'package:recycled_sound/features/admin/presentation/incoming_queue_screen.dart';
import 'package:recycled_sound/features/admin/presentation/placeholder_admin_screen.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';

GoRouter _stubRouter(Widget root) => GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => root),
        GoRoute(
            path: '/incoming',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('incoming-stub')))),
        GoRoute(
            path: '/devices',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('devices-stub')))),
        GoRoute(
            path: '/matching',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('matching-stub')))),
        GoRoute(
            path: '/users',
            builder: (_, _) =>
                const Scaffold(body: Center(child: Text('users-stub')))),
      ],
    );

Widget _wrap(Widget root, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      routerConfig: _stubRouter(root),
    ),
  );
}

void main() {
  group('AdminShell', () {
    testWidgets('renders title + sidebar entries', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpWidget(_wrap(const PlaceholderAdminScreen(
        section: AdminSection.incoming,
        title: 'Test title',
        tagline: 'tagline',
      )));
      await tester.pumpAndSettle();

      expect(find.text('Recycled Sound'), findsOneWidget);
      expect(find.text('Test title'), findsOneWidget);
      expect(find.text('Incoming'), findsOneWidget);
      expect(find.text('Devices'), findsOneWidget);
      expect(find.text('Matching'), findsOneWidget);
      expect(find.text('Users'), findsOneWidget);
    });

    testWidgets('sidebar tap navigates', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpWidget(_wrap(const PlaceholderAdminScreen(
        section: AdminSection.incoming,
        title: 'X',
        tagline: 't',
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Matching'));
      await tester.pumpAndSettle();
      expect(find.text('matching-stub'), findsOneWidget);
    });
  });

  group('IncomingQueueScreen', () {
    testWidgets('empty state when no incoming docs', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpWidget(_wrap(
        const IncomingQueueScreen(),
        overrides: [
          allIncomingDevicesProvider.overrideWith(
            (_) => Stream.value(const <Device>[]),
          ),
        ],
      ));
      await tester.pumpAndSettle();
      expect(find.text('Queue is empty'), findsOneWidget);
    });

    testWidgets('renders rows + Approve button', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpWidget(_wrap(
        const IncomingQueueScreen(),
        overrides: [
          allIncomingDevicesProvider.overrideWith(
            (_) => Stream.value(const [
              Device(id: 'd1', brand: 'Phonak', model: 'P90', type: 'RIC'),
            ]),
          ),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Phonak P90'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('1 awaiting review'), findsOneWidget);
    });

    testWidgets(
        'flagged row hides quick-Approve (forces review), unflagged keeps it',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpWidget(_wrap(
        const IncomingQueueScreen(),
        overrides: [
          allIncomingDevicesProvider.overrideWith(
            (_) => Stream.value(const [
              // Flagged → Approve suppressed, only a Review affordance.
              Device(
                id: 'flagged',
                brand: 'Oticon',
                model: 'More 1',
                type: 'BTE',
                needsInputFields: [ClinicalField.tubing],
              ),
              // Clean → quick-Approve still offered.
              Device(id: 'clean', brand: 'Phonak', model: 'P90', type: 'RIC'),
            ]),
          ),
        ],
      ));
      await tester.pumpAndSettle();

      // Exactly one Approve (the clean row) and one Review (the flagged row).
      expect(find.text('Approve'), findsOneWidget);
      expect(find.text('Review'), findsOneWidget);
      // The flagged row carries the NEEDS INPUT chip.
      expect(find.text('NEEDS INPUT 1'), findsOneWidget);
    });

    testWidgets('permission-denied error gets a friendly message',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpWidget(_wrap(
        const IncomingQueueScreen(),
        overrides: [
          allIncomingDevicesProvider.overrideWith(
            (_) => Stream.error(Exception(
                '[cloud_firestore/permission-denied] Missing or insufficient permissions.')),
          ),
        ],
      ));
      await tester.pumpAndSettle();
      expect(
        find.text('You need an audiologist or admin role to view the queue.'),
        findsOneWidget,
      );
    });

    testWidgets('Approve button calls promoteToDevice', (tester) async {
      // Use a real fake-firestore so the repo can perform the batch write
      // and we can assert against the resulting state.
      final firestore = FakeFirebaseFirestore();
      final storage = MockFirebaseStorage();
      final auth = MockFirebaseAuth(
        signedIn: true,
        mockUser: MockUser(uid: 'admin', email: 'a@b.com'),
      );
      await firestore.collection('incoming').doc('to-promote').set({
        'brand': 'Oticon',
        'model': 'More 1',
        'createdBy': 'someone',
        'qaStatus': 'pending_qa',
        'createdAt': DateTime.utc(2026, 1, 1),
      });

      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpWidget(_wrap(
        const IncomingQueueScreen(),
        overrides: [
          firestoreProvider.overrideWithValue(firestore),
          firebaseStorageProvider.overrideWithValue(storage),
          firebaseAuthProvider.overrideWithValue(auth),
        ],
      ));
      await tester.pumpAndSettle();

      expect(find.text('Oticon More 1'), findsOneWidget);
      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();

      // Source deleted, destination written
      final src =
          await firestore.collection('incoming').doc('to-promote').get();
      expect(src.exists, isFalse);
      final dst =
          await firestore.collection('devices').doc('to-promote').get();
      expect(dst.exists, isTrue);
      expect(dst.data()!['qaStatus'], 'passed');
    });
  });

  group('DeviceRegisterScreen', () {
    testWidgets('empty state nudges to triage', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpWidget(_wrap(
        const DeviceRegisterScreen(),
        overrides: [
          allDevicesProvider.overrideWith(
            (_) => Stream.value(const <Device>[]),
          ),
        ],
      ));
      await tester.pumpAndSettle();
      expect(find.text('No devices yet'), findsOneWidget);
      expect(
        find.textContaining('Promote a device from the Incoming queue'),
        findsOneWidget,
      );
    });

    testWidgets('renders curated rows with passed badge', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpWidget(_wrap(
        const DeviceRegisterScreen(),
        overrides: [
          allDevicesProvider.overrideWith(
            (_) => Stream.value(const [
              Device(
                id: 'd1',
                brand: 'Phonak',
                model: 'P90',
                type: 'RIC',
                batterySize: '312',
                qaStatus: QaStatus.passed,
                status: DeviceStatus.ready,
              ),
            ]),
          ),
        ],
      ));
      await tester.pumpAndSettle();
      expect(find.text('Phonak P90'), findsOneWidget);
      expect(find.text('PASSED'), findsOneWidget);
      expect(find.text('1 in register'), findsOneWidget);
    });
  });
}
