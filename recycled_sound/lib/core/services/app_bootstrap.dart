import 'dart:async';

/// Outcome of the async init kicked off in `main()`. Sealed so callers must
/// pattern-match all three states — failure is a visible variant, not an
/// absorbed catch.
sealed class BootstrapStatus {
  const BootstrapStatus();
}

class BootstrapPending extends BootstrapStatus {
  const BootstrapPending();
}

class BootstrapReady extends BootstrapStatus {
  const BootstrapReady();
}

class BootstrapFailed extends BootstrapStatus {
  const BootstrapFailed(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}

/// Tracks the async initialisation Future kicked off in `main()` so the boot
/// screen can await it without re-running it.
///
/// Failure is *resolved*, not rejected — the future always completes with a
/// [BootstrapStatus]. Callers `switch` on the result and decide whether to
/// proceed in degraded mode or block on a retry. This is deliberate: an
/// infinite-await on a swallowed error is the failure mode this class exists
/// to prevent.
class AppBootstrap {
  static Completer<BootstrapStatus>? _completer;
  static BootstrapStatus _current = const BootstrapPending();

  /// Start the init task. Safe to call exactly once from `main()`.
  static void start(Future<void> Function() initialiser) {
    final c = Completer<BootstrapStatus>();
    _completer = c;
    initialiser().then(
      (_) {
        _current = const BootstrapReady();
        c.complete(_current);
      },
      onError: (Object e, StackTrace s) {
        _current = BootstrapFailed(e, s);
        c.complete(_current);
      },
    );
  }

  /// Resolves with the bootstrap outcome. If `start` was never called the
  /// future resolves immediately with [BootstrapReady] so test harnesses that
  /// skip `main()` aren't stranded.
  static Future<BootstrapStatus> get done async =>
      _completer == null ? const BootstrapReady() : await _completer!.future;

  /// Last-known status. Useful for screens that want to render the current
  /// state without awaiting (e.g. an indicator that flips post-init).
  static BootstrapStatus get current => _current;
}
