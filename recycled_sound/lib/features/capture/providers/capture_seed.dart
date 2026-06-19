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
    this.colour = '',
    this.needsInputFields = const [],
  });

  final String brand;
  final String model;
  final String box;

  /// Device colour confirmed on the scan-confirm screen (the single place
  /// colour is collected). Carried into capture so the created device's colour
  /// matches what the volunteer just confirmed; empty for a standalone capture
  /// (no confirm screen) — the audiologist sets it later.
  final String colour;

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

/// The box number the volunteer enters in the box-first modal dialog when
/// they tap a home button (Scan or Capture) — the FIRST thing they do, and the
/// ONLY place a box number is entered. Read by the confirm screen (to seed the
/// created device's `location`) and by a standalone capture (entered directly
/// from home, with no scanner/confirm in between). Defaults to '' and is set by
/// the modal before navigation.
final scanBoxProvider = StateProvider<String>((ref) => '');
