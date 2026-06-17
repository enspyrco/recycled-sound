import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_typography.dart';

/// Lists the sweep-video clips on a device (the `videos` field), so an
/// audiologist reviewing an incoming or curated device can actually SEE the
/// captured evidence — a sweep-only capture would otherwise present a record
/// with no visible media (cage-match PR #97, Carnot P1).
///
/// The clips are stored as `gs://` URIs (or https URLs) at
/// `captures/{uid}/{deviceId}/sweep_{ts}.mp4`. The app has no in-app video
/// player dependency yet, so tapping a clip resolves a time-limited, playable
/// **download URL** ([FirebaseStorage.refFromURL].getDownloadURL — same
/// resolution as [StorageImage]) and presents it in a dialog the reviewer can
/// copy into a browser/player. A proper in-app player is a tracked follow-up;
/// the bar this widget meets is "the evidence is visible and retrievable",
/// not "playable in place".
class SweepVideoList extends StatelessWidget {
  const SweepVideoList({super.key, required this.videos});

  /// gs:// URIs (or https URLs) of the sweep clips, in capture order.
  final List<String> videos;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < videos.length; i++)
          _SweepVideoTile(videoRef: videos[i], label: 'Sweep video ${i + 1}'),
      ],
    );
  }
}

class _SweepVideoTile extends StatelessWidget {
  const _SweepVideoTile({required this.videoRef, required this.label});

  final String videoRef;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: const Icon(Icons.play_circle_outline, color: AppColors.accent),
        title: Text(label, style: AppTypography.body),
        subtitle: Text('Tap to get a playable link',
            style: AppTypography.caption.copyWith(color: AppColors.textMuted)),
        trailing: const Icon(Icons.open_in_new, size: 18),
        onTap: () => _showLink(context),
      ),
    );
  }

  void _showLink(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(label),
        content: FutureBuilder<String>(
          future: FirebaseStorage.instance.refFromURL(videoRef).getDownloadURL(),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 64,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snap.hasError || !snap.hasData) {
              return Text(
                "Couldn't load this clip's link. It may still be uploading.",
                style: AppTypography.body,
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Open this link to play the sweep:',
                    style: AppTypography.caption),
                const SizedBox(height: 8),
                SelectableText(snap.data!, style: AppTypography.caption),
              ],
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
