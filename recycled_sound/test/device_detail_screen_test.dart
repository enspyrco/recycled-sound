import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:firebase_storage_mocks/firebase_storage_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:recycled_sound/features/devices/data/incoming_device_repository.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/presentation/device_detail_screen.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';

Widget _wrap(Widget child, {required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(home: child),
  );
}

/// Repository double that counts `deleteIncoming` calls and lets the test hold
/// the delete in flight (via [gate]) so taps can be issued while the async
/// delete is pending. Extends the real repo — constructed with the standard
/// Firebase mocks — rather than a mockito/mocktail stub, matching the
/// test-double style already used in this package.
class _CountingRepository extends IncomingDeviceRepository {
  _CountingRepository()
      : super(
          firestore: FakeFirebaseFirestore(),
          storage: MockFirebaseStorage(),
          auth: MockFirebaseAuth(),
        );

  int deleteCalls = 0;

  /// Completes the in-flight delete. Tests resolve this when they want the
  /// delete to finish (and the screen to navigate away).
  final gate = Completer<void>();

  @override
  Future<void> deleteIncoming(String id) async {
    deleteCalls++;
    await gate.future;
  }
}

void main() {
  const id = 'abc';

  testWidgets('renders detail view when the stream emits a device',
      (tester) async {
    const device = Device(
      id: id,
      brand: 'Phonak',
      model: 'Audéo P90',
      type: Style.ric,
      year: '2021',
      batterySize: BatterySize.size312,
      qaStatus: QaStatus.passed,
      status: DeviceStatus.ready,
    );

    await tester.pumpWidget(_wrap(
      const DeviceDetailScreen(deviceId: id),
      overrides: [
        incomingDeviceByIdProvider(id)
            .overrideWith((_) => Stream.value(device)),
      ],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Phonak Audéo P90'), findsOneWidget);
    expect(find.text('Identification'), findsOneWidget);
    expect(find.text('Specifications'), findsOneWidget);
    expect(find.text('Status'), findsWidgets);
  });

  testWidgets('shows "Device not found" on null emission', (tester) async {
    await tester.pumpWidget(_wrap(
      const DeviceDetailScreen(deviceId: id),
      overrides: [
        incomingDeviceByIdProvider(id).overrideWith((_) => Stream.value(null)),
      ],
    ));
    await tester.pumpAndSettle();
    expect(find.text('Device not found.'), findsOneWidget);
  });

  testWidgets('shows loading spinner before first emit', (tester) async {
    await tester.pumpWidget(_wrap(
      const DeviceDetailScreen(deviceId: id),
      overrides: [
        incomingDeviceByIdProvider(id).overrideWith(
          (_) => const Stream<Device?>.empty(),
        ),
      ],
    ));
    // Don't pumpAndSettle — we want the loading state.
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('error state shows failure message', (tester) async {
    await tester.pumpWidget(_wrap(
      const DeviceDetailScreen(deviceId: id),
      overrides: [
        incomingDeviceByIdProvider(id).overrideWith(
          (_) => Stream.error(StateError('boom')),
        ),
      ],
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed to load'), findsOneWidget);
  });

  group('rapid-tap delete latch', () {
    const device = Device(
      id: id,
      brand: 'Oticon',
      model: 'More 1',
      type: Style.ric,
      year: '2021',
      batterySize: BatterySize.size312,
      qaStatus: QaStatus.passed,
      status: DeviceStatus.ready,
    );

    // Detail's `_delete()` captures `GoRouter.of(context)` before its first
    // await, so the screen must live under a real router or the confirm path
    // throws before `deleteIncoming` is reached.
    Future<_CountingRepository> pumpDetail(WidgetTester tester) async {
      final repo = _CountingRepository();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const DeviceDetailScreen(deviceId: id),
          ),
        ],
      );
      await tester.pumpWidget(ProviderScope(
        overrides: [
          incomingDeviceByIdProvider(id)
              .overrideWith((_) => Stream.value(device)),
          incomingDeviceRepositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('two rapid taps open exactly one confirm dialog',
        (tester) async {
      await pumpDetail(tester);

      final deleteButton = find.widgetWithIcon(IconButton, Icons.delete_outline);
      // Two taps before settling — the second lands while the first's dialog
      // is mid-open. The synchronous latch must make it a no-op.
      await tester.tap(deleteButton);
      await tester.tap(deleteButton, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
    });

    testWidgets('two rapid confirms fire deleteIncoming exactly once',
        (tester) async {
      final repo = await pumpDetail(tester);

      final deleteButton = find.widgetWithIcon(IconButton, Icons.delete_outline);
      await tester.tap(deleteButton);
      await tester.tap(deleteButton, warnIfMissed: false);
      await tester.pumpAndSettle();

      // Confirm in the (single) dialog. The delete is gated open, so the
      // screen stays mounted and we can assert the call count.
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pump();

      expect(repo.deleteCalls, 1);

      // Let the gated delete complete so no timer/future is left pending.
      repo.gate.complete();
      await tester.pump();
    });

    testWidgets('cancel unlatches so the button works again', (tester) async {
      await pumpDetail(tester);

      final deleteButton = find.widgetWithIcon(IconButton, Icons.delete_outline);
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      // Re-tapping after cancel must re-open the dialog (latch was reset).
      await tester.tap(deleteButton);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  });
}
