import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';
import 'package:recycled_sound/features/devices/presentation/device_list_screen.dart';
import 'package:recycled_sound/features/devices/providers/device_providers.dart';

Widget _wrap({required List<Override> overrides}) {
  return ProviderScope(
    overrides: overrides,
    child: const MaterialApp(home: DeviceListScreen()),
  );
}

void main() {
  const pendingDevice = Device(
    id: 'p1',
    brand: 'Oticon',
    model: 'Nera2 Pro',
    type: Style.bte,
    qaStatus: QaStatus.pendingQa,
    status: DeviceStatus.donated,
  );

  const curatedDevice = Device(
    id: 'c1',
    brand: 'Phonak',
    model: 'Audéo P90',
    type: Style.ric,
    qaStatus: QaStatus.passed,
    status: DeviceStatus.ready,
  );

  testWidgets(
      'pending intake section lists the volunteer\'s captured devices, '
      'distinct from the curated register', (tester) async {
    await tester.pumpWidget(_wrap(
      overrides: [
        // watchMyIncoming() — the volunteer's own captures.
        incomingDevicesStreamProvider
            .overrideWith((_) => Stream.value([pendingDevice])),
        // The curated register.
        allDevicesProvider.overrideWith((_) => Stream.value([curatedDevice])),
      ],
    ));
    await tester.pumpAndSettle();

    // Both section headers render.
    expect(find.text('Pending intake'), findsOneWidget);
    expect(find.text('Device register'), findsOneWidget);

    // The just-captured device is visible and flagged as pending review.
    expect(find.text('Oticon Nera2 Pro'), findsOneWidget);
    expect(find.text('PENDING REVIEW'), findsOneWidget);

    // The curated device is shown with its QA status, not the pending chip.
    expect(find.text('Phonak Audéo P90'), findsOneWidget);
    expect(find.text('PASSED'), findsOneWidget);
  });

  testWidgets(
      'empty pending section shows guidance instead of hiding the section',
      (tester) async {
    await tester.pumpWidget(_wrap(
      overrides: [
        incomingDevicesStreamProvider
            .overrideWith((_) => Stream.value(const [])),
        allDevicesProvider.overrideWith((_) => Stream.value(const [])),
      ],
    ));
    await tester.pumpAndSettle();

    // The section header is always present so the volunteer knows where their
    // scans will land, even before they capture anything.
    expect(find.text('Pending intake'), findsOneWidget);
    expect(
      find.textContaining('Devices you scan appear here'),
      findsOneWidget,
    );
  });
}
