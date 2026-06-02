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
///     with the given `uniqueID`. When an ID is supplied and doesn't resolve,
///     the call returns false rather than locking a fallback lens — guessing
///     would desync Dart's preview from native's focus restriction. When the
///     argument is nil (or unsupplied), the plugin falls back to the back
///     wide-angle camera, preserving the pre-macro-lens contract for any
///     pre-existing channel callers. Modern callers (the capture screen)
///     should pass the explicit uniqueID — the screen now opens the back
///     ultra-wide for macro focus and passes its `CameraDescription.name`
///     so `.near` lands on that exact lens.
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
  /// Two disjoint paths, not a cascade:
  ///
  /// * **Explicit uniqueID supplied.** Look it up via
  ///   `AVCaptureDevice(uniqueID:)` and return whatever that resolves to —
  ///   `nil` if it doesn't resolve. We deliberately do NOT silently fall
  ///   through to a default lens here: the caller passed an ID because they
  ///   want THAT lens, and locking a sibling lens would create a state
  ///   mismatch (Dart viewing lens A while native restricts lens B).
  ///   Returning nil surfaces the failure as `setNearFocus → false`, which
  ///   the capture flow already handles (it falls back to Dart-driven
  ///   centre AF).
  ///
  /// * **No uniqueID supplied** (or empty). Preserve the pre-macro-lens
  ///   contract — the original `setNearFocus()` targeted the back
  ///   wide-angle camera, so legacy callers (none in-tree today, but the
  ///   method-channel API is observable) keep getting the wide. Modern
  ///   callers should pass the explicit uniqueID to opt into the ultra-wide
  ///   path; the capture screen does.
  private func resolveDevice(deviceUniqueId: String?) -> AVCaptureDevice? {
    if let uid = deviceUniqueId, !uid.isEmpty {
      return AVCaptureDevice(uniqueID: uid)
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
