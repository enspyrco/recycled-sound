import ARKit
import Flutter
import UIKit

/// Exposes runtime device telemetry that `device_info_plus` and `battery_plus`
/// don't cover: thermal state, low-power-mode, processor count, physical RAM,
/// LiDAR availability, and Neural Engine presence (derived from chip family).
class DeviceTelemetryPlugin: NSObject {
  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: "co.enspyr.recycledSound/device_telemetry",
      binaryMessenger: messenger
    )
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "snapshot":
      result(snapshot())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func snapshot() -> [String: Any] {
    let info = ProcessInfo.processInfo
    let bytes = info.physicalMemory

    return [
      "thermalState": thermalStateString(info.thermalState),
      "thermalLoad": thermalLoad(info.thermalState),
      "lowPowerMode": info.isLowPowerModeEnabled,
      "processorCount": info.processorCount,
      "activeProcessorCount": info.activeProcessorCount,
      "physicalMemoryBytes": bytes,
      "physicalMemoryGB": Double(bytes) / 1_073_741_824.0,
      "uptime": info.systemUptime,
      "hasLidar": Self.hasLidar(),
      "hasNeuralEngine": Self.hasNeuralEngine(),
    ]
  }

  /// Map ProcessInfo.ThermalState → an engineering name we surface in the UI.
  private func thermalStateString(_ s: ProcessInfo.ThermalState) -> String {
    switch s {
    case .nominal: return "nominal"
    case .fair: return "fair"
    case .serious: return "serious"
    case .critical: return "critical"
    @unknown default: return "unknown"
    }
  }

  /// Map thermal state to a 0.0–1.0 normalised "load" so the gauge can fade
  /// smoothly across green→orange→red. iOS only gives us 4 discrete states,
  /// so we space them at 0.15 / 0.45 / 0.75 / 1.0.
  private func thermalLoad(_ s: ProcessInfo.ThermalState) -> Double {
    switch s {
    case .nominal: return 0.15
    case .fair: return 0.45
    case .serious: return 0.75
    case .critical: return 1.0
    @unknown default: return 0.0
    }
  }

  /// LiDAR is iOS 13.4+ only via the `.mesh` scene reconstruction option.
  /// Direct typed call — `arkit_plugin` is already a pubspec dep so ARKit
  /// is in the link graph; the previous Objective-C runtime reflection
  /// dance was a holdover from an earlier "avoid hard dep" mistake.
  private static func hasLidar() -> Bool {
    if #available(iOS 13.4, *) {
      return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }
    return false
  }

  /// Neural Engine: A12 Bionic (2018) and later. We map by `utsname.machine`.
  /// Conservative — returns true only for chips we know have one.
  private static func hasNeuralEngine() -> Bool {
    let id = machineIdentifier()
    // iPhone11,* (XR/XS, A12) and later. iPad8,* (Pro 2018, A12X) and later.
    let neuralPrefixes = [
      "iPhone11,", "iPhone12,", "iPhone13,", "iPhone14,", "iPhone15,",
      "iPhone16,", "iPhone17,", "iPhone18,",
      "iPad8,", "iPad11,", "iPad12,", "iPad13,", "iPad14,", "iPad15,", "iPad16,",
    ]
    return neuralPrefixes.contains(where: { id.hasPrefix($0) })
  }

  private static func machineIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let machineMirror = Mirror(reflecting: systemInfo.machine)
    return machineMirror.children.reduce("") { id, element in
      guard let value = element.value as? Int8, value != 0 else { return id }
      return id + String(UnicodeScalar(UInt8(value)))
    }
  }
}
