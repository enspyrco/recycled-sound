import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recycled_sound/features/capture/presentation/upload_progress_screen.dart';
import 'package:recycled_sound/features/capture/providers/upload_job.dart';

import 'support/google_fonts_test_asset.dart';

/// A controller pre-seeded with a fixed [UploadJob] so a widget test can render
/// any phase of the progress screen without driving a real upload.
class _SeededController extends UploadJobController {
  _SeededController(super.ref, UploadJob? initial) {
    state = initial;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The screen paints AppTypography (GoogleFonts.inter()); feed it a bundled
  // font so it doesn't try a live fetch offline. If the SDK font is missing the
  // text-rendering tests skip rather than fail.
  final fontReady = installGoogleFontsAssetMock();

  /// Pump the progress screen behind a minimal router that also has a `/scan`
  /// target, so the success/no-job navigations have somewhere to land.
  Future<GoRouter> pump(WidgetTester tester, UploadJob? job) async {
    final router = GoRouter(
      initialLocation: '/capture/uploading',
      routes: [
        GoRoute(
          path: '/capture/uploading',
          builder: (_, _) => const UploadProgressScreen(),
        ),
        GoRoute(
          path: '/scan',
          builder: (_, _) =>
              const Scaffold(body: Center(child: Text('SCAN SCREEN'))),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uploadJobProvider
              .overrideWith((ref) => _SeededController(ref, job)),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    return router;
  }

  UploadJob jobWith({
    required UploadPhase phase,
    String box = 'B07',
    String? errorMessage,
  }) =>
      UploadJob(
        phase: phase,
        box: box,
        errorMessage: errorMessage,
        photos: const [
          PhotoProgress(key: 'left_medial', transferred: 100, total: 100, done: true),
          PhotoProgress(key: 'right_scale', transferred: 0, total: 100),
          // A positional key exercises the _labelFor fallback.
          PhotoProgress(key: '0'),
        ],
      );

  testWidgets('uploading phase shows the box, the N-of-total counter and a '
      'keep-open hint', (tester) async {
    await pump(tester, jobWith(phase: UploadPhase.uploading));
    await tester.pump();

    expect(find.text('Saving box B07'), findsOneWidget);
    expect(find.text('1 of 3 photos uploaded'), findsOneWidget);
    expect(find.text('Keep the app open — uploading the photos.'),
        findsOneWidget);
    // Named slot keys render as readable labels; a positional key falls back.
    expect(find.text('Photo 0'), findsOneWidget);
  }, skip: !fontReady);

  testWidgets('success phase offers "Scan next device" which navigates to /scan',
      (tester) async {
    await pump(tester, jobWith(phase: UploadPhase.success));
    await tester.pump();

    expect(find.text('Saved box B07'), findsOneWidget);
    final cta = find.text('Scan next device');
    expect(cta, findsOneWidget);

    await tester.tap(cta);
    await tester.pumpAndSettle();
    expect(find.text('SCAN SCREEN'), findsOneWidget,
        reason: 'continue clears the job and routes to the scanner');
  }, skip: !fontReady);

  testWidgets('error phase shows the message and a working Try again button',
      (tester) async {
    await pump(
      tester,
      jobWith(phase: UploadPhase.error, errorMessage: 'No connection.'),
    );
    await tester.pump();

    expect(find.text('Upload failed'), findsOneWidget);
    expect(find.text('No connection.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    // Tapping retry must not throw (the seeded controller's retry is a no-op
    // since nothing was started through it).
    await tester.tap(find.text('Try again'));
    await tester.pump();
  }, skip: !fontReady);

  testWidgets('no job (deep link / hot restart) redirects to /scan rather than '
      'stranding a blank screen', (tester) async {
    await pump(tester, null);
    // The redirect is scheduled for after this frame; let it run.
    await tester.pumpAndSettle();
    expect(find.text('SCAN SCREEN'), findsOneWidget);
  });
}
