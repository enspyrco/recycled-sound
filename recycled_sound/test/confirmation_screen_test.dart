import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recycled_sound/features/scanner/presentation/confirmation_screen.dart';

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
}
