import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_card.dart';
import '../../../core/widgets/rs_chip.dart';
import '../../../core/widgets/rs_spec_row.dart';
import '../data/models/device.dart';
import '../providers/device_providers.dart';
import 'widgets/storage_image.dart';

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

  RsChipVariant _qaVariant(QaStatus status) => switch (status) {
        QaStatus.passed => RsChipVariant.success,
        QaStatus.failed => RsChipVariant.error,
        QaStatus.pendingQa => RsChipVariant.warning,
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${device.brand} ${device.model}'),
        actions: [
          RsChip(
            label: device.qaStatus.wire.replaceAll('_', ' ').toUpperCase(),
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
            if (device.photos.isNotEmpty) ...[
              Text('Photos', style: AppTypography.h3),
              const SizedBox(height: 8),
              _PhotoGallery(deviceId: device.id, photos: device.photos),
              const SizedBox(height: 20),
            ],
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
                  RsSpecRow(label: 'QA', value: device.qaStatus.wire),
                  RsSpecRow(label: 'Status', value: device.status.wire),
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

/// Horizontal strip of device photo thumbnails. Tapping one opens the
/// full-screen [PhotoDetailScreen] (zoom + delete) at `/devices/{id}/photo`.
class _PhotoGallery extends StatelessWidget {
  const _PhotoGallery({required this.deviceId, required this.photos});

  final String deviceId;
  final List<String> photos;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final ref = photos[i];
          return GestureDetector(
            onTap: () => context.push(
              '/devices/$deviceId/photo',
              extra: ref,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 96,
                height: 96,
                child: Hero(
                  tag: ref,
                  child: StorageImage(photoRef: ref),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
