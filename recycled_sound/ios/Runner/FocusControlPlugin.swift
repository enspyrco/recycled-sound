import AVFoundation
import Flutter

/// Native focus control for the guided capture flow.
///
/// The Flutter `camera` plugin exposes focus *mode* and *point* but not
/// `AVCaptureDevice.autoFocusRangeRestriction`. For hearing aids — small
/// objects held ~10–20 cm away — restricting the autofocus search to the near
/// range lets the lens settle faster and more reliably on the subject instead
/// of hunting across the full distance range.
///
/// Channel: `recycled_sound/focus_control`
///
/// Methods:
///   setNearFocus() → Bool
///     Apply `.near` range restriction (+ continuous AF) to the back wide
///     camera. Returns true if applied, false if the device/feature is
///     unavailable. Throws a FlutterError only on an actual config error.
///
/// **Lock coordination.** `camera_avfoundation` locks this same
/// `AVCaptureDevice` transiently inside its own focus config during
/// `initialize()`. `lockForConfiguration()` is a brief critical section, not a
/// held lock, so calling this ONCE after the camera is initialized (when the
/// plugin isn't mid-config) does not contend. The capture screen must not also
/// drive `setFocusMode/Point` from Dart afterwards, or the two could race.
class FocusControlPlugin: NSObject {
  private var channel: FlutterMethodChannel?

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    let channel = FlutterMethodChannel(
      name: "recycled_sound/focus_control",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setNearFocus":
      result(applyNearFocus())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Returns true if the restriction was applied, false if unsupported.
  private func applyNearFocus() -> Bool {
    guard let device = AVCaptureDevice.default(
      .builtInWideAngleCamera, for: .video, position: .back
    ) else {
      return false
    }
    guard device.isAutoFocusRangeRestrictionSupported else {
      return false
    }
    do {
      try device.lockForConfiguration()
      defer { device.unlockForConfiguration() }
      device.autoFocusRangeRestriction = .near
      if device.isFocusModeSupported(.continuousAutoFocus) {
        device.focusMode = .continuousAutoFocus
      }
      return true
    } catch {
      // Couldn't lock (e.g. another holder mid-config) — report so Dart can
      // decide whether to retry; non-fatal for the capture flow.
      return false
    }
  }
}
