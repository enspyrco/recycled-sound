// Dev-only preview of [UploadProgressScreen] — run it to SEE the upload UI
// (per-photo bars filling, the success flash, the auto-advance to the scanner)
// WITHOUT walking the 14-photo capture flow on a device:
//
//   flutter run -d chrome -t lib/features/capture/presentation/upload_progress_preview.dart
//
// It overrides [uploadJobProvider] with a controller that *simulates* an upload
// on a timer, so no camera, Firebase, or real network is involved.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/upload_job.dart';
import 'capture_slot.dart';
import 'upload_progress_screen.dart';

void main() {
  runApp(
    ProviderScope(
      overrides: [
        uploadJobProvider.overrideWith((ref) => _PreviewUploadController(ref)),
      ],
      child: const _PreviewApp(),
    ),
  );
}

class _PreviewApp extends StatelessWidget {
  const _PreviewApp();

  @override
  Widget build(BuildContext context) {
    final router = GoRouter(
      initialLocation: '/capture/uploading',
      routes: [
        GoRoute(
          path: '/capture/uploading',
          builder: (_, _) => const UploadProgressScreen(),
        ),
        GoRoute(
          path: '/scan',
          builder: (_, _) => Scaffold(
            appBar: AppBar(title: const Text('Scanner (preview stub)')),
            body: const Center(
              child: Text('Auto-navigated here after a successful upload.'),
            ),
          ),
        ),
      ],
    );
    return MaterialApp.router(routerConfig: router, debugShowCheckedModeBanner: false);
  }
}

/// Animates a fake 14-photo upload so the screen can be evaluated in isolation.
/// Extends the real controller (so the provider type matches) but never touches
/// the repo: [start] is replaced by [_simulate], and [retry] restarts the sim.
class _PreviewUploadController extends UploadJobController {
  _PreviewUploadController(super.ref) {
    _simulate();
  }

  static const _perPhoto = 1300000; // ~1.3MB, like a real 1080p still
  static const _step = 450000; // bytes added per active photo per tick
  Timer? _timer;

  List<String> get _keys => [
        for (final s in CaptureSlot.pairSequence) '${s.side.name}_${s.slot.name}',
      ];

  void _simulate() {
    _timer?.cancel();
    state = UploadJob(
      phase: UploadPhase.uploading,
      box: 'B07',
      photos: [for (final k in _keys) PhotoProgress(key: k, total: _perPhoto)],
    );
    _timer = Timer.periodic(const Duration(milliseconds: 180), (t) {
      final cur = state;
      if (cur == null) {
        t.cancel();
        return;
      }
      // Advance up to two not-yet-done photos (matches the plugin's ~2-at-a-time
      // upload concurrency) so the count ticks up in pairs.
      var budget = 2;
      final next = <PhotoProgress>[];
      var allDone = true;
      for (final p in cur.photos) {
        if (p.done) {
          next.add(p);
          continue;
        }
        if (budget > 0) {
          final sent = (p.transferred + _step).clamp(0, _perPhoto);
          final done = sent >= _perPhoto;
          next.add(p.copyWith(transferred: sent, done: done));
          if (!done) allDone = false;
          budget--;
        } else {
          next.add(p);
          allDone = false;
        }
      }
      if (allDone) {
        t.cancel();
        state = cur.copyWith(phase: UploadPhase.success, deviceId: 'preview', photos: next);
      } else {
        state = cur.copyWith(photos: next);
      }
    });
  }

  @override
  Future<void> retry() async => _simulate();

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
