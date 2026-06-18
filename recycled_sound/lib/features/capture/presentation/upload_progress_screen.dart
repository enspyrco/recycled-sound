import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_typography.dart';
import '../providers/upload_job.dart';
import 'capture_slot.dart';

/// Full-screen progress for a device's photo upload.
///
/// Reached via `context.go('/capture/uploading')` after [UploadJobController.start]
/// has been kicked off — the upload runs in the provider, so this screen only
/// *observes* it and the camera screen behind it is free to dispose. On success
/// it holds on a "Saved" state with a "Scan next device" button (no
/// auto-navigate — the volunteer advances when ready); on failure it offers a
/// retry that reuses the captured photos. If there is no job (deep link,
/// browser back, hot restart, or a return after `clear()`), it redirects to
/// `/scan` rather than stranding the user on a blank screen.
class UploadProgressScreen extends ConsumerStatefulWidget {
  const UploadProgressScreen({super.key});

  @override
  ConsumerState<UploadProgressScreen> createState() =>
      _UploadProgressScreenState();
}

class _UploadProgressScreenState extends ConsumerState<UploadProgressScreen> {
  // One-shot guard: navigate-and-clear (or the no-job redirect) must run
  // exactly once even though build() can run many times.
  bool _navigated = false;

  void _goToNext() {
    if (_navigated) return;
    _navigated = true;
    // Clear AFTER the frame so the provider isn't mutated mid-build, and the
    // success flash stays painted until the route actually changes.
    final router = GoRouter.of(context);
    ref.read(uploadJobProvider.notifier).clear();
    router.go('/scan');
  }

  @override
  Widget build(BuildContext context) {
    // No auto-navigate: on success the volunteer stays here and taps
    // "Scan next device" when ready (the footer button calls _goToNext).
    final job = ref.watch(uploadJobProvider);

    // No job (deep link, browser back, hot restart, or a return after the job
    // was cleared) — redirect to the scanner rather than stranding the user on
    // a blank screen. Navigation can't run during build, so schedule it for
    // after this frame; the empty scaffold shows for that single frame only.
    if (job == null) {
      if (!_navigated) {
        _navigated = true;
        final router = GoRouter.of(context);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) router.go('/scan');
        });
      }
      return const Scaffold(backgroundColor: AppColors.background);
    }

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              _Header(job: job),
              const SizedBox(height: 20),
              Expanded(child: _PhotoList(job: job)),
              const SizedBox(height: 16),
              _Footer(
                job: job,
                onRetry: () => ref.read(uploadJobProvider.notifier).retry(),
                onContinue: _goToNext,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.job});

  final UploadJob job;

  @override
  Widget build(BuildContext context) {
    final (title, colour) = switch (job.phase) {
      UploadPhase.uploading => ('Saving box ${job.box}', AppColors.primary),
      UploadPhase.success => ('Saved box ${job.box}', AppColors.success),
      UploadPhase.error => ('Upload failed', AppColors.error),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              switch (job.phase) {
                UploadPhase.uploading => Icons.cloud_upload_outlined,
                UploadPhase.success => Icons.check_circle,
                UploadPhase.error => Icons.error_outline,
              },
              color: colour,
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(title, style: AppTypography.h3)),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: job.overall,
            minHeight: 8,
            backgroundColor: AppColors.surface,
            valueColor: AlwaysStoppedAnimation(colour),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${job.completed} of ${job.total} photos uploaded',
          style: AppTypography.caption,
        ),
      ],
    );
  }
}

class _PhotoList extends StatelessWidget {
  const _PhotoList({required this.job});

  final UploadJob job;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: job.photos.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final p = job.photos[i];
        return Row(
          children: [
            SizedBox(
              width: 22,
              child: Icon(
                p.done ? Icons.check : Icons.radio_button_unchecked,
                size: 18,
                color: p.done ? AppColors.success : AppColors.border,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_labelFor(p.key), style: AppTypography.body),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: p.fraction,
                      minHeight: 4,
                      backgroundColor: AppColors.surface,
                      valueColor: const AlwaysStoppedAnimation(
                        AppColors.primary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.job,
    required this.onRetry,
    required this.onContinue,
  });

  final UploadJob job;
  final VoidCallback onRetry;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return switch (job.phase) {
      UploadPhase.uploading => Text(
          'Keep the app open — uploading the photos.',
          textAlign: TextAlign.center,
          style: AppTypography.caption,
        ),
      UploadPhase.success => FilledButton(
          onPressed: onContinue,
          child: const Text('Scan next device'),
        ),
      UploadPhase.error => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (job.errorMessage != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  job.errorMessage!,
                  textAlign: TextAlign.center,
                  style: AppTypography.caption.copyWith(color: AppColors.error),
                ),
              ),
            FilledButton(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
    };
  }
}

/// Format a storage key (`left_medial`, `right_scale`, or a positional `0`)
/// into a volunteer-readable label ("Left · Brand & model").
String _labelFor(String key) {
  final parts = key.split('_');
  if (parts.length == 2) {
    final side = AidSide.values.where((s) => s.name == parts[0]).firstOrNull;
    final slot =
        CaptureSlot.values.where((s) => s.name == parts[1]).firstOrNull;
    if (side != null && slot != null) return '${side.label} · ${slot.title}';
  }
  return 'Photo $key';
}
