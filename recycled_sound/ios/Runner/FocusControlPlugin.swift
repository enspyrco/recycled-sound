import AVFoundation
import Flutter

/// Native focus control for the guided capture flow.
///
/// The Flutter `camera` plugin exposes focus *mode* and *point* but not
/// `AVCaptureDevice.autoFocusRangeRestriction`. For hearing aids — small
/// objects held ~5–8 cm away — restricting the autofocus search to the near
/// range lets the lens settle faster and more reliably on the subject instead
/// of hunting across the full distance range.
///
/// Channel: `recycled_sound/focus_control`
///
/// Methods:
///   setNearFocus(deviceUniqueId: String?) → Bool
///     Apply `.near` range restriction (+ continuous AF) to the AVCaptureDevice
///     with the given `uniqueID`. When the argument is nil (or unsupplied), the
///     plugin falls back to the back ultra-wide camera (macro-capable, ~2 cm
///     minimum focus distance), and then to the back wide-angle camera. The
///     uniqueID-targeted path is preferred so the restriction lands on
///     whichever device `camera_avfoundation` actually opened — keeping the
///     two sides aligned across iPhones with different lens lineups (non-Pro
///     pre-12s have only the wide; 11/12+ add the ultra-wide; Pros add tele).
///     Returns true if applied, false if the device/feature is unavailable.
///
/// **Macro framing rationale.** Volunteers hold hearing aids ~5–8 cm from the
/// lens to fill the frame. The wide-angle camera has a hardware minimum focus
/// distance of ~10 cm, so the preview stays blurry. The ultra-wide camera does
/// macro down to ~2 cm — same lens iOS's own Camera app uses for "Macro mode".
/// Selecting the ultra-wide camera from Dart (via `availableCameras()` filtered
/// to `CameraLensType.ultraWide`) opens it directly without any multi-cam
/// virtual-device gymnastics.
///
/// **Lock coordination.** `camera_avfoundation` locks the underlying
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
      let args = call.arguments as? [String: Any]
      let uniqueId = args?["deviceUniqueId"] as? String
      result(applyNearFocus(deviceUniqueId: uniqueId))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Resolve which `AVCaptureDevice` to lock.
  ///
  /// Priority: explicit uniqueID (so we match whichever lens Dart selected) →
  /// back ultra-wide (macro-capable) → back wide. Returning the wide as a
  /// final fallback preserves the old behaviour on pre-12 non-Pro iPhones,
  /// where ultra-wide simply doesn't exist.
  private func resolveDevice(deviceUniqueId: String?) -> AVCaptureDevice? {
    if let uid = deviceUniqueId, !uid.isEmpty,
       let device = AVCaptureDevice(uniqueID: uid) {
      return device
    }
    if let ultraWide = AVCaptureDevice.default(
      .builtInUltraWideCamera, for: .video, position: .back
    ) {
      return ultraWide
    }
    return AVCaptureDevice.default(
      .builtInWideAngleCamera, for: .video, position: .back
    )
  }

  /// Returns true if the restriction was applied, false if unsupported.
  private func applyNearFocus(deviceUniqueId: String?) -> Bool {
    guard let device = resolveDevice(deviceUniqueId: deviceUniqueId) else {
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
