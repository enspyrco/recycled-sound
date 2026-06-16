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

  /// Parse a persisted list into the typed fields it recognizes, dropping
  /// anything unrecognized. Order-preserving, never throws. This is the
  /// **display-tolerant** view — use it where an unknown key is genuinely
  /// harmless (a banner that shows what it understands). For the trust boundary,
  /// use [partition], which RETAINS the unknown keys so the gate can fail closed.
  static List<ClinicalField> parseList(Object? raw) => partition(raw).known;

  /// Parse a persisted list into recognized [known] fields AND the raw [unknown]
  /// wire keys that did not map to any [ClinicalField]. Order-preserving within
  /// each bucket; never throws.
  ///
  /// **Why retain the unknowns.** Silently dropping a key is the right move for
  /// display tolerance but the WRONG thermodynamic sign at a trust boundary
  /// (Carnot, PR #86 cage-match): a persisted `needsInputFields` entry we can't
  /// even name is still an *unresolved blocker*. If we drop it, a downstream
  /// promotion gate sees an empty list and waves the device through — fail-open
  /// at exactly the boundary the type exists to protect. Keeping the unknown
  /// keys lets the gate fail CLOSED on a blocker it can't interpret. A non-string
  /// entry (a number, null) is recorded as its `toString()` so it still blocks
  /// rather than vanishing.
  static ({List<ClinicalField> known, List<String> unknown}) partition(
    Object? raw,
  ) {
    if (raw is! List) return (known: const [], unknown: const []);
    final known = <ClinicalField>[];
    final unknown = <String>[];
    for (final e in raw) {
      final field = fromWire(e is String ? e : null);
      if (field != null) {
        known.add(field);
      } else {
        unknown.add(e?.toString() ?? 'null');
      }
    }
    return (known: known, unknown: unknown);
  }
}

/// Serialize a typed field list back to the wire strings Firestore stores.
/// The inverse of [ClinicalField.parseList]; the round-trip is identity for any
/// list of real fields.
extension ClinicalFieldWireList on List<ClinicalField> {
  List<String> toWireList() => map((f) => f.wire).toList();
}
