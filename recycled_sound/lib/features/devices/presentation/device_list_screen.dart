import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_card.dart';
import '../../../core/widgets/rs_chip.dart';
import '../data/models/device.dart';
import '../providers/device_providers.dart';

/// Device list screen — two clearly-separated registers, so a volunteer can
/// always find the device they just captured.
///
/// **Why two sections.** A capture writes an `incoming/` doc (pre-triage) owned
/// by the volunteer; it is NOT yet in the curated `devices/` register an
/// audiologist promotes into. Before this split the screen showed only one of
/// the two and called it "Device Register", so a volunteer who scanned a device
/// then went looking for it in "the register" couldn't tell whether their scan
/// had landed. Now their own just-captured devices surface in a labelled
/// **"Pending intake"** section (their `watchMyIncoming()` stream) — explicitly
/// flagged as awaiting audiologist review — above the curated **register**
/// (`allDevicesProvider`). The two data states are visually distinct, so the
/// scan is always somewhere the volunteer would look.
class DeviceListScreen extends ConsumerWidget {
  const DeviceListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(incomingDevicesStreamProvider);
    final register = ref.watch(allDevicesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Pending intake — the volunteer's own captures ──────────────
          const _SectionHeader(
            title: 'Pending intake',
            subtitle: 'Your scans, awaiting audiologist review.',
            icon: Icons.pending_actions,
          ),
          const SizedBox(height: 12),
          pending.when(
            loading: () => const _SectionLoading(),
            error: (e, _) => _SectionError(error: e),
            data: (devices) {
              if (devices.isEmpty) {
                return const _SectionEmpty(
                  icon: Icons.hourglass_empty,
                  message:
                      "Devices you scan appear here until an "
                      'audiologist reviews them.',
                );
              }
              return _DeviceList(
                devices: devices,
                pending: true,
                onTap: (d) => context.push('/devices/${d.id}'),
              );
            },
          ),

          const SizedBox(height: 28),

          // ── Curated register — post-triage devices ─────────────────────
          const _SectionHeader(
            title: 'Device register',
            subtitle: 'Reviewed and confirmed by an audiologist.',
            icon: Icons.verified_outlined,
          ),
          const SizedBox(height: 12),
          register.when(
            loading: () => const _SectionLoading(),
            error: (e, _) => _SectionError(error: e),
            data: (devices) {
              if (devices.isEmpty) {
                return const _SectionEmpty(
                  icon: Icons.hearing_disabled,
                  message: 'Confirmed devices will appear here.',
                );
              }
              return _DeviceList(
                devices: devices,
                pending: false,
                onTap: (d) => context.push('/devices/${d.id}'),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// A labelled section heading with a leading icon and one-line subtitle.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20, color: AppColors.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: AppTypography.h3),
              const SizedBox(height: 2),
              Text(subtitle, style: AppTypography.caption),
            ],
          ),
        ),
      ],
    );
  }
}

/// Vertical list of device cards. [pending] toggles the "pending" framing on
/// each card (a PENDING REVIEW chip instead of the QA-status chip).
class _DeviceList extends StatelessWidget {
  const _DeviceList({
    required this.devices,
    required this.pending,
    required this.onTap,
  });

  final List<Device> devices;
  final bool pending;
  final void Function(Device) onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < devices.length; i++) ...[
          if (i > 0) const SizedBox(height: 12),
          _DeviceCard(
            device: devices[i],
            pending: pending,
            onTap: () => onTap(devices[i]),
          ),
        ],
      ],
    );
  }
}

class _SectionLoading extends StatelessWidget {
  const _SectionLoading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 24),
    child: Center(child: CircularProgressIndicator()),
  );
}

class _SectionError extends StatelessWidget {
  const _SectionError({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    return RsCard(
      child: Text('Failed to load: $error', style: AppTypography.body),
    );
  }
}

class _SectionEmpty extends StatelessWidget {
  const _SectionEmpty({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return RsCard(
      child: Row(
        children: [
          Icon(icon, size: 28, color: AppColors.textMuted),
          const SizedBox(width: 12),
          Expanded(child: Text(message, style: AppTypography.caption)),
        ],
      ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  const _DeviceCard({
    required this.device,
    required this.onTap,
    this.pending = false,
  });

  final Device device;
  final VoidCallback onTap;

  /// When true the card shows a "PENDING REVIEW" chip and a clock icon rather
  /// than the QA-status chip — it's an un-triaged capture, not a register entry.
  final bool pending;

  RsChipVariant _qaVariant(QaStatus status) => switch (status) {
    QaStatus.passed => RsChipVariant.success,
    QaStatus.failed => RsChipVariant.error,
    QaStatus.pendingQa => RsChipVariant.warning,
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
              child: Icon(
                pending ? Icons.schedule : Icons.hearing,
                color: AppColors.primary,
                size: 24,
              ),
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
                      if (device.type != Style.unspecified) device.type.wire,
                      if (device.year.isNotEmpty) device.year,
                      if (device.batterySize != BatterySize.unspecified)
                        'Battery ${device.batterySize.wire}',
                      // Physical storage box (issue #766) — helps a
                      // volunteer or audiologist physically locate the device.
                      if (device.location.isNotEmpty) 'Box ${device.location}',
                    ].join(' · '),
                    style: AppTypography.caption,
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                pending
                    ? const RsChip(
                        label: 'PENDING REVIEW',
                        variant: RsChipVariant.info,
                      )
                    : RsChip(
                        label: device.qaStatus.wire
                            .replaceAll('_', ' ')
                            .toUpperCase(),
                        variant: _qaVariant(device.qaStatus),
                      ),
                // Volunteer flagged one or more fields Unknown at scan time —
                // the audiologist still needs to determine them.
                if (device.unknownFieldCount > 0) ...[
                  const SizedBox(height: 6),
                  const RsChip(
                    label: 'NEEDS INPUT',
                    variant: RsChipVariant.warning,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
