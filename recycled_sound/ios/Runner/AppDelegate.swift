import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Register Object Capture (LiDAR 3D scanning) platform channel + view
    if let controller = window?.rootViewController as? FlutterViewController {
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ObjectCaptureView")
      ObjectCapturePluginRegistrar.register(
        with: controller.binaryMessenger,
        registrar: registrar
      )
    }
  }
}
