import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_card.dart';
import '../../../core/widgets/rs_chip.dart';
import '../data/models/device.dart';
import '../providers/device_providers.dart';

/// Device list screen — live stream from `incoming/` (pre-triage register).
///
/// Audiologist-curated `devices/` will land alongside in a later PR; for now
/// "Device Register" surfaces everything the scanner has captured.
class DeviceListScreen extends ConsumerWidget {
  const DeviceListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(incomingDevicesStreamProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Device Register')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Failed to load devices:\n$e',
              style: AppTypography.body,
              textAlign: TextAlign.center,
            ),
          ),
        ),
        data: (devices) {
          if (devices.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.hearing_disabled,
                        size: 48, color: AppColors.textMuted),
                    const SizedBox(height: 12),
                    Text('No devices yet', style: AppTypography.h4),
                    const SizedBox(height: 4),
                    Text('Scanned devices will appear here.',
                        style: AppTypography.caption),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: devices.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final d = devices[i];
              return _DeviceCard(
                device: d,
                onTap: () => context.push('/devices/${d.id}'),
              );
            },
          );
        },
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({required this.device, required this.onTap});

  final Device device;
  final VoidCallback onTap;

  RsChipVariant _qaVariant(String status) => switch (status) {
        'passed' => RsChipVariant.success,
        'failed' => RsChipVariant.error,
        _ => RsChipVariant.warning,
      };

  @override
  Widget build(BuildContext context) {
    final title = '${device.brand} ${device.model}'.trim();
    return GestureDetector(
      onTap: onTap,
      child: RsCard(
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.primaryLight,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.hearing,
                  color: AppColors.primary, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? 'Unidentified device' : title,
                    style: AppTypography.h4,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (device.type.isNotEmpty) device.type,
                      if (device.year.isNotEmpty) device.year,
                      if (device.batterySize.isNotEmpty)
                        'Battery ${device.batterySize}',
                    ].join(' · '),
                    style: AppTypography.caption,
                  ),
                ],
              ),
            ),
            RsChip(
              label: device.qaStatus.replaceAll('_', ' ').toUpperCase(),
              variant: _qaVariant(device.qaStatus),
            ),
          ],
        ),
      ),
    );
  }
}
