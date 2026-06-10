// Excluded from coverage: native plugin bindings (battery_plus, connectivity_plus, device_info_plus)
// coverage:ignore-file
import 'dart:async';
import 'dart:io' show Platform;

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Closed set of thermal states the OS reports. iOS surfaces 4; we keep an
/// `unknown` for native-channel failure or unrecognised values from a future
/// OS revision. Switches over this enum are exhaustive — adding a state
/// causes a compile error rather than a silent fall-through.
enum ThermalState {
  nominal,
  fair,
  serious,
  critical,
  unknown;

  /// Map a string from the platform channel into a value. Anything we don't
  /// recognise lands in [ThermalState.unknown] rather than throwing — the OS
  /// is allowed to extend this enum and we'd rather render "unknown" than
  /// crash boot.
  static ThermalState parse(String? raw) => switch (raw) {
        'nominal' => ThermalState.nominal,
        'fair' => ThermalState.fair,
        'serious' => ThermalState.serious,
        'critical' => ThermalState.critical,
        _ => ThermalState.unknown,
      };

  /// `serious` and `critical` mean "OS will start throttling soon" — a cue
  /// for the pipeline to back off voluntarily before the camera is slowed.
  bool get coolDownNeeded =>
      this == ThermalState.serious || this == ThermalState.critical;

  /// Apple's HIG maps thermal state to *approximate* chassis-skin
  /// temperature bands. Framed with "≈" to signal estimate-not-measurement —
  /// the OS does NOT expose a CPU temperature reading.
  String get estimatedCelsiusBand => switch (this) {
        ThermalState.nominal => '≈ cool',
        ThermalState.fair => '≈ warm',
        ThermalState.serious => '≈ hot · cooldown soon',
        ThermalState.critical => '≈ very hot · throttling',
        ThermalState.unknown => '—',
      };

  String get label => name.toUpperCase();
}

/// Closed set of network connectivity types we render. `connectivity_plus`
/// returns a list (a device can be on Wi-Fi *and* a VPN); we collapse to a
/// single human-facing value with a clear precedence.
enum NetworkType {
  wifi,
  cellular,
  ethernet,
  vpn,
  bluetooth,
  offline;

  static NetworkType collapse(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi)) return NetworkType.wifi;
    if (results.contains(ConnectivityResult.mobile)) return NetworkType.cellular;
    if (results.contains(ConnectivityResult.ethernet)) return NetworkType.ethernet;
    if (results.contains(ConnectivityResult.vpn)) return NetworkType.vpn;
    if (results.contains(ConnectivityResult.bluetooth)) return NetworkType.bluetooth;
    return NetworkType.offline;
  }

  String get label => switch (this) {
        NetworkType.wifi => 'Wi-Fi',
        NetworkType.cellular => 'Cellular',
        NetworkType.ethernet => 'Ethernet',
        NetworkType.vpn => 'VPN',
        NetworkType.bluetooth => 'Bluetooth',
        NetworkType.offline => 'offline',
      };
}

/// One snapshot of everything we can read about the phone right now.
///
/// Kept intentionally flat so the diagnostic readout can iterate it as a list
/// of `(label, value)` pairs without having to know about each field.
@immutable
class DeviceTelemetry {
  const DeviceTelemetry({
    required this.make,
    required this.modelId,
    required this.modelName,
    required this.osName,
    required this.osVersion,
    required this.appVersion,
    required this.buildNumber,
    required this.locale,
    required this.processorCount,
    required this.physicalMemoryGb,
    required this.batteryPercent,
    required this.charging,
    required this.lowPowerMode,
    required this.networkType,
    required this.thermalState,
    required this.thermalLoad,
    required this.thermalHeadroom,
    required this.hasLidar,
    required this.hasNeuralEngine,
    required this.socModel,
  });

  /// "Apple" / "Samsung" / etc.
  final String make;

  /// Hardware identifier — `iPhone15,2`, `SM-G991B`.
  final String modelId;

  /// Marketing name when known, falls back to `modelId`.
  final String modelName;

  final String osName;
  final String osVersion;
  final String appVersion;
  final String buildNumber;
  final String locale;
  final int processorCount;
  final double physicalMemoryGb;
  final int batteryPercent;
  final bool charging;
  final bool lowPowerMode;
  final NetworkType networkType;
  final ThermalState thermalState;

  /// 0.0–1.0. Fades the gauge across green→orange→red.
  final double thermalLoad;

  /// Android-only thermal headroom *ratio* (not seconds): a dimensionless
  /// float where `1.0` is the severe-throttling threshold and `0.0` is cool.
  /// `getThermalHeadroom(forecastSeconds)` takes seconds as INPUT but returns
  /// a ratio. Null on iOS / Android < 30 / when the OEM hasn't implemented it.
  final double? thermalHeadroom;

