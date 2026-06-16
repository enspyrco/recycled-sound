import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../devices/data/models/device.dart';
import '../../devices/providers/device_providers.dart';
import 'admin_shell.dart';

/// Web Devices view — the curated post-triage register.
class DeviceRegisterScreen extends ConsumerWidget {
  const DeviceRegisterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(allDevicesProvider);
    return AdminShell(
      currentSection: AdminSection.devices,
      title: 'Device register',
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Failed to load devices: $e',
                style: AppTypography.body),
          ),
        ),
        data: (devices) {
          if (devices.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.devices_outlined,
                        size: 56, color: AppColors.textMuted),
                    const SizedBox(height: 12),
                    Text('No devices yet', style: AppTypography.h3),
                    const SizedBox(height: 4),
                    Text(
                      'Promote a device from the Incoming queue to populate the register.',
                      style: AppTypography.caption,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${devices.length} in register',
                  style: AppTypography.caption,
                ),
                const SizedBox(height: 12),
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Column(
                    children: devices.map(_DeviceRow.new).toList(),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow(this.device);
  final Device device;

  @override
  Widget build(BuildContext context) {
    final title = '${device.brand} ${device.model}'.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Text(
              title.isEmpty ? 'Unidentified' : title,
              style: AppTypography.body,
            ),
          ),
          Expanded(
            flex: 1,
            child: Text(device.type.label, style: AppTypography.body),
          ),
          Expanded(
            flex: 1,
            child:
                Text(device.batterySize.label, style: AppTypography.body),
          ),
          Expanded(
            flex: 1,
            child: Text(device.status.wire, style: AppTypography.caption),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              device.qaStatus.wire.replaceAll('_', ' ').toUpperCase(),
              style: AppTypography.caption.copyWith(
                color: AppColors.success,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
