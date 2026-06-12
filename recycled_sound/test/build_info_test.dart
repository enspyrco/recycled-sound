import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/core/build_info.dart';

void main() {
  group('BuildInfo', () {
    test('falls back to dev/local without --dart-define', () {
      // The test binary is compiled without GIT_SHA/GIT_BUILD_DATE defines,
      // so the honest local fallbacks apply.
      expect(BuildInfo.gitSha, 'dev');
      expect(BuildInfo.buildDate, 'local');
      expect(BuildInfo.isReleaseStamped, isFalse);
    });

    test('asRows exposes COMMIT and BUILT in display order', () {
      final rows = BuildInfo.asRows();
      expect(rows.map((r) => r.key), ['COMMIT', 'BUILT']);
      expect(rows[0].value, 'dev');
      expect(rows[1].value, 'local');
    });
  });
}
