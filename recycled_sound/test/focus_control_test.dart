import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/capture/data/focus_control.dart';

/// Exercises the Dart side of the native focus-control plugin without a host
/// platform by mocking the `recycled_sound/focus_control` method channel.
///
/// The contract under test (see [FocusControl.setNearFocus]): it invokes
/// `setNearFocus` on the right channel, returns the native bool when one comes
/// back, defaults to `false` on a null reply, and — critically for the capture
/// flow that fires it unconditionally — NEVER throws: a [PlatformException] or
/// a [MissingPluginException] (channel not registered on this platform) both
/// resolve to `false`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('recycled_sound/focus_control');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('setNearFocus invokes setNearFocus on the focus_control channel',
      () async {
    String? invokedMethod;
    messenger.setMockMethodCallHandler(channel, (call) async {
      invokedMethod = call.method;
      return true;
    });

    final ok = await FocusControl.setNearFocus();

    expect(invokedMethod, 'setNearFocus');
    expect(ok, isTrue);
  });

  test('setNearFocus returns false when the native side reports false',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async => false);
    expect(await FocusControl.setNearFocus(), isFalse);
  });

  test('setNearFocus defaults to false when the native reply is null',
      () async {
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    expect(await FocusControl.setNearFocus(), isFalse);
  });

  test('setNearFocus swallows PlatformException and returns false', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable', message: 'no near focus');
    });
    expect(await FocusControl.setNearFocus(), isFalse);
  });

  test(
      'setNearFocus swallows MissingPluginException (unregistered channel) '
      'and returns false', () async {
    // No handler registered at all → the platform throws
    // MissingPluginException, the exact non-iOS / channel-absent case.
    messenger.setMockMethodCallHandler(channel, null);
    expect(await FocusControl.setNearFocus(), isFalse);
  });
}
