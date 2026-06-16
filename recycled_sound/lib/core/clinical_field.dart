/// The closed seven-field clinical vocabulary Seray's audiologist model requires
/// per device: Make, Model, Style, Tubing, Power, Battery Size, Colour.
///
/// This is deliberately its OWN type, not a reuse of [ScanField] (the scanner's
/// 11-value internal enum, which also carries year/domeType/waxFilter/receiver —
/// fields that never gate clinical promotion). The closed set is *exactly* these
/// seven, and modelling it as a type makes "is this a clinical field?" and
/// "which fields are unresolved?" compile-time facts rather than string matches
/// scattered across the scan result, the device model, and the review screen.
///
/// **Why a type, not `List<String>`.** The vocabulary was previously stringly-
/// typed (`needsInputFields: List<String>`, matched as magic `'tubing'` / `'colour'`
/// literals in multiple files). PR #85's review screen had to re-declare a
/// key→label map and *invented keys* (`'make'`/`'style'`/`'battery'`) that don't
/// match the real wire vocabulary — exactly the failure mode a closed type
/// prevents. All three cage-match reviewers converged on "this wants to be a type"
/// (see feedback_trust_boundary_needs_type_enforcement).
///
/// **Wire format is unchanged.** [wire] is the exact string already persisted in
/// Firestore (`brand`/`model`/`type`/`tubing`/`powerSource`/`batterySize`/`colour`),
/// so existing `incoming/` and `devices/` docs round-trip untouched. Parsing is
/// tolerant — unknown/legacy/garbage keys are dropped, never thrown on — mirroring
/// the [Tubing]/[PowerSource]/[QaStatus] `fromWire` pattern.
enum ClinicalField {
  brand('brand', 'Make'),
  model('model', 'Model'),
  type('type', 'Style'),
  tubing('tubing', 'Tubing'),
  powerSource('powerSource', 'Power'),
  batterySize('batterySize', 'Battery Size'),
  colour('colour', 'Colour');

  const ClinicalField(this.wire, this.label);

  /// The on-the-wire string persisted in Firestore — unchanged from the legacy
  /// `List<String>` keys, so this enum round-trips existing documents exactly.
  final String wire;

  /// The audiologist-facing display name (e.g. "Make", "Battery Size"). The
  /// single source of truth for these labels — replaces the hand-rolled
  /// `_labels` map the review banner used to maintain in parallel.
  final String label;

  /// Parse a single wire string. Unknown/empty/legacy input returns `null`
  /// (the field is dropped, not promoted to a bogus value). Never throws.
  static ClinicalField? fromWire(String? s) => switch (s) {
    'brand' => brand,
    'model' => model,
    'type' => type,
    'tubing' => tubing,
    'powerSource' => powerSource,
    'batterySize' => batterySize,
    'colour' => colour,
    _ => null,
  };

  /// Parse a persisted list (a Firestore `List<dynamic>` or `null`) into typed
  /// fields, silently dropping any unrecognized/garbage entry. Order-preserving.
  /// Never throws — a malformed `needsInputFields` array degrades to the fields
  /// it *can* understand rather than crashing the register or the review queue.
  static List<ClinicalField> parseList(Object? raw) => switch (raw) {
    final List<dynamic> l =>
      l.map((e) => fromWire(e is String ? e : null)).whereType<ClinicalField>().toList(),
    _ => const [],
  };
}

/// Serialize a typed field list back to the wire strings Firestore stores.
/// The inverse of [ClinicalField.parseList]; the round-trip is identity for any
/// list of real fields.
extension ClinicalFieldWireList on List<ClinicalField> {
  List<String> toWireList() => map((f) => f.wire).toList();
}
