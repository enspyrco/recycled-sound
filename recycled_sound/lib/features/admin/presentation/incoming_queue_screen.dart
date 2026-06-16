import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_chip.dart';
import '../../devices/data/models/device.dart';
import '../../devices/providers/device_providers.dart';
import 'admin_shell.dart';

/// Audiologist/admin triage queue — every incoming device awaiting review.
class IncomingQueueScreen extends ConsumerWidget {
  const IncomingQueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(allIncomingDevicesProvider);
    return AdminShell(
      currentSection: AdminSection.incoming,
      title: 'Incoming queue',
      child: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorPane(error: e),
        data: (devices) {
          if (devices.isEmpty) return const _EmptyState();
          return _QueueTable(devices: devices);
        },
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  const _ErrorPane({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final isPermission = error.toString().contains('permission-denied');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline,
                size: 48, color: AppColors.textMuted),
            const SizedBox(height: 12),
            Text(
              isPermission
                  ? 'You need an audiologist or admin role to view the queue.'
                  : 'Failed to load queue:\n$error',
              style: AppTypography.body,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.inbox_outlined,
                size: 56, color: AppColors.textMuted),
            const SizedBox(height: 12),
            Text('Queue is empty', style: AppTypography.h3),
            const SizedBox(height: 4),
            Text('New scans appear here for review.',
                style: AppTypography.caption),
          ],
        ),
      ),
    );
  }
}

class _QueueTable extends ConsumerStatefulWidget {
  const _QueueTable({required this.devices});
  final List<Device> devices;

  @override
  ConsumerState<_QueueTable> createState() => _QueueTableState();
}

class _QueueTableState extends ConsumerState<_QueueTable> {
  final Set<String> _promoting = {};

  Future<void> _approve(Device d) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(incomingDeviceRepositoryProvider);
    setState(() => _promoting.add(d.id));
    try {
      await repo.promoteToDevice(d.id);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
              'Promoted ${d.brand} ${d.model} to the device register.'),
          backgroundColor: AppColors.success,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Promote failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _promoting.remove(d.id));
    }
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.devices.length} awaiting review',
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
              children: [
                const _QueueHeaderRow(),
                ...widget.devices.map(
                  (d) => _QueueRow(
                    device: d,
                    busy: _promoting.contains(d.id),
                    onApprove: () => _approve(d),
                    onReview: () => context.go('/incoming/${d.id}/review'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueHeaderRow extends StatelessWidget {
  const _QueueHeaderRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          Expanded(flex: 3, child: Text('Device', style: AppTypography.label)),
          Expanded(flex: 1, child: Text('Type', style: AppTypography.label)),
          Expanded(flex: 1, child: Text('Battery', style: AppTypography.label)),
          Expanded(flex: 2, child: Text('Scanned by', style: AppTypography.label)),
          const SizedBox(width: 120),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.device,
    required this.busy,
    required this.onApprove,
    required this.onReview,
  });

  final Device device;
  final bool busy;
  final VoidCallback onApprove;

  /// Tap-through to the full audiologist review screen — the richer path
  /// (resolve flagged fields, edit clinical specs, Pass/Fail). The row's
  /// quick-Approve button stays for the no-edits-needed fast path.
  final VoidCallback onReview;

  @override
  Widget build(BuildContext context) {
    final title = '${device.brand} ${device.model}'.trim();
    // Includes unrecognised blocker keys, not just typed flags — so a device
    // the promotion gate would reject (fail-closed on an un-nameable key) never
    // gets a quick-Approve button that would just throw. Keeps the queue's
    // bypass-suppression aligned with the gate in promoteToDevice.
    final flagged = device.unknownFieldCount;
    return InkWell(
      onTap: onReview,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border:
              Border(bottom: BorderSide(color: AppColors.border, width: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      title.isEmpty ? 'Unidentified device' : title,
                      style: AppTypography.body,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (flagged > 0) ...[
                    const SizedBox(width: 8),
                    RsChip(
                      label: 'NEEDS INPUT $flagged',
                      variant: RsChipVariant.warning,
                    ),
                  ],
                ],
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
              flex: 2,
              child: Text(
                device.scanId.isEmpty ? 'mobile scanner' : device.scanId,
                style: AppTypography.caption,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Quick-Approve is the no-edits fast path: it calls promoteToDevice
            // directly, skipping the review screen. That's ONLY safe when the
            // volunteer flagged nothing — a device with unresolved
            // needsInputFields must NOT be promotable via this bypass, or the
            // whole handoff is defeated (a flagged device could land in
            // devices/ with its flagged fields still undetermined). So when
            // anything is flagged we suppress Approve and force the row's
            // tap-through to review, where Pass is a conscious human action.
            SizedBox(
              width: 120,
              child: flagged > 0
                  ? OutlinedButton.icon(
                      onPressed: onReview,
                      icon: const Icon(Icons.rate_review_outlined, size: 16),
                      label: const Text('Review'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.warning,
                        side: const BorderSide(color: AppColors.warning),
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    )
                  : FilledButton.icon(
                      onPressed: busy ? null : onApprove,
                      icon: busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.check, size: 16),
                      label: Text(busy ? 'Promoting' : 'Approve'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.success,
                        padding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
