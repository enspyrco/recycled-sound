import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:recycled_sound/features/capture/providers/capture_seed.dart';
import 'package:recycled_sound/features/devices/data/incoming_device_repository.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';
import 'package:recycled_sound/features/scanner/data/models/scan_result.dart';
import 'package:recycled_sound/features/scanner/presentation/confirmation_screen.dart';
import 'package:recycled_sound/features/scanner/providers/scanner_providers.dart';

void main() {
  // Regression test for the black "4 OF 7" screen (issue #70, second half).
  //
  // _FieldContainer used a stretch-Row directly under a ListView child:
  // unbounded height + CrossAxisAlignment.stretch forces the accent strip to
  // h=Infinity, throwing a layout exception that blanked the ENTIRE field
  // list — the screen rendered as a near-black void with only the header
  // strip visible. IntrinsicHeight bounds the Row; this test pins that.
  //
  // The screen itself is coverage:ignore-file (Firestore-bound persist path),
  // but mounting and asserting the field list renders needs no Firebase.
  testWidgets('ConfirmationScreen renders all 7 field rows without '
      'layout exceptions', (tester) async {
    await tester.pumpWidget(const ProviderScope(
      child: MaterialApp(home: ConfirmationScreen()),
    ));
    // Fixed pumps, not pumpAndSettle — the amber "needs attention" pulse
    // animation repeats forever and would never settle.
    await tester.pump(const Duration(milliseconds: 100));

    // No layout exception thrown during mount.
    expect(tester.takeException(), isNull);

    // The header strip and every one of the 7 audiologist fields is visible
    // (scroll the lower ones into view — small test viewport).
    expect(find.textContaining('OF 7'), findsOneWidget);
    for (final label in ['MAKE', 'MODEL', 'STYLE', 'TUBING', 'POWER']) {
      expect(find.text(label), findsOneWidget, reason: '$label row missing');
    }
    for (final label in ['BATTERY', 'COLOUR']) {
      await tester.scrollUntilVisible(find.text(label), 200);
      expect(find.text(label), findsOneWidget, reason: '$label row missing');
    }

    // Teardown: dispose before the binding's pending-timer/ticker check.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  // #94: a Signia whose model isn't legible — the volunteer marks MODEL Unknown
  // rather than guessing. The tap must register as a *deliberate* handoff
  // (human-sourced Unknown), not an AI read failure that shares the string.
  testWidgets('tapping Unknown on MODEL flags a volunteer handoff (#94)',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // A normal AI result with a real model value, so the Unknown valve shows.
    container.read(scanResultProvider.notifier).setResult(
          ScanResult.mock().copyWith(
            model: const SpecField(value: 'More 1', confidence: 90),
          ),
        );

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ConfirmationScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    // The amber "Unknown" pill inside the MODEL row (replaced the old help-icon
    // button — same handoff, now styled like the chip sections).
    final modelRow =
        find.ancestor(of: find.text('MODEL'), matching: find.byType(Row)).first;
    final modelUnknown =
        find.descendant(of: modelRow, matching: find.text(kUnknownValue));
    expect(modelUnknown, findsOneWidget);

    await tester.tap(modelUnknown);
    await tester.pump();

    final result = container.read(scanResultProvider);
    expect(result.model.value, kUnknownValue);
    expect(result.model.source, FieldSource.human,
        reason: 'a tapped Unknown is a human verdict, not an AI default');
    expect(result.model.isVolunteerUnknown, isTrue);
    expect(result.volunteerUnknownFields, contains(ClinicalField.model),
        reason: 'so the created device records needsInputFields:[model]');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });

  // #25 / Option B: the scanner is an identification tool, not a photo-capture
  // flow. Confirming a complete scan ADDS an identity-only device to the
  // register (the 7 confirmed fields + box, NO photos) and returns home — it no
  // longer chains into /capture. Photos are a separate step via the home
  // "Capture photos for later" button.
  testWidgets('Add to Register creates an identity-only device (no photos) and '
      'routes home', (tester) async {
    final repo = _RecordingRepo();
    final container = ProviderContainer(overrides: [
      incomingDeviceRepositoryProvider.overrideWithValue(repo),
      scanBoxProvider.overrideWith((ref) => 'B07'),
    ]);
    addTearDown(container.dispose);
    // A fully-resolved 7-field result so the "Add to Register" button enables
    // (isComplete) and every clinical value parses to a real enum.
    container.read(scanResultProvider.notifier).setResult(
          ScanResult.mock().copyWith(
            brand: const SpecField(value: 'Oticon', confidence: 95),
            model: const SpecField(value: 'More 1', confidence: 92),
            type: const SpecField(value: 'BTE', confidence: 90),
            tubing: const SpecField(value: 'Slim', confidence: 88),
            powerSource: const SpecField(value: 'Battery', confidence: 88),
            batterySize: const SpecField(value: '312', confidence: 88),
            colour: const SpecField(value: 'Black', confidence: 88),
          ),
        );

    final router = GoRouter(
      initialLocation: '/scan/confirm',
      routes: [
        GoRoute(
          path: '/scan/confirm',
          builder: (_, _) => const ConfirmationScreen(),
        ),
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: Text('HOME')),
        ),
      ],
    );

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Add to Register'));
    await tester.pump(); // run the async persist
    await tester.pump(const Duration(milliseconds: 600)); // route transition

    expect(repo.createCalls, 1, reason: 'confirming persists exactly one device');
    final draft = repo.lastDraft!;
    expect(draft.brand, 'Oticon');
    expect(draft.model, 'More 1');
    expect(draft.type, Style.bte);
    expect(draft.tubing, Tubing.slim);
    expect(draft.powerSource, PowerSource.battery);
    expect(draft.batterySize, BatterySize.size312);
    expect(draft.colour, 'Black');
    expect(draft.location, 'B07',
        reason: 'the box-first box number lands as the device location');
    expect(draft.needsInputFields, isEmpty,
        reason: 'every field was resolved, so nothing is flagged');
    expect(repo.lastLocalPaths, isEmpty);
    expect(repo.lastNamedPaths, isEmpty,
        reason: 'identity-only: the scan path uploads NO photos');
    expect(find.text('HOME'), findsOneWidget,
        reason: 'after adding to the register the scanner returns home, '
            'NOT into the capture flow');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}

/// Records what [createIncoming] was called with instead of touching Firebase.
/// Subclasses the real repo only to satisfy the provider's type — the mock
/// Firebase handles passed to `super` are never used (createIncoming is fully
/// overridden).
class _RecordingRepo extends IncomingDeviceRepository {
  _RecordingRepo()
      : super(
          firestore: FakeFirebaseFirestore(),
          storage: MockFirebaseStorage(),
          auth: MockFirebaseAuth(
            signedIn: true,
            mockUser: MockUser(uid: 'u-1'),
          ),
        );

  int createCalls = 0;
  DraftDevice? lastDraft;
  List<String>? lastLocalPaths;
  Map<String, String>? lastNamedPaths;

  @override
  Future<String> createIncoming(
    DraftDevice draft, {
    List<String> localPhotoPaths = const [],
    Map<String, String> namedPhotoPaths = const {},
    void Function(String key, int bytesTransferred, int totalBytes)? onProgress,
  }) async {
    createCalls++;
    lastDraft = draft;
    lastLocalPaths = localPhotoPaths;
    lastNamedPaths = namedPhotoPaths;
    return 'dev-1';
  }
}
