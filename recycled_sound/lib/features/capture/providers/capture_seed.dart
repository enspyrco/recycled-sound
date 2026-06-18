import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Identity carried from the scanner into the capture flow when a NOVEL device
/// needs its reference photo set.
///
/// In the scanner-first flow the scanner has already read brand/model and the
/// volunteer has entered the box number; if the register has no reference set
/// for that model, the confirm screen seeds this and routes to `/capture`. The
/// capture screen pre-fills from it (so the volunteer just shoots) and clears
/// it on consumption.
class CaptureSeed {
  const CaptureSeed({
    required this.brand,
    required this.model,
    required this.box,
  });

  final String brand;
  final String model;
  final String box;
}

/// Set by the scanner-confirm flow before routing to `/capture` for a novel
/// device; `null` for a standalone capture entered directly from home.
final captureSeedProvider = StateProvider<CaptureSeed?>((ref) => null);
