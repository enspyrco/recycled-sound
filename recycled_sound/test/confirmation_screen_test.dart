import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

    // The Unknown (help) button inside the MODEL row.
    final modelRow =
        find.ancestor(of: find.text('MODEL'), matching: find.byType(Row)).first;
    final modelUnknown = find.descendant(
        of: modelRow, matching: find.byIcon(Icons.help_outline));
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
}
