import 'package:cloud_firestore/cloud_firestore.dart';

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
    this.photos = const [],
  });

  final String brand;
  final String model;
  final String type;
  final String year;
  final String serialLeft;
  final String serialRight;
  final String batterySize;
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
  final List<String> photos;

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
    photos: photos ?? this.photos,
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
    this.photos = const [],
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
  final List<String> photos;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// How many spec fields the volunteer flagged `Unknown` at scan-confirm time
  /// (the amber escape valve on the confirm screen). Non-zero means the record
  /// is registered but still needs the audiologist to determine those fields —
  /// surfaced as a "NEEDS INPUT" flag on the register card. Kept as a literal
  /// rather than importing the scanner-side `kUnknownValue` so the devices
  /// feature stays free of a cross-feature dependency on the scanner.
  int get unknownFieldCount => [
    brand,
    model,
    type,
    batterySize,
    domeType,
    waxFilter,
    receiver,
  ].where((v) => v == 'Unknown').length;

  /// Build a [Device] from a Firestore document snapshot.
  ///
  /// The document `id` is taken from the snapshot, not from a `id` field
  /// in the data — Firestore document IDs are the canonical identifier.
  factory Device.fromFirestore(DocumentSnapshot<Map<String, dynamic>> snap) {
    final d = snap.data() ?? const <String, dynamic>{};
    DateTime? ts(dynamic v) => v is Timestamp ? v.toDate() : null;
    return Device(
      id: snap.id,
      brand: (d['brand'] as String?) ?? '',
      model: (d['model'] as String?) ?? '',
      type: (d['type'] as String?) ?? '',
      year: (d['year'] as String?) ?? '',
      serialLeft: (d['serialLeft'] as String?) ?? '',
      serialRight: (d['serialRight'] as String?) ?? '',
      batterySize: (d['batterySize'] as String?) ?? '',
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
      photos: ((d['photos'] as List?)?.cast<String>()) ?? const <String>[],
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
    'photos': photos,
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
