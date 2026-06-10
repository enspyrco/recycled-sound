import 'package:flutter/services.dart';

/// Dart side of the native focus-control plugin (`FocusControlPlugin.swift`).
///
/// Lets the capture flow restrict autofocus to the near range for the small,
/// close-held hearing aids — see the Swift plugin doc for why and for the
/// lock-coordination caveat (call [setNearFocus] once, after the camera is
/// initialized; don't also drive focus mode/point from Dart).
///
/// iOS-only. On other platforms (or if the channel isn't registered) the call
/// is a no-op returning false, so callers can fire it unconditionally.
class FocusControl {
  static const _channel = MethodChannel('recycled_sound/focus_control');

  /// Apply `.near` autofocus range restriction to the capture device.
  ///
  /// Pass [deviceUniqueId] (the `CameraDescription.name` reported by the
  /// `camera` plugin on iOS — which IS the AVCaptureDevice uniqueID) so the
  /// restriction lands on the exact lens the controller opened. When the id is
  /// null/empty, the native side falls back to the back ultra-wide camera
  /// (macro-capable), then to the back wide-angle camera. Returns true if
  /// applied, false if unsupported/unavailable. Never throws out of the
  /// capture flow — a platform exception resolves to false.
  static Future<bool> setNearFocus({String? deviceUniqueId}) async {
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setNearFocus',
        <String, dynamic>{
          if (deviceUniqueId != null && deviceUniqueId.isNotEmpty)
            'deviceUniqueId': deviceUniqueId,
        },
      );
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