  final bool hasLidar;

  /// Nullable: iOS can derive from chip identifier (deterministic), Android
  /// has no honest probe — `null` means "we don't know" and the UI should
  /// omit the row rather than guess.
  final bool? hasNeuralEngine;

  final String? socModel;

  /// `(label, value)` pairs for the diagnostic readout's auto-cycling display.
  /// Order matters — most "interesting" facts first.
  List<MapEntry<String, String>> asReadout() {
    return [
      MapEntry('DEVICE', '$make $modelName'),
      MapEntry('OS', '$osName $osVersion'),
      MapEntry('APP', '$appVersion+$buildNumber'),
      MapEntry('CPU CORES', '$processorCount'),
      MapEntry('RAM', '${physicalMemoryGb.toStringAsFixed(1)} GB'),
      if (socModel != null) MapEntry('SOC', socModel!),
      if (hasNeuralEngine != null)
        MapEntry('NEURAL ENGINE', hasNeuralEngine! ? 'present' : 'absent'),
      MapEntry('LIDAR', hasLidar ? 'present' : 'absent'),
      MapEntry('NETWORK', networkType.label),
      MapEntry('BATTERY', '$batteryPercent%${charging ? ' charging' : ''}'),
      if (lowPowerMode) const MapEntry('LOW POWER', 'enabled'),
      MapEntry('THERMAL', '${thermalState.label} · ${thermalState.estimatedCelsiusBand}'),
      if (thermalState.coolDownNeeded)
        const MapEntry('COOLDOWN', 'recommended — back off frame rate'),
      MapEntry('LOCALE', locale),
    ];
  }
}

/// Reads device facts on demand. No streams; the gauge polls as needed.
class DeviceTelemetryService {
  static const _channel =
      MethodChannel('co.enspyr.recycledSound/device_telemetry');

  final _deviceInfo = DeviceInfoPlugin();
  final _battery = Battery();
  final _connectivity = Connectivity();

  Future<DeviceTelemetry> snapshot() async {
    // Fan out reads in parallel via Dart 3.2 record-based wait — destructure
    // by name, no positional `as` casts. Reorder the tuple, the compiler
    // catches you.
    final (
      native,
      pkg,
      batteryLevel,
      batteryState,
      conn,
      deviceFields,
    ) = await (
      _readNative(),
      PackageInfo.fromPlatform(),
      _battery.batteryLevel,
      _battery.batteryState,
      _connectivity.checkConnectivity(),
      _readDeviceInfo(),
    ).wait;

    final thermalState = ThermalState.parse(native['thermalState'] as String?);

    return DeviceTelemetry(
      make: deviceFields.make,
      modelId: deviceFields.modelId,
      modelName: deviceFields.modelName,
      osName: deviceFields.osName,
      osVersion: deviceFields.osVersion,
      appVersion: pkg.version,
      buildNumber: pkg.buildNumber,
      locale: Platform.localeName,
      processorCount: (native['processorCount'] as num?)?.toInt() ?? 0,
      physicalMemoryGb:
          (native['physicalMemoryGB'] as num?)?.toDouble() ?? 0.0,
      batteryPercent: batteryLevel,
      charging: batteryState == BatteryState.charging ||
          batteryState == BatteryState.full,
      lowPowerMode: (native['lowPowerMode'] as bool?) ?? false,
      networkType: NetworkType.collapse(conn),
      thermalState: thermalState,
      thermalLoad: (native['thermalLoad'] as num?)?.toDouble() ?? 0.0,
      thermalHeadroom: (native['thermalHeadroom'] as num?)?.toDouble(),
      hasLidar: (native['hasLidar'] as bool?) ?? false,
      hasNeuralEngine: native['hasNeuralEngine'] as bool?,
      socModel: native['socModel'] as String?,
    );
  }

