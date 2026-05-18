import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_card.dart';
import '../../../core/widgets/rs_chip.dart';
import '../../../core/widgets/rs_spec_row.dart';
import '../data/models/device.dart';
import '../providers/device_providers.dart';

/// Device detail screen — live stream of a single `incoming/{id}` doc.
class DeviceDetailScreen extends ConsumerWidget {
  const DeviceDetailScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(incomingDeviceByIdProvider(deviceId));

    return async.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Device')),
        body: Center(child: Text('Failed to load: $e')),
      ),
      data: (device) {
        if (device == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Device')),
            body: const Center(child: Text('Device not found.')),
          );
        }
        return _DetailView(device: device);
      },
    );
  }
}

class _DetailView extends StatelessWidget {
  const _DetailView({required this.device});

  final Device device;

  RsChipVariant _qaVariant(String status) => switch (status) {
        'passed' => RsChipVariant.success,
        'failed' => RsChipVariant.error,
        _ => RsChipVariant.warning,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${device.brand} ${device.model}'),
        actions: [
          RsChip(
            label: device.qaStatus.replaceAll('_', ' ').toUpperCase(),
            variant: _qaVariant(device.qaStatus),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Identification', style: AppTypography.h3),
            const SizedBox(height: 8),
            RsCard(
              child: Column(
                children: [
                  RsSpecRow(label: 'Brand', value: device.brand),
                  RsSpecRow(label: 'Model', value: device.model),
                  RsSpecRow(label: 'Type', value: device.type),
                  RsSpecRow(label: 'Year', value: device.year),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('Specifications', style: AppTypography.h3),
            const SizedBox(height: 8),
            RsCard(
              child: Column(
                children: [
                  RsSpecRow(label: 'Battery', value: device.batterySize),
                  RsSpecRow(label: 'Dome', value: device.domeType),
                  RsSpecRow(label: 'Wax Filter', value: device.waxFilter),
                  RsSpecRow(label: 'Receiver', value: device.receiver),
                  RsSpecRow(
                      label: 'Interface', value: device.programmingInterface),
                  RsSpecRow(label: 'Tech Level', value: device.techLevel),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('Status', style: AppTypography.h3),
            const SizedBox(height: 8),
            RsCard(
              child: Column(
                children: [
                  RsSpecRow(label: 'QA', value: device.qaStatus),
                  RsSpecRow(label: 'Status', value: device.status),
                  RsSpecRow(label: 'Condition', value: device.condition),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
