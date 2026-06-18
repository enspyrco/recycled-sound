import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/clinical_field.dart';

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
    this.needsInputFields = const [],
  });

  final String brand;
  final String model;
  final String box;

  /// Identity fields a volunteer deliberately flagged Unknown on the confirm
  /// screen (e.g. `[ClinicalField.model]` for a Signia whose model isn't
  /// legible). Carried so the created device records the volunteer→audiologist
  /// handoff in `needsInputFields`, not just the bare `'Unknown'` value string
  /// (which alone can't be told apart from an AI read failure — see
  /// `feedback_provenance_not_value`). The clinical fields beyond identity are
  /// still NOT carried across this seam (task #14/#73).
  final List<ClinicalField> needsInputFields;
}

/// Set by the scanner-confirm flow before routing to `/capture` for a novel
/// device; `null` for a standalone capture entered directly from home.
final captureSeedProvider = StateProvider<CaptureSeed?>((ref) => null);
