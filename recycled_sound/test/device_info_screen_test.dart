import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/core/providers/device_telemetry_provider.dart';
import 'package:recycled_sound/core/services/device_telemetry.dart';
import 'package:recycled_sound/features/settings/presentation/device_info_screen.dart';

/// Builds a [DeviceTelemetry] with sensible defaults so each test only sets
/// the fields it cares about.
DeviceTelemetry _telemetry({
  ThermalState thermalState = ThermalState.nominal,
  NetworkType networkType = NetworkType.wifi,
}) {
  return DeviceTelemetry(
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
    networkType: networkType,
    thermalState: thermalState,
    thermalLoad: 0.2,
    thermalHeadroom: null,
    hasLidar: true,
    hasNeuralEngine: true,
    socModel: 'A16 Bionic',
  );
}

/// Fake service returning a canned snapshot (or error) without a live channel.
class _FakeTelemetryService implements DeviceTelemetryService {
  _FakeTelemetryService(this._result);

  final FutureOr<DeviceTelemetry> Function() _result;

  @override
  Future<DeviceTelemetry> snapshot() async => _result();
}

Widget _wrap({required DeviceTelemetryService service}) {
  return ProviderScope(
    overrides: [
      deviceTelemetryServiceProvider.overrideWithValue(service),
    ],
    child: const MaterialApp(home: DeviceInfoScreen()),
  );
}

void main() {
  testWidgets('renders the telemetry readout from the shared provider',
      (tester) async {
    await tester.pumpWidget(_wrap(
      service: _FakeTelemetryService(() => _telemetry()),
    ));
    await tester.pumpAndSettle();

    // Header transparency framing.
    expect(find.textContaining('everything the app can read'), findsOneWidget);

    // A few readout rows (labels come from DeviceTelemetry.asReadout).
    expect(find.text('DEVICE'), findsOneWidget);
    expect(find.text('Apple iPhone 14 Pro'), findsOneWidget);
    expect(find.text('OS'), findsOneWidget);
    expect(find.text('iOS 17.4'), findsOneWidget);

    // Typed closed-set fields render through their enum labels, not raw strings.
    expect(find.text('NETWORK'), findsOneWidget);
    expect(find.text('Wi-Fi'), findsOneWidget);
  });

  testWidgets('typed thermal enum drives the cooldown row', (tester) async {
    await tester.pumpWidget(_wrap(
      service: _FakeTelemetryService(
        () => _telemetry(thermalState: ThermalState.serious),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('COOLDOWN'), findsOneWidget);
  });

  testWidgets('shows a loading spinner before the snapshot resolves',
      (tester) async {
    final completer = Completer<DeviceTelemetry>();
    await tester.pumpWidget(_wrap(
      service: _FakeTelemetryService(() => completer.future),
    ));
    // Don't settle — we want the in-flight state.
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    completer.complete(_telemetry());
    await tester.pumpAndSettle();
  });

  testWidgets('shows a degraded view when the read fails', (tester) async {
    await tester.pumpWidget(_wrap(
      service: _FakeTelemetryService(() => throw StateError('no sensors')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Device info unavailable'), findsOneWidget);
  });

  testWidgets('build identity card renders with the compile-time defaults',
      (tester) async {
    await tester.pumpWidget(_wrap(
      service: _FakeTelemetryService(() => _telemetry()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('BUILD'), findsOneWidget);
    expect(find.text('COMMIT'), findsOneWidget);
    expect(find.text('BUILT'), findsOneWidget);
    // No --dart-define in the test environment → honest local fallbacks.
    expect(find.text('dev'), findsOneWidget);
    expect(find.text('local'), findsOneWidget);
  });

  testWidgets('build identity stays visible even when telemetry fails',
      (tester) async {
    // The whole point: when device sensors die, you can STILL read which
    // build is on the phone. Build identity is a compile-time constant, so
    // it renders independently of the async telemetry section.
    await tester.pumpWidget(_wrap(
      service: _FakeTelemetryService(() => throw StateError('no sensors')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Device info unavailable'), findsOneWidget);
    expect(find.text('BUILD'), findsOneWidget);
    expect(find.text('COMMIT'), findsOneWidget);
  });
}
