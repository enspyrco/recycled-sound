import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/build_info.dart';
import '../../../core/providers/device_telemetry_provider.dart';
import '../../../core/services/device_telemetry.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_card.dart';
import '../../../core/widgets/rs_spec_row.dart';

/// Device Info screen — user-facing transparency readout of the on-device
/// telemetry the app already collects (model, OS, battery, network, thermal
/// state, etc.).
///
/// Reads the SHARED [deviceTelemetrySnapshotProvider] so this view, the boot
/// diagnostic splash, and a future bug-report flow all consume one source of
/// truth. The typed `(label, value)` rows come from
/// [DeviceTelemetry.asReadout], so the formatting never drifts between screens.
class DeviceInfoScreen extends ConsumerWidget {
  const DeviceInfoScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(deviceTelemetrySnapshotProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Info'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(deviceTelemetrySnapshotProvider),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Build identity pinned at top, and ALWAYS — it's a compile-time
            // constant, so it renders even when device-sensor telemetry
            // fails. This is the ground-truth "what code is this build?"
            // answer the marketing version can't give (pubspec may be stale).
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: _BuildIdentityCard(),
            ),
            // Telemetry scrolls below in BOUNDED height (Expanded), so the
            // readout's own scroll view never gets an unbounded constraint.
            Expanded(
              child: async.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => _ErrorView(error: e),
                data: (telemetry) => _ReadoutView(telemetry: telemetry),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Always-visible build identity card (git SHA + build date). See [BuildInfo].
class _BuildIdentityCard extends StatelessWidget {
  const _BuildIdentityCard();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('BUILD', style: AppTypography.label),
        const SizedBox(height: 8),
        RsCard(
          child: Column(
            children: [
              for (final row in BuildInfo.asRows())
                RsSpecRow(label: row.key, value: row.value),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReadoutView extends StatelessWidget {
  const _ReadoutView({required this.telemetry});

  final DeviceTelemetry telemetry;

  @override
  Widget build(BuildContext context) {
    final rows = telemetry.asReadout();
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This is everything the app can read about your device. We attach '
            'these details to bug reports to help diagnose issues — nothing '
            'here identifies you personally.',
            style: AppTypography.body.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: 20),
          RsCard(
            child: Column(
              children: [
                for (final row in rows)
                  RsSpecRow(label: row.key, value: row.value),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.sensors_off, color: AppColors.textMuted, size: 40),
            const SizedBox(height: 12),
            Text(
              'Device info unavailable',
              style: AppTypography.h4,
            ),
            const SizedBox(height: 4),
            Text(
              'Could not read device sensors: $error',
              style: AppTypography.caption,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
