import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  // Strong refs so the plugin instances outlive engine init. Without these,
  // the FlutterMethodChannel handlers capture self weakly and the plugins
  // get deallocated as soon as the registration method returns — same GC
  // hazard documented in feedback_native_plugin_gc.md.
  private var visionOcrPlugin: VisionOcrPlugin?
  private var deviceTelemetryPlugin: DeviceTelemetryPlugin?
  private var focusControlPlugin: FocusControlPlugin?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Register Object Capture (LiDAR 3D scanning) platform channel + view.
    // Use the plugin registry's registrar to get the binary messenger —
    // window?.rootViewController is nil with scene-based lifecycle.
    let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ObjectCaptureView")
    if let registrar = registrar {
      ObjectCapturePluginRegistrar.register(
        with: registrar.messenger(),
        registrar: registrar
      )
    }

    // Register native iOS Vision OCR plugin.
    if let visionRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "VisionOcr") {
      visionOcrPlugin = VisionOcrPlugin(messenger: visionRegistrar.messenger())
    }

    // Register device telemetry channel (thermal, low-power, RAM, LiDAR, NE).
    if let telemRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceTelemetry") {
      deviceTelemetryPlugin = DeviceTelemetryPlugin(messenger: telemRegistrar.messenger())
    }

    // Register native focus control (autoFocusRangeRestriction = .near).
    if let focusRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "FocusControl") {
      focusControlPlugin = FocusControlPlugin(messenger: focusRegistrar.messenger())
    }
  }
}
