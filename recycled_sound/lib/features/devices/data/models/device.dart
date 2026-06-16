import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:recycled_sound/core/clinical_field.dart';

export 'package:recycled_sound/core/clinical_field.dart' show ClinicalField;

/// QA gate state for a hearing aid. The set is closed: stringly-typing it
/// would let a typo silently fall through the chip-variant switch.
enum QaStatus {
  pendingQa('pending_qa'),
  passed('passed'),
  failed('failed');

  const QaStatus(this.wire);

  /// The on-the-wire string value persisted in Firestore.
  final String wire;

  /// Parse the wire form; defaults to [pendingQa] for unknown/empty input
  /// (handles legacy docs and forward-compat with new variants).
  static QaStatus fromWire(String? s) => switch (s) {
    'passed' => passed,
    'failed' => failed,
    _ => pendingQa,
  };
}

/// Lifecycle status for a hearing aid in the redistribution pipeline.
enum DeviceStatus {
  donated('donated'),
  reprogramming('reprogramming'),
  servicing('servicing'),
  ready('ready'),
  matched('matched'),
  shipped('shipped'),
  delivered('delivered'),
  active('active');

  const DeviceStatus(this.wire);

  final String wire;

  static DeviceStatus fromWire(String? s) => switch (s) {
    'reprogramming' => reprogramming,
    'servicing' => servicing,
    'ready' => ready,
    'matched' => matched,
    'shipped' => shipped,
    'delivered' => delivered,
    'active' => active,
    _ => donated,
  };
}

/// Tubing type — Seray's clinical field 4. Closed set; human-determined at
/// confirm time. [unspecified] is the "not yet determined" state and serializes
/// to the empty string, preserving the model's empty-default convention (and
/// absorbing the legacy `'Unknown'` provenance flag, which was never a real
/// tubing value — the "needs input" signal lives in [Device.needsInputFields],
/// not in this value. See feedback_provenance_not_value).
enum Tubing {
  unspecified(''),
  slim('Slim'),
  standard('Standard'),
  none('None');

  const Tubing(this.wire);

  /// The on-the-wire string — the exact values the confirm-screen chip selector
  /// and DeviceIndex already emit (`'Slim'`/`'Standard'`/`'None'`), so existing
  /// Firestore docs and the scanner contract round-trip unchanged.
  final String wire;

  /// Parse the wire form; any unrecognized/empty/legacy value (including the
  /// `'Unknown'` provenance sentinel) falls back to [unspecified]. Never throws.
  static Tubing fromWire(String? s) => switch (s) {
    'Slim' => slim,
    'Standard' => standard,
    'None' => none,
    _ => unspecified,
  };
}

/// Power source — Seray's clinical field 5. Closed set; human-confirmed.
/// [unspecified] is the "not yet determined" state and serializes to the empty
/// string (same empty-default convention as [Tubing]).
enum PowerSource {
  unspecified(''),
  battery('Battery'),
  rechargeable('Rechargeable');

  const PowerSource(this.wire);

  /// The on-the-wire string — matches the confirm-screen chip values and
  /// DeviceIndex's derived `'Battery'`/`'Rechargeable'`.
  final String wire;

  /// Parse the wire form; unrecognized/empty/legacy → [unspecified]. Never throws.
  static PowerSource fromWire(String? s) => switch (s) {
    'Battery' => battery,
    'Rechargeable' => rechargeable,
    _ => unspecified,
  };
}

