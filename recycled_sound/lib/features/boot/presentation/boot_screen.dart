// Excluded from coverage: boot splash depending on device_telemetry + periodic timers
// coverage:ignore-file
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/providers/device_telemetry_provider.dart';
import '../../../core/services/app_bootstrap.dart';
import '../../../core/services/device_telemetry.dart';
import '../../../core/widgets/thermal_gauge.dart';

/// Initial diagnostic boot — flashes the device's specs and current thermal
/// load before the home screen mounts. Renders all telemetry rows with a
/// staggered fade-in so the screen feels like a system bring-up sequence
/// rather than a static splash.
///
/// Auto-advances to `/` after [_holdDuration]. Tap anywhere to skip.
/// Advancement happens regardless of Firebase outcome — failure becomes a
/// visible "FB FAIL" tag in the footer rather than an infinite-await trap.
class BootScreen extends ConsumerStatefulWidget {
  const BootScreen({super.key});

  @override
  ConsumerState<BootScreen> createState() => _BootScreenState();
}

class _BootScreenState extends ConsumerState<BootScreen> {
  static const _holdDuration = Duration(milliseconds: 4200);
  static const _staggerStep = Duration(milliseconds: 80);

  /// Shared telemetry service — the same instance backing Settings → Device
  /// Info and a future bug-report flow, so the platform-channel read logic
  /// lives in exactly one place.
  DeviceTelemetryService get _service =>
      ref.read(deviceTelemetryServiceProvider);
  DeviceTelemetry? _telemetry;
  Timer? _advance;
  Timer? _refresh;
  int _revealed = 0;
  bool _telemetryError = false;
  BootstrapStatus _bootstrap = const BootstrapPending();

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // Watch the bootstrap outcome so the footer can show real state.
    unawaited(AppBootstrap.done.then((status) {
      if (!mounted) return;
      setState(() => _bootstrap = status);
      if (status is BootstrapFailed) {
        debugPrint('AppBootstrap failed: ${status.error}\n${status.stackTrace}');
      }
    }));

    try {
      final t = await _service.snapshot();
      if (!mounted) return;
      setState(() => _telemetry = t);
      _staggerReveal(t.asReadout().length);
    } catch (e, s) {
      // Same chord as Firebase: telemetry failure must be visible state, not
      // a fast-navigate that skips the bootstrap gate. Keep the screen
      // mounted, render the degraded state ("sensors unavailable"), and let
      // the normal _tryGo path advance after the hold elapses AND the
      // bootstrap resolves.
      debugPrint('Telemetry snapshot failed at boot: $e\n$s');
      if (!mounted) return;
      setState(() => _telemetryError = true);
    }
    _refresh = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final t = await _service.snapshot();
        if (!mounted) return;
        setState(() {
          _telemetry = t;
          _telemetryError = false;
        });
      } catch (_) {/* ignore — keep last good snapshot */}
    });
    _advance = Timer(_holdDuration, _tryGo);
  }

  /// Wait for bootstrap resolution (success OR failure) before advancing —
  /// downstream screens are degradable but the boot screen shouldn't render
  /// the home shell mid-init. Failure proceeds anyway with a visible
  /// degraded-mode tag; better than infinite-await.
  Future<void> _tryGo() async {
    await AppBootstrap.done;
    _go();
  }

  void _staggerReveal(int total) {
    for (var i = 1; i <= total; i++) {
      Future.delayed(_staggerStep * i, () {
        if (!mounted) return;
        setState(() => _revealed = i);
      });
    }
  }

  void _go() {
    if (!mounted) return;
    context.go('/');
  }

  /// Tap-to-skip: still waits on bootstrap (success or fail) before navigating.
  Future<void> _onTap() async {
    await AppBootstrap.done;
    _go();
  }

  @override
  void dispose() {
    _advance?.cancel();
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = _telemetry;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F14),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                const SizedBox(height: 28),
                Expanded(child: _buildSpecs(t)),
                const SizedBox(height: 16),
                if (t != null) _buildThermal(t),
                const SizedBox(height: 12),
                _buildFooter(t),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFF10B981),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'RECYCLED SOUND',
              style: TextStyle(
                fontFamily: 'Menlo',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 2.0,
                color: Color(0xFFE5E7EB),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'system bring-up',
          style: TextStyle(
            fontFamily: 'Menlo',
            fontSize: 10,
            color: Color(0xFF6B7280),
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }

  Widget _buildSpecs(DeviceTelemetry? t) {
    if (t == null) {
      return Center(
        child: _telemetryError
            ? const Text(
                'sensors unavailable',
                style: TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 11,
                  color: Color(0xFFEF4444),
                  letterSpacing: 1.2,
                ),
              )
            : const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation(Color(0xFF6B7280)),
                ),
              ),
      );
    }
    final entries = t.asReadout();
    return ListView.builder(
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final visible = i < _revealed;
        return AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: visible ? 1.0 : 0.0,
          child: AnimatedSlide(
            duration: const Duration(milliseconds: 220),
            offset: visible ? Offset.zero : const Offset(0, 0.25),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '> ',
                    style: TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 12,
                      color: Color(0xFF10B981),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: Text(
                      entries[i].key,
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                        color: Color(0xFF6B7280),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entries[i].value,
                      style: const TextStyle(
                        fontFamily: 'Menlo',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFF3F4F6),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildThermal(DeviceTelemetry t) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: t.thermalState.coolDownNeeded
              ? const Color(0xFFEF4444)
              : const Color(0xFF1F2937),
        ),
      ),
      child: ThermalGauge(
        load: t.thermalLoad,
        label: 'THERMAL LOAD',
        subLabel:
            '${t.thermalState.label} · ${t.thermalState.estimatedCelsiusBand}',
        coolDownNeeded: t.thermalState.coolDownNeeded,
      ),
    );
  }

  /// Footer reflects the actual bootstrap outcome — success, failure, or
  /// still-pending — and never lies "OK" for a failed init.
  Widget _buildFooter(DeviceTelemetry? t) {
    final (text, badge, badgeColor) = switch ((t, _bootstrap)) {
      (null, _) => ('reading sensors…', null, null),
      (_, BootstrapPending()) => ('connecting to firebase…', null, null),
      (_, BootstrapReady()) =>
        ('tap to continue', 'OK', const Color(0xFF10B981)),
      (_, BootstrapFailed()) => (
          'firebase init failed — tap to continue offline',
          'FB FAIL',
          const Color(0xFFEF4444)
        ),
    };
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontFamily: 'Menlo',
              fontSize: 10,
              color: Color(0xFF6B7280),
              letterSpacing: 1.2,
            ),
          ),
        ),
        if (badge != null)
          Text(
            badge,
            style: TextStyle(
              fontFamily: 'Menlo',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: badgeColor,
              letterSpacing: 1.2,
            ),
          ),
      ],
    );
  }
}
