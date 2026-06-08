import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../data/incoming_device_repository.dart';
import '../providers/device_providers.dart';
import 'widgets/storage_image.dart';

/// Full-screen, zoomable view of one device photo, with a delete action.
///
/// Delete removes the photo from the device's `photos` array (and best-effort
/// from Storage) via [IncomingDeviceRepository.deletePhoto], then pops back to
/// the detail screen, whose gallery — streaming the doc — drops the thumbnail.
class PhotoDetailScreen extends ConsumerStatefulWidget {
  const PhotoDetailScreen({
    super.key,
    required this.deviceId,
    required this.photoRef,
  });

  final String deviceId;
  final String photoRef;

  @override
  ConsumerState<PhotoDetailScreen> createState() => _PhotoDetailScreenState();
}

class _PhotoDetailScreenState extends ConsumerState<PhotoDetailScreen> {
  bool _deleting = false;

  Future<void> _confirmDelete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete photo?'),
        content: const Text('This removes the photo from the device record.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _delete();
  }

  Future<void> _delete() async {
    setState(() => _deleting = true);
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final repo = ref.read(incomingDeviceRepositoryProvider);
    try {
      await repo.deletePhoto(widget.deviceId, widget.photoRef);
      router.pop();
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
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (_deleting)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: _confirmDelete,
            ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 1,
          maxScale: 5,
          child: Hero(
            tag: widget.photoRef,
            child: StorageImage(photoRef: widget.photoRef, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}
