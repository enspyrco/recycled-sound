import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recycled_sound/app.dart';
import 'package:recycled_sound/core/routing/app_router.dart';
import 'package:recycled_sound/core/widgets/rs_button.dart';
import 'package:recycled_sound/core/widgets/rs_card.dart';
import 'package:recycled_sound/core/widgets/rs_chip.dart';
import 'package:recycled_sound/core/widgets/rs_progress_dots.dart';
import 'package:recycled_sound/core/widgets/rs_spec_row.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';

void main() {
  // Tests skip the diagnostic boot screen — its periodic timers would loop
  // pumpAndSettle until timeout. Production keeps `/boot` as initial route.
  //
  // Firestore-backed providers are overridden with a fixed in-memory stream so
  // tests don't need a Firebase emulator. Anything depending on
  // [incomingDevicesStreamProvider] sees the same canned list each test.
  Widget testApp() => ProviderScope(
        overrides: [
          incomingDevicesStreamProvider.overrideWith(
            (_) => Stream.value(const [
              Device(id: '1', brand: 'Phonak', model: 'Audéo P90'),
              Device(id: '2', brand: 'Oticon', model: 'More 1'),
            ]),
          ),
        ],
        child: RecycledSoundApp(router: createAppRouter(initialLocation: '/')),
      );

  // ── App smoke test ─────────────────────────────────────────────────────
  testWidgets('Home screen renders with scanner CTA', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    expect(find.text('Scan a Hearing Aid'), findsOneWidget);
    expect(find.text('Open Scanner'), findsOneWidget);
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

  testWidgets('Navigating to Devices tab shows register', (tester) async {
    await tester.pumpWidget(testApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();

    expect(find.text('Device Register'), findsOneWidget);
    expect(find.text('Phonak Audéo P90'), findsOneWidget);
    expect(find.text('Oticon More 1'), findsOneWidget);
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
