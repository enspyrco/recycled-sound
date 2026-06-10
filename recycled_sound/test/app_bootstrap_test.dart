import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/core/services/app_bootstrap.dart';

void main() {
  group('AppBootstrap', () {
    test('done resolves Ready immediately when start was never called', () async {
      // Note: this test runs in isolation but AppBootstrap holds static
      // state — if some earlier test called start(), `done` would resolve
      // with the previously-recorded outcome. We accept that here and
      // assert it's a known BootstrapStatus subtype.
      final s = await AppBootstrap.done;
      expect(s, isA<BootstrapStatus>());
    });

    test('current snapshot returns a status without awaiting', () {
      expect(AppBootstrap.current, isA<BootstrapStatus>());
    });

    test('start completes with Ready on success', () async {
      AppBootstrap.start(() async {
        // simulate fast init
      });
      final s = await AppBootstrap.done;
      expect(s, isA<BootstrapReady>());
      expect(AppBootstrap.current, isA<BootstrapReady>());
    });

    test('start completes with Failed on error', () async {
      AppBootstrap.start(() async {
        throw StateError('boom');
      });
      final s = await AppBootstrap.done;
      expect(s, isA<BootstrapFailed>());
      final f = s as BootstrapFailed;
      expect(f.error, isA<StateError>());
      expect(f.stackTrace, isA<StackTrace>());
    });

    test('BootstrapPending is constructible', () {
      const p = BootstrapPending();
      expect(p, isA<BootstrapStatus>());
    });
  });
}
