import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/widgets/rs_card.dart';
import '../../../core/widgets/rs_chip.dart';
import '../../../core/widgets/rs_spec_row.dart';
import '../data/incoming_device_repository.dart';
import '../data/models/device.dart';
import '../providers/device_providers.dart';
import 'widgets/storage_image.dart';

/// Back-affordance for the device-detail surface.
///
/// This route is registered on the *root* navigator (not the shell), so it
/// gets no bottom-tab fallback. It's also entered two different ways:
///
///   * From the device list via `context.push('/devices/:id')` — stack push,
///     so a `pop` returns to the list.
///   * From the capture flow's `_save()` via `context.go('/devices/:id')` —
///     stack replace, so there's nothing to pop and the user is stranded
///     (the failure mode Delia reported as #92).
///
/// `canPop() ? pop : go('/')` handles both entry points from a single call
/// site — the right idiom for any go_router screen that can be reached via
/// both push and go. Replacing the AppBar's auto-generated back button (which
/// would silently do nothing in the go-entry case) with this widget makes
/// the back action work regardless of how the user got here.
Widget _homeOrPopButton(BuildContext context) => IconButton(
      icon: const Icon(Icons.arrow_back),
      tooltip: 'Back',
      onPressed: () =>
          context.canPop() ? context.pop() : context.go('/'),
    );

/// Device detail screen — live stream of a single `incoming/{id}` doc.
class DeviceDetailScreen extends ConsumerWidget {
  const DeviceDetailScreen({super.key, required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(incomingDeviceByIdProvider(deviceId));

    return async.when(
      loading: () => Scaffold(
        appBar: AppBar(
          leading: _homeOrPopButton(context),
          title: const Text('Device'),
        ),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(
          leading: _homeOrPopButton(context),
          title: const Text('Device'),
        ),
        body: Center(child: Text('Failed to load: $e')),
      ),
      data: (device) {
        if (device == null) {
          return Scaffold(
            appBar: AppBar(
              leading: _homeOrPopButton(context),
              title: const Text('Device'),
            ),
            body: const Center(child: Text('Device not found.')),
          );
        }
        return _DetailView(device: device);
      },
    );
  }
}

class _DetailView extends ConsumerStatefulWidget {
  const _DetailView({required this.device});

  final Device device;

  @override
  ConsumerState<_DetailView> createState() => _DetailViewState();
}

class _DetailViewState extends ConsumerState<_DetailView> {
  /// Latched the *moment* the delete button is tapped — before the confirm
  /// dialog even opens — and held through the async delete. Disables the
  /// delete button so a fast double-tap can't open two confirm dialogs or
  /// fire two cascade deletes against the same doc (the rapid-tap race Kelvin
  /// flagged on #51). Reset only if the user cancels the dialog, so they can
  /// retry; kept latched through a confirmed delete (the screen navigates
  /// away on success).
  bool _deleting = false;

  RsChipVariant _qaVariant(QaStatus status) => switch (status) {
        QaStatus.passed => RsChipVariant.success,
        QaStatus.failed => RsChipVariant.error,
        QaStatus.pendingQa => RsChipVariant.warning,
      };

  /// Two-step delete: confirmation dialog (named device + permanence warning),
  /// then [IncomingDeviceRepository.deleteIncoming]. On success, navigate
  /// back to the gallery — `canPop` fallback to `/` matches the home-or-pop
  /// idiom used elsewhere when this screen is the deep-link entry point.
  ///
  /// The `_deleting` latch is set SYNCHRONOUSLY here, at tap time, before the
  /// first `await`. That closes the rapid-tap window: between this call and
  /// the dialog resolving, a second tap finds `onPressed == null` (the button
  /// is already disabled) and is a no-op, so we can never stack two confirm
  /// dialogs or fire `deleteIncoming` twice.
  Future<void> _confirmDelete() async {
    final device = widget.device;
    setState(() => _deleting = true);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete the ${device.brand} ${device.model}?'),
        content: const Text(
          'This permanently removes the device record and all its photos. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) {
      // Cancelled (or dismissed) — unlatch so the volunteer can retry.
      if (mounted) setState(() => _deleting = false);
      return;
    }
    await _delete();
  }

  Future<void> _delete() async {
    // _deleting is already latched by _confirmDelete at tap time; no need to
    // set it again here.
    // Capture pre-await handles — context becomes invalid the moment we
    // navigate (the doc stream emits null and the parent rebuilds).
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final repo = ref.read(incomingDeviceRepositoryProvider);
    try {
      await repo.deleteIncoming(widget.device.id);
      // Home-or-pop: this screen may be the entry route on a deep-link wake,
      // in which case canPop() is false and we land on the gallery root.
      if (router.canPop()) {
        router.pop();
      } else {
        router.go('/');
      }
    } on FirebaseException catch (e) {
      if (mounted) setState(() => _deleting = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(PersistErrorKind.fromCode(e.code).userMessage),
          backgroundColor: AppColors.error,
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _deleting = false);
      messenger.showSnackBar(
        SnackBar(
          content: Text(PersistErrorKind.unknown.userMessage),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final device = widget.device;
    return Scaffold(
      appBar: AppBar(
        leading: _homeOrPopButton(context),
        title: Text('${device.brand} ${device.model}'),
        actions: [
          RsChip(
            label: device.qaStatus.wire.replaceAll('_', ' ').toUpperCase(),
            variant: _qaVariant(device.qaStatus),
          ),
          IconButton(
            tooltip: 'Delete device',
            icon: const Icon(Icons.delete_outline),
            // While a delete is in flight the handler is null so the
            // material ripple visibly disables — clearer than an enabled
            // button that silently no-ops.
            onPressed: _deleting ? null : _confirmDelete,
          ),
          const SizedBox(width: 8),
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
                  RsSpecRow(label: 'Type', value: device.type.label),
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
                  RsSpecRow(label: 'Battery', value: device.batterySize.label),
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
