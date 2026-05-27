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

  /// Apply `.near` autofocus range restriction to the back wide camera.
  /// Returns true if applied, false if unsupported/unavailable. Never throws
  /// out of the capture flow — a platform exception resolves to false.
  static Future<bool> setNearFocus() async {
    try {
      final ok = await _channel.invokeMethod<bool>('setNearFocus');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
