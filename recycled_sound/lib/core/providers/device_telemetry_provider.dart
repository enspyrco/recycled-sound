import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/device_telemetry.dart';

/// The single owner of the on-device telemetry read.
///
/// Boot (diagnostic splash), Settings → Device Info, and a future bug-report
/// flow all consume telemetry through these providers so the platform-channel
/// read logic lives in exactly one place. The service already parses
/// closed-set fields ([ThermalState], [NetworkType]) into typed enums at the
/// channel boundary — see `feedback_typed_at_the_boundary` — so consumers never
/// touch raw Strings.
///
/// Overridable in tests: inject a fake [DeviceTelemetryService] to render the
/// Device Info screen without a live platform channel.
final deviceTelemetryServiceProvider = Provider<DeviceTelemetryService>((ref) {
  return DeviceTelemetryService();
});

/// A one-shot snapshot of everything the app can read about the device right
/// now. Backs the Device Info screen's "what the app knows about your device"
/// transparency readout.
///
/// Use `ref.refresh(deviceTelemetrySnapshotProvider)` to re-read (e.g. a
/// pull-to-refresh or a "refresh" button). The future resolves to the same
/// [DeviceTelemetry] payload a future bug-report flow will attach — read it
/// once here, reuse it there, no duplicate channel reads.
final deviceTelemetrySnapshotProvider =
    FutureProvider<DeviceTelemetry>((ref) async {
  return ref.watch(deviceTelemetryServiceProvider).snapshot();
});