/// An as-yet-unpersisted device — the scanner's confirmation output before it
/// has a Firestore document id.
///
/// This is the "boundary between two truths" made unrepresentable: a device
/// the audiologist has confirmed but that has *no* persisted identity yet. The
/// old code modelled this with `Device(id: '')`, an empty-string sentinel that
/// lies at the type level — every `Device` in the system claims to have an id,
/// but that one didn't. [DraftDevice] has no `id` field at all, so the
/// "draft without identity" state is expressible only through this type, and
/// the only way to obtain a [Device] from it is [toDevice], which *requires*
/// the id Firestore allocated.
///
/// The field set mirrors [Device] minus `id`, `createdAt`, and `updatedAt`
/// (the persistence layer owns those).
class DraftDevice {
  const DraftDevice({
    required this.brand,
    required this.model,
    this.type = '',
    this.year = '',
    this.serialLeft = '',
    this.serialRight = '',
    this.batterySize = '',
    this.tubing = Tubing.unspecified,
    this.powerSource = PowerSource.unspecified,
    this.colour = '',
    this.domeType = '',
    this.waxFilter = '',
    this.receiver = '',
    this.programmingInterface = '',
    this.techLevel = '',
    this.gainRange = '',
    this.fittingRange = '',
    this.remoteFT = false,
    this.appCompatible = false,
    this.auracast = false,
    this.chargerType = '',
    this.accessories = const [],
    this.condition = '',
    this.qaStatus = QaStatus.pendingQa,
    this.status = DeviceStatus.donated,
    this.servicingNotes = '',
    this.servicingCost = 0,
    this.donorId = '',
    this.scanId = '',
    this.location = '',
    this.photos = const [],
    this.needsInputFields = const [],
  });

  final String brand;
  final String model;
  final String type;
  final String year;
  final String serialLeft;
  final String serialRight;
  final String batterySize;

  /// Tubing type — Seray's clinical field 4. Human-determined at confirm time;
  /// [Tubing.unspecified] until acknowledged.
  final Tubing tubing;

  /// Power source — Seray's clinical field 5. Human-confirmed.
  final PowerSource powerSource;

  /// Device colour — Seray's field 7. Confirmed against brand/generic swatches.
  final String colour;

  final String domeType;
  final String waxFilter;
  final String receiver;
  final String programmingInterface;
  final String techLevel;
  final String gainRange;
  final String fittingRange;
  final bool remoteFT;
  final bool appCompatible;
  final bool auracast;
  final String chargerType;
  final List<String> accessories;
  final String condition;
  final QaStatus qaStatus;
  final DeviceStatus status;
  final String servicingNotes;
  final double servicingCost;
  final String donorId;
  final String scanId;

  /// Physical storage location — the box/bag the device lives in (e.g. `B07`,
  /// `C10`). Free text, not a constrained set: the storage layout evolves and
  /// new bins appear faster than an enum could track. Uppercased/trimmed on
  /// save. Metadata, not one of the 7 clinical fields — never gates completion.
  final String location;

  final List<String> photos;

  /// The 7-field scan-model fields the volunteer flagged as undetermined, asking
  /// the audiologist to determine them (e.g. `[ClinicalField.tubing,
  /// ClinicalField.colour]`). A structured, *typed* handoff — not magic strings
  /// re-derived from an overloaded value — see [ScanResult.volunteerUnknownFields].
  final List<ClinicalField> needsInputFields;

  /// Promote this draft to a persisted [Device], pinning the Firestore-issued
  /// [id]. Optionally overrides [photos] (used after photo upload resolves the
  /// final gs:// URIs). This is the one-way DraftDevice→Device boundary.
  Device toDevice({required String id, List<String>? photos}) => Device(
    id: id,
    brand: brand,
    model: model,
    type: type,
    year: year,
    serialLeft: serialLeft,
    serialRight: serialRight,
    batterySize: batterySize,
    tubing: tubing,
    powerSource: powerSource,
    colour: colour,
    domeType: domeType,
    waxFilter: waxFilter,
    receiver: receiver,
    programmingInterface: programmingInterface,
    techLevel: techLevel,
    gainRange: gainRange,
    fittingRange: fittingRange,
    remoteFT: remoteFT,
    appCompatible: appCompatible,
    auracast: auracast,
    chargerType: chargerType,
    accessories: accessories,
    condition: condition,
    qaStatus: qaStatus,
    status: status,
    servicingNotes: servicingNotes,
    servicingCost: servicingCost,
    donorId: donorId,
    scanId: scanId,
    location: location,
    photos: photos ?? this.photos,
    needsInputFields: needsInputFields,
  );
}