  Future<Map<String, dynamic>> _readNative() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>('snapshot');
      if (raw == null) return const {};
      return raw.map((k, v) => MapEntry(k.toString(), v));
    } on MissingPluginException {
      // Native plugin isn't registered (test harness, web build, etc.) —
      // expected; render telemetry as empty rather than crash.
      return const {};
    } on PlatformException catch (e, s) {
      // Plugin is registered but a specific call failed — log so the cause
      // doesn't disappear, then degrade gracefully.
      debugPrint('DeviceTelemetry native call failed: ${e.code} ${e.message}');
      FlutterError.reportError(FlutterErrorDetails(exception: e, stack: s));
      return const {};
    }
  }

  Future<_DeviceFields> _readDeviceInfo() async {
    if (Platform.isIOS) {
      final ios = await _deviceInfo.iosInfo;
      return _DeviceFields(
        make: 'Apple',
        modelId: ios.utsname.machine,
        modelName: _iosMarketingName(ios.utsname.machine),
        osName: ios.systemName,
        osVersion: ios.systemVersion,
      );
    }
    final android = await _deviceInfo.androidInfo;
    return _DeviceFields(
      make: _capitalise(android.manufacturer),
      modelId: android.model,
      modelName: '${_capitalise(android.manufacturer)} ${android.model}',
      osName: 'Android',
      osVersion: android.version.release,
    );
  }

  /// Hand-maintained lookup. Falls back to the raw identifier when unknown
  /// so users still see something meaningful (e.g. `iPhone20,1`). Worth
  /// migrating to an asset JSON if this list keeps growing past ~50 entries.
  String _iosMarketingName(String id) {
    const map = <String, String>{
      // iPhones
      'iPhone8,1': 'iPhone 6s',
      'iPhone8,2': 'iPhone 6s Plus',
      'iPhone8,4': 'iPhone SE (1st gen)',
      'iPhone9,1': 'iPhone 7',
      'iPhone9,3': 'iPhone 7',
      'iPhone9,2': 'iPhone 7 Plus',
      'iPhone9,4': 'iPhone 7 Plus',
      'iPhone10,1': 'iPhone 8',
      'iPhone10,4': 'iPhone 8',
      'iPhone10,2': 'iPhone 8 Plus',
      'iPhone10,5': 'iPhone 8 Plus',
      'iPhone10,3': 'iPhone X',
      'iPhone10,6': 'iPhone X',
      'iPhone11,2': 'iPhone XS',
      'iPhone11,4': 'iPhone XS Max',
      'iPhone11,6': 'iPhone XS Max',
      'iPhone11,8': 'iPhone XR',
      'iPhone12,1': 'iPhone 11',
      'iPhone12,3': 'iPhone 11 Pro',
      'iPhone12,5': 'iPhone 11 Pro Max',
      'iPhone12,8': 'iPhone SE (2nd gen)',
      'iPhone13,1': 'iPhone 12 mini',
      'iPhone13,2': 'iPhone 12',
      'iPhone13,3': 'iPhone 12 Pro',
      'iPhone13,4': 'iPhone 12 Pro Max',
      'iPhone14,2': 'iPhone 13 Pro',
      'iPhone14,3': 'iPhone 13 Pro Max',
      'iPhone14,4': 'iPhone 13 mini',
      'iPhone14,5': 'iPhone 13',
      'iPhone14,6': 'iPhone SE (3rd gen)',
      'iPhone14,7': 'iPhone 14',
      'iPhone14,8': 'iPhone 14 Plus',
      'iPhone15,2': 'iPhone 14 Pro',
      'iPhone15,3': 'iPhone 14 Pro Max',
      'iPhone15,4': 'iPhone 15',
      'iPhone15,5': 'iPhone 15 Plus',
      'iPhone16,1': 'iPhone 15 Pro',
      'iPhone16,2': 'iPhone 15 Pro Max',
      'iPhone17,1': 'iPhone 16 Pro',
      'iPhone17,2': 'iPhone 16 Pro Max',
      'iPhone17,3': 'iPhone 16',
      'iPhone17,4': 'iPhone 16 Plus',
      // iPads (audiology students test on these)
      'iPad11,1': 'iPad mini (5th gen)',
      'iPad11,2': 'iPad mini (5th gen)',
      'iPad11,3': 'iPad Air (3rd gen)',
      'iPad11,4': 'iPad Air (3rd gen)',
      'iPad13,1': 'iPad Air (4th gen)',
      'iPad13,2': 'iPad Air (4th gen)',
      'iPad13,8': 'iPad Pro 12.9 (5th gen)',
      'iPad13,16': 'iPad Air (5th gen)',
      'iPad14,1': 'iPad mini (6th gen)',
      'iPad14,3': 'iPad Pro 11 (4th gen)',
      'iPad14,5': 'iPad Pro 12.9 (6th gen)',
      'iPad15,3': 'iPad Air 11 (M2)',
      'iPad15,5': 'iPad Air 13 (M2)',
      'iPad16,3': 'iPad Pro 11 (M4)',
      'iPad16,5': 'iPad Pro 13 (M4)',
      // Simulators
      'i386': 'Simulator (x86)',
      'x86_64': 'Simulator (x86_64)',
      'arm64': 'Simulator (arm64)',
    };
    return map[id] ?? id;
  }

  String _capitalise(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);
}

class _DeviceFields {
  _DeviceFields({
    required this.make,
    required this.modelId,
    required this.modelName,
    required this.osName,
    required this.osVersion,
  });
  final String make;
  final String modelId;
  final String modelName;
  final String osName;
  final String osVersion;
}
