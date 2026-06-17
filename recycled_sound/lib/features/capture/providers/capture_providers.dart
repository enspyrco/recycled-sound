import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Slot-name → local file path for photos taken in CaptureScreen.
///
/// Written by CaptureScreen._save() before routing to /scan/confirm.
/// Read by ConfirmationScreen to show the photo strip and pass to createIncoming().
/// Cleared by ConfirmationScreen after createIncoming() succeeds.
final capturedPhotosProvider =
    StateProvider<Map<String, String>>((ref) => const {});
