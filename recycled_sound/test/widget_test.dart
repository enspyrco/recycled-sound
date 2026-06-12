import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recycled_sound/app.dart';
import 'package:recycled_sound/core/providers/device_telemetry_provider.dart';
import 'package:recycled_sound/core/routing/app_router.dart';
import 'package:recycled_sound/core/services/device_telemetry.dart';
import 'package:recycled_sound/core/widgets/rs_button.dart';
import 'package:recycled_sound/core/widgets/rs_card.dart';
import 'package:recycled_sound/core/widgets/rs_chip.dart';
import 'package:recycled_sound/core/widgets/rs_progress_dots.dart';
import 'package:recycled_sound/core/widgets/rs_spec_row.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';
import 'package:recycled_sound/features/scanner/presentation/confirmation_screen.dart';
import 'package:recycled_sound/features/scanner/presentation/live_scanner_screen.dart';

void main() {
  // Tests skip the diagnostic boot screen — its periodic timers would loop
  // pumpAndSettle until timeout. Production keeps `/boot` as initial route.
  //
  // Firestore-backed providers are overridden with a fixed in-memory stream so
  // tests don't need a Firebase emulator. Anything depending on
  // [incomingDevicesStreamProvider] sees the same canned list each test.
  Widget testApp() => ProviderScope(
        overrides: [
          // The volunteer's own captures (watchMyIncoming) — surface in the
          // "Pending intake" section of the Devices tab.
          incomingDevicesStreamProvider.overrideWith(
            (_) => Stream.value(const [
              Device(id: '1', brand: 'Phonak', model: 'Audéo P90'),
              Device(id: '2', brand: 'Oticon', model: 'More 1'),
            ]),
          ),
          // The curated register — empty here so the section renders its
          // empty-state guidance instead of reaching for a real Firebase stream.
          allDevicesProvider.overrideWith((_) => Stream.value(const [])),
          // Device Info reads telemetry through the shared service provider.
          // In the test harness the real service's native plugins (battery,
          // connectivity, device_info) don't settle, so inject a fake that
          // returns instantly — keeps pumpAndSettle from timing out.
          deviceTelemetryServiceProvider
              .overrideWithValue(_FakeTelemetryService()),
        ],
        child: RecycledSoundApp(router: createAppRouter(initialLocation: '/')),
      );

  // ── App smoke test ─────────────────────────────────────────────────────
  testWidgets('Home screen renders with scanner CTA', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    expect(find.text('Add a Hearing Aid'), findsOneWidget);
    expect(find.text('Scan to identify'), findsOneWidget);
    expect(find.text('Capture photos for later'), findsOneWidget);
    expect(find.text('Impact'), findsOneWidget);
    expect(find.text('Quick Actions'), findsOneWidget);
  });

  testWidgets('Home screen shows stats cards', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    expect(find.text('20'), findsOneWidget);
    expect(find.text('Devices collected'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.text('Brands on register'), findsOneWidget);
  });

  testWidgets('Bottom nav bar shows Home and Devices tabs', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Devices'), findsOneWidget);
  });

  testWidgets('Navigating to Devices tab shows the volunteer\'s captures '
      'under Pending intake', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();

    // Both registers are labelled so a volunteer can find their scan.
    expect(find.text('Pending intake'), findsOneWidget);
    expect(find.text('Device register'), findsOneWidget);

    // Their just-captured devices land in the pending section, flagged for
    // review — not silently filed into the curated register.
    expect(find.text('Phonak Audéo P90'), findsOneWidget);
    expect(find.text('Oticon More 1'), findsOneWidget);
    expect(find.text('PENDING REVIEW'), findsNWidgets(2));
  });

  testWidgets('Settings keeps the bottom nav shell (gear → Settings → Device Info)',
      (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    // Tap the gear in the Home AppBar.
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    // Settings renders AND the bottom NavigationBar is still on screen —
    // proving the route resolves inside the ShellRoute, not full-screen.
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Device Info'), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsOneWidget);

    // Drill into Device Info — the bar must persist here too.
    await tester.tap(find.text('Device Info'));
    await tester.pumpAndSettle();

    expect(find.byType(BottomNavigationBar), findsOneWidget);
  });

  // ── Scanner navigation (issues #38/#49/#70 family) ─────────────────────
  // These cover home_screen's nav lines so the diff-cover gate measures
  // them, and pin the go()-everywhere convention for camera routes.
  // NOTE: no pumpAndSettle after these taps — LiveScanScreen runs
  // boot-sequence timers and ConfirmationScreen has an infinite pulse
  // animation, so settle would time out. Fixed pumps instead.
  testWidgets('Scan to identify navigates to the live scanner',
      (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Scan to identify'));
    await tester.pump(); // start navigation
    await tester.pump(const Duration(milliseconds: 600)); // route transition

    expect(find.byType(LiveScanScreen), findsOneWidget);

    // Teardown: the scanner's 5s auto-capture fallback timer is anonymous
    // (not cancelled in dispose). Dispose the tree first so its `mounted`
    // guard no-ops, then advance fake time so the timer fires and clears —
    // otherwise the binding fails the test on a pending timer.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 16));
  });

  testWidgets('7-Field Confirmation tile opens the confirmation screen',
      (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    // Tile sits below the fold in the test viewport.
    await tester.scrollUntilVisible(find.text('7-Field Confirmation'), 200);
    await tester.tap(find.text('7-Field Confirmation'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(ConfirmationScreen), findsOneWidget);

    // Teardown: dispose the tree to stop the screen's repeating pulse
    // animation before the binding's end-of-test invariant check.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 16));
  });

  // ── RsButton ───────────────────────────────────────────────────────────
  group('RsButton', () {
    testWidgets('primary variant renders ElevatedButton', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RsButton(label: 'Test', onPressed: () {}),
        ),
      ));
      expect(find.byType(ElevatedButton), findsOneWidget);
      expect(find.text('Test'), findsOneWidget);
    });

    testWidgets('outline variant renders OutlinedButton', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RsButton(
            label: 'Outline',
            variant: RsButtonVariant.outline,
            onPressed: () {},
          ),
        ),
      ));
      expect(find.byType(OutlinedButton), findsOneWidget);
    });

    testWidgets('ghost variant renders TextButton', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RsButton(
            label: 'Ghost',
            variant: RsButtonVariant.ghost,
            onPressed: () {},
          ),
        ),
      ));
      expect(find.byType(TextButton), findsOneWidget);
    });

    testWidgets('loading state shows spinner', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RsButton(label: 'Load', onPressed: () {}, isLoading: true),
        ),
      ));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('icon variant shows icon and label', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RsButton(
            label: 'With Icon',
            icon: Icons.add,
            onPressed: () {},
          ),
        ),
      ));
      expect(find.byIcon(Icons.add), findsOneWidget);
      expect(find.text('With Icon'), findsOneWidget);
    });
  });

  // ── RsChip ─────────────────────────────────────────────────────────────
  group('RsChip', () {
    testWidgets('renders label text', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: RsChip(label: 'Active')),
      ));
      expect(find.text('Active'), findsOneWidget);
    });

    testWidgets('renders all variants without error', (tester) async {
      for (final variant in RsChipVariant.values) {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: RsChip(label: variant.name, variant: variant)),
        ));
        expect(find.text(variant.name), findsOneWidget);
      }
    });
  });

  // ── RsCard ─────────────────────────────────────────────────────────────
  testWidgets('RsCard wraps child with padding', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: RsCard(child: Text('Inner'))),
    ));
    expect(find.text('Inner'), findsOneWidget);
    expect(find.byType(Card), findsOneWidget);
  });

  // ── RsProgressDots ─────────────────────────────────────────────────────
  testWidgets('RsProgressDots renders correct number of dots', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: RsProgressDots(total: 4, current: 1)),
    ));
    // 4 Container widgets for dots (inside the Row)
    final containers = find.descendant(
      of: find.byType(RsProgressDots),
      matching: find.byType(Container),
    );
    expect(containers, findsNWidgets(4));
  });

  // ── RsSpecRow ──────────────────────────────────────────────────────────
  group('RsSpecRow', () {
    testWidgets('renders label and value', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: RsSpecRow(label: 'Brand', value: 'Phonak')),
      ));
      expect(find.text('Brand'), findsOneWidget);
      expect(find.text('Phonak'), findsOneWidget);
    });

    testWidgets('shows edit icon when onEdit provided', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: RsSpecRow(label: 'Brand', value: 'Phonak', onEdit: () {}),
        ),
      ));
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    });

    testWidgets('hides edit icon when no onEdit', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: RsSpecRow(label: 'Brand', value: 'Phonak')),
      ));
      expect(find.byIcon(Icons.edit_outlined), findsNothing);
    });

    testWidgets('shows confidence dot when confidence provided', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RsSpecRow(label: 'Brand', value: 'Phonak', confidence: 95),
        ),
      ));
      // Confidence dot is a decorated Container inside the row
      expect(find.text('Phonak'), findsOneWidget);
    });
  });
}

/// Returns a canned telemetry snapshot instantly so router-level tests that
/// land on Device Info settle without touching native plugins.
class _FakeTelemetryService implements DeviceTelemetryService {
  @override
  Future<DeviceTelemetry> snapshot() async => const DeviceTelemetry(
        make: 'Apple',
        modelId: 'iPhone15,2',
        modelName: 'iPhone 14 Pro',
        osName: 'iOS',
        osVersion: '17.4',
        appVersion: '0.5.0',
        buildNumber: '9',
        locale: 'en_AU',
        processorCount: 6,
        physicalMemoryGb: 6.0,
        batteryPercent: 82,
        charging: false,
        lowPowerMode: false,
        networkType: NetworkType.wifi,
        thermalState: ThermalState.nominal,
        thermalLoad: 0.2,
        thermalHeadroom: null,
        hasLidar: true,
        hasNeuralEngine: true,
        socModel: 'A16 Bionic',
      );
}