/// 26-field device model matching the Recycled Sound device register.
///
/// Persisted in two Firestore collections with identical shape:
/// - `incoming/{id}` — scanner write-target, pre-triage
/// - `devices/{id}` — audiologist-curated register, post-triage
class Device {
  const Device({
    required this.id,
    required this.brand,
    required this.model,
    this.type = '',
    this.year = '',
    this.serialLeft = '',
    this.serialRight = '',
    this.batterySize = '',
    this.tubing = Tubing.unspecified,
    this.powerSource = PowerSource.unspecified,
    this.colour = '',
    this.domeType = '',
    this.waxFilter = '',
    this.receiver = '',
    this.programmingInterface = '',
    this.techLevel = '',
    this.gainRange = '',
    this.fittingRange = '',
    this.remoteFT = false,
    this.appCompatible = false,
    this.auracast = false,
    this.chargerType = '',
    this.accessories = const [],
    this.condition = '',
    this.qaStatus = QaStatus.pendingQa,
    this.status = DeviceStatus.donated,
    this.servicingNotes = '',
    this.servicingCost = 0,
    this.donorId = '',
    this.scanId = '',
    this.location = '',
    this.photos = const [],
    this.needsInputFields = const [],
    this.unrecognisedNeedsInput = const [],
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String brand;
  final String model;
  final String type;
  final String year;
  final String serialLeft;
  final String serialRight;
  final String batterySize;

  /// Tubing type — Seray's clinical field 4. Human-determined.
  final Tubing tubing;

  /// Power source — Seray's clinical field 5. Human-confirmed.
  final PowerSource powerSource;

  /// Device colour — Seray's field 7. Confirmed against brand/generic swatches.
  final String colour;

  final String domeType;
  final String waxFilter;
  final String receiver;
  final String programmingInterface;
  final String techLevel;
  final String gainRange;
  final String fittingRange;
  final bool remoteFT;
  final bool appCompatible;
  final bool auracast;
  final String chargerType;
  final List<String> accessories;
  final String condition;
  final QaStatus qaStatus;
  final DeviceStatus status;
  final String servicingNotes;
  final double servicingCost;
  final String donorId;
  final String scanId;

  /// Physical storage location — the box/bag the device lives in (e.g. `B07`,
  /// `C10`). Free text, not a constrained set. Uppercased/trimmed on save.
  /// Metadata, not one of the 7 clinical fields — never gates completion.
  final String location;

  final List<String> photos;

  /// The 7-field scan-model fields the volunteer flagged as undetermined at
  /// scan-confirm time (the amber escape valve), persisted as a structured,
  /// *typed* handoff to the audiologist. See [DraftDevice.needsInputFields].
  final List<ClinicalField> needsInputFields;

  /// Raw `needsInputFields` wire keys that did NOT map to a [ClinicalField]
  /// (legacy keys, typos, future-version values). Retained — not dropped — so
  /// the promotion gate can fail CLOSED on an unresolved blocker it can't name
  /// (see [ClinicalField.partition]). Round-trips back to Firestore alongside
  /// the typed keys so a tolerant read never silently destroys data on save.
  /// Almost always empty for app-written docs (the writer only emits real keys).
  final List<String> unrecognisedNeedsInput;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// How many fields the volunteer flagged for the audiologist to determine.
  /// Reads the persisted [needsInputFields] set rather than string-matching
  /// `'Unknown'` against value fields — the AI pipeline emits `'Unknown'` as
  /// its own low-confidence default, so a value-match would raise false flags
  /// for fields the volunteer never touched. Surfaced as the register's
  /// "NEEDS INPUT" chip.
  int get unknownFieldCount =>
      needsInputFields.length + unrecognisedNeedsInput.length;

  /// Build a [Device] from a Firestore document snapshot.
  ///
  /// The document `id` is taken from the snapshot, not from a `id` field
  /// in the data — Firestore document IDs are the canonical identifier.
  factory Device.fromFirestore(DocumentSnapshot<Map<String, dynamic>> snap) {
    final d = snap.data() ?? const <String, dynamic>{};
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;
    // Partition (not drop) unknown keys so the promotion gate fails closed on a
    // blocker it can't name; both buckets round-trip back to Firestore below.
    final needsInput = ClinicalField.partition(d['needsInputFields']);
    return Device(
      id: snap.id,
      brand: (d['brand'] as String?) ?? '',
      model: (d['model'] as String?) ?? '',
      type: (d['type'] as String?) ?? '',
      year: (d['year'] as String?) ?? '',
      serialLeft: (d['serialLeft'] as String?) ?? '',
      serialRight: (d['serialRight'] as String?) ?? '',
      batterySize: (d['batterySize'] as String?) ?? '',
      tubing: Tubing.fromWire(d['tubing'] as String?),
      powerSource: PowerSource.fromWire(d['powerSource'] as String?),
      colour: (d['colour'] as String?) ?? '',
      domeType: (d['domeType'] as String?) ?? '',
      waxFilter: (d['waxFilter'] as String?) ?? '',
      receiver: (d['receiver'] as String?) ?? '',
      programmingInterface: (d['programmingInterface'] as String?) ?? '',
      techLevel: (d['techLevel'] as String?) ?? '',
      gainRange: (d['gainRange'] as String?) ?? '',
      fittingRange: (d['fittingRange'] as String?) ?? '',
      remoteFT: (d['remoteFT'] as bool?) ?? false,
      appCompatible: (d['appCompatible'] as bool?) ?? false,
      auracast: (d['auracast'] as bool?) ?? false,
      chargerType: (d['chargerType'] as String?) ?? '',
      accessories:
          ((d['accessories'] as List?)?.cast<String>()) ?? const <String>[],
      condition: (d['condition'] as String?) ?? '',
      qaStatus: QaStatus.fromWire(d['qaStatus'] as String?),
      status: DeviceStatus.fromWire(d['status'] as String?),
      servicingNotes: (d['servicingNotes'] as String?) ?? '',
      servicingCost: ((d['servicingCost'] as num?) ?? 0).toDouble(),
      donorId: (d['donorId'] as String?) ?? '',
      scanId: (d['scanId'] as String?) ?? '',
      location: (d['location'] as String?) ?? '',
      photos: ((d['photos'] as List?)?.cast<String>()) ?? const <String>[],
      needsInputFields: needsInput.known,
      unrecognisedNeedsInput: needsInput.unknown,
      createdAt: ts(d['createdAt']),
      updatedAt: ts(d['updatedAt']),
    );
  }

  /// Serialize for Firestore. Excludes [id] (lives in the doc key) and uses
  /// [FieldValue.serverTimestamp] for `createdAt`/`updatedAt` when null —
  /// callers that update existing docs should pass the existing values.
  ///
  /// [createdBy] is required: the `incoming/` rules pin
  /// `request.resource.data.createdBy == auth.uid` on create, and a missing
  /// value would silently fail at the rules layer with a permission-denied
  /// rather than a compile error.
  Map<String, dynamic> toFirestore({required String createdBy}) => {
    'brand': brand,
    'model': model,
    'type': type,
    'year': year,
    'serialLeft': serialLeft,
    'serialRight': serialRight,
    'batterySize': batterySize,
    'tubing': tubing.wire,
    'powerSource': powerSource.wire,
    'colour': colour,
    'domeType': domeType,
    'waxFilter': waxFilter,
    'receiver': receiver,
    'programmingInterface': programmingInterface,
    'techLevel': techLevel,
    'gainRange': gainRange,
    'fittingRange': fittingRange,
    'remoteFT': remoteFT,
    'appCompatible': appCompatible,
    'auracast': auracast,
    'chargerType': chargerType,
    'accessories': accessories,
    'condition': condition,
    'qaStatus': qaStatus.wire,
    'status': status.wire,
    'servicingNotes': servicingNotes,
    'servicingCost': servicingCost,
    'donorId': donorId,
    'scanId': scanId,
    'location': location,
    'photos': photos,
    // Typed keys + any retained unrecognised keys — so a tolerant read followed
    // by a write never silently destroys a blocker we couldn't interpret.
    'needsInputFields': [...needsInputFields.toWireList(), ...unrecognisedNeedsInput],
    'createdBy': createdBy,
    'createdAt': createdAt == null
        ? FieldValue.serverTimestamp()
        : Timestamp.fromDate(createdAt!),
    'updatedAt': FieldValue.serverTimestamp(),
  };

  /// Sample devices from the existing register for MVP display.
  static List<Device> mockDevices() => [
    const Device(
      id: '1',
      brand: 'Phonak',
      model: 'Audéo P90',
      type: 'RIC',
      year: '2021',
      batterySize: '312',
      qaStatus: QaStatus.passed,
      status: DeviceStatus.ready,
    ),
    const Device(
      id: '2',
      brand: 'Oticon',
      model: 'More 1',
      type: 'BTE',
      year: '2022',
      batterySize: '13',
      qaStatus: QaStatus.pendingQa,
      status: DeviceStatus.donated,
    ),
    const Device(
      id: '3',
      brand: 'Signia',
      model: 'Pure 7Nx',
      type: 'RIC',
      year: '2020',
      batterySize: '312',
      qaStatus: QaStatus.passed,
      status: DeviceStatus.matched,
    ),
    const Device(
      id: '4',
      brand: 'GN Resound',
      model: 'ONE 9',
      type: 'RIC',
      year: '2023',
      batterySize: 'Rechargeable',
      qaStatus: QaStatus.pendingQa,
      status: DeviceStatus.donated,
    ),
    const Device(
      id: '5',
      brand: 'Widex',
      model: 'Moment 440',
      type: 'RIC',
      year: '2021',
      batterySize: '10',
      qaStatus: QaStatus.failed,
      status: DeviceStatus.servicing,
    ),
  ];
}

/// The outcome of reviewing a device for promotion across the trust boundary
/// `incoming/` → `devices/` (the curated clinical register). A sealed type: the
/// compiler forces a caller that switches on it to handle BOTH arms, so once the
/// repository *consumes* this verdict (the enforcement flip in #777) there is no
/// way to write a device to `devices/` while it carries unresolved blockers
/// without explicitly handling [NeedsResolution].
///
/// SCOPE (PR #86): this type + [Promotion.reviewForPromotion] are defined and
/// tested, but `IncomingDeviceRepository.promoteToDevice` does NOT yet consume
/// them — it remains a raw `Map → Map` copy. So in #86 the verdict is the
/// *representation* of the invariant, not yet its *enforcement*; wiring it
/// (without deadlocking on read-only identity fields) is #777. The guarantee
/// above is conditional on that wiring — stated honestly rather than overclaimed
/// (Carnot, PR #86 cage-match).
///
/// See feedback_trust_boundary_needs_type_enforcement and feedback_review_
/// approves_compilation_not_purpose for why PR #85's vigilance-only gate was
/// bypassable three ways.
sealed class PromotionVerdict {
  const PromotionVerdict();
}

/// The device cleared the gate — no clinical field (recognised OR unrecognised)
/// remains flagged. [device] is ready to write into `devices/`. Obtainable ONLY
/// from [Promotion.reviewForPromotion], so its existence is proof the gate ran.
class Promotable extends PromotionVerdict {
  const Promotable(this.device);
  final Device device;
}

/// The device cannot be promoted. [unresolved] names the typed clinical fields
/// still awaiting audiologist input; [unrecognised] holds any persisted blocker
/// keys that did not map to a [ClinicalField] (legacy/typo/future) — they block
/// too, because a blocker we can't interpret is the LAST thing that should wave
/// a device through (fail closed). The caller must surface these, not promote.
/// (#777 adds the audited override escape valve and wires this into
/// `IncomingDeviceRepository.promoteToDevice`.)
class NeedsResolution extends PromotionVerdict {
  const NeedsResolution(this.unresolved, {this.unrecognised = const []});
  final List<ClinicalField> unresolved;
  final List<String> unrecognised;
}

extension Promotion on Device {
  /// Pure domain gate for the `incoming/` → `devices/` trust boundary. Returns
  /// [Promotable] only when there are NO blockers at all — no recognised
  /// [needsInputFields] AND no [unrecognisedNeedsInput]; otherwise
  /// [NeedsResolution] naming what blocks promotion. Failing closed on
  /// unrecognised keys is deliberate: dropping a blocker we can't name would
  /// fail OPEN at the exact boundary this gate exists to protect.
  ///
  /// Note: this reads the *persisted* blocker set. A field counts as resolved
  /// once the audiologist's edit removes it from that set on the incoming doc —
  /// which the review screen does not yet do for identity fields (that
  /// resolution path is #777). Until #777 wires this into the repository, the
  /// gate is defined and tested but not yet enforced.
  PromotionVerdict reviewForPromotion() =>
      needsInputFields.isEmpty && unrecognisedNeedsInput.isEmpty
          ? Promotable(this)
          : NeedsResolution(needsInputFields,
              unrecognised: unrecognisedNeedsInput);
}
