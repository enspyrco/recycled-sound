import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/capture/presentation/widgets/sweep_guide.dart';

void main() {
  // Pumps the widget inside a sized MaterialApp so theme + layout resolve.
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('renders the instruction text', (tester) async {
    await tester.pumpWidget(host(const SweepGuide(running: false)));
    expect(find.textContaining('Slowly turn the hearing aid'), findsOneWidget);
  });

  testWidgets('fires onComplete once after a full sweep', (tester) async {
    var completions = 0;
    await tester.pumpWidget(host(SweepGuide(
      sweepDuration: const Duration(seconds: 2),
      onComplete: () => completions++,
    )));
    // Before the sweep finishes, no completion.
    await tester.pump(const Duration(seconds: 1));
    expect(completions, 0);
    // After the full duration, exactly one completion.
    await tester.pump(const Duration(seconds: 2));
    expect(completions, 1);
    // Settle the perpetual spin controller so the test can tear down.
    await tester.pumpWidget(host(const SizedBox()));
  });

  testWidgets('does not advance progress while paused', (tester) async {
    var completions = 0;
    await tester.pumpWidget(host(SweepGuide(
      running: false,
      sweepDuration: const Duration(seconds: 2),
      onComplete: () => completions++,
    )));
    await tester.pump(const Duration(seconds: 5));
    expect(completions, 0);
    await tester.pumpWidget(host(const SizedBox()));
  });

  testWidgets('falls back to a hearing icon when the asset is missing',
      (tester) async {
    await tester.pumpWidget(host(const SweepGuide(
      running: false,
      asset: 'assets/capture_guide/does_not_exist.png',
    )));
    // errorBuilder resolves synchronously for a missing asset bundle entry.
    await tester.pump();
    expect(find.byIcon(Icons.hearing), findsOneWidget);
  });
}
