/// Compile-time build identity — the ground-truth answer to "what code is
/// this build running?", independent of the marketing version in pubspec.
///
/// ## Why this exists
///
/// On 2026-06-12 Nick's phone showed "0.5.0 (8)" for code three weeks newer:
/// `pubspec.yaml` was never bumped, so the marketing version (shown as the
/// `APP` row in Device Info) is an unreliable identity. Nobody could cleanly
/// answer "what code is Delia/Nick testing?" — a real problem for the
/// volunteer dress rehearsal where several people run different builds.
///
/// The git SHA + build date are injected at build time via `--dart-define`
/// (see `.github/workflows/testflight.yml`). Because they are
/// `String.fromEnvironment` constants, they are always available and never
/// async — so the Device Info screen can show them even when device-sensor
/// telemetry fails.
///
/// Local debug builds that don't pass the defines fall back to `dev` / `local`,
/// which is honest: in debug you already know what you're running.
class BuildInfo {
  // Static-only holder; the constructor is unreachable by design.
  const BuildInfo._(); // coverage:ignore-line

  /// Short git commit the build was compiled from, or `dev` locally.
  static const String gitSha =
      String.fromEnvironment('GIT_SHA', defaultValue: 'dev');

  /// UTC date the build was compiled (YYYY-MM-DD), or `local`.
  static const String buildDate =
      String.fromEnvironment('GIT_BUILD_DATE', defaultValue: 'local');

  /// True when real build identity was injected (i.e. a CI/release build).
  static bool get isReleaseStamped => gitSha != 'dev';

  /// Typed `(label, value)` rows for display, mirroring the telemetry
  /// readout's shape so the Device Info screen renders them identically.
  static List<MapEntry<String, String>> asRows() => [
        MapEntry('COMMIT', gitSha),
        MapEntry('BUILT', buildDate),
      ];
}
