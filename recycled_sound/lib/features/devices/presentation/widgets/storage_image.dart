import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';

/// Renders an image stored in Firebase Storage, given the reference string
/// held in a device's `photos` array.
///
/// The stored value is either a `gs://` URI (capture/intake uploads) or an
/// https download URL (older scan path) — [FirebaseStorage.refFromURL] accepts
/// both, so we resolve to a download URL and hand it to [Image.network]. A
/// raw https URL could be passed straight through, but resolving uniformly
/// keeps one code path and survives bucket/token changes.
class StorageImage extends StatelessWidget {
  const StorageImage({
    super.key,
    required this.photoRef,
    this.fit = BoxFit.cover,
  });

  final String photoRef;
  final BoxFit fit;

  Future<String> _resolve() =>
      FirebaseStorage.instance.refFromURL(photoRef).getDownloadURL();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _resolve(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const ColoredBox(
            color: AppColors.primaryLight,
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        if (snap.hasError || !snap.hasData) {
          return const ColoredBox(
            color: AppColors.primaryLight,
            child: Center(
              child: Icon(Icons.broken_image, color: AppColors.textMuted),
            ),
          );
        }
        return Image.network(snap.data!, fit: fit);
      },
    );
  }
}
