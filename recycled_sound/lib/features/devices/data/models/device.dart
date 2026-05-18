import 'package:cloud_firestore/cloud_firestore.dart';

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
    this.qaStatus = 'pending_qa',
    this.status = 'donated',
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
  final String qaStatus;
  final String status;
  final String servicingNotes;
  final double servicingCost;
  final String donorId;
  final String scanId;
  final List<String> photos;
  final DateTime? createdAt;
  final DateTime? updatedAt;

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
      qaStatus: (d['qaStatus'] as String?) ?? 'pending_qa',
      status: (d['status'] as String?) ?? 'donated',
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
  Map<String, dynamic> toFirestore({String? createdBy}) => {
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
        'qaStatus': qaStatus,
        'status': status,
        'servicingNotes': servicingNotes,
        'servicingCost': servicingCost,
        'donorId': donorId,
        'scanId': scanId,
        'photos': photos,
        'createdBy': ?createdBy,
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
          qaStatus: 'passed',
          status: 'ready',
        ),
        const Device(
          id: '2',
          brand: 'Oticon',
          model: 'More 1',
          type: 'BTE',
          year: '2022',
          batterySize: '13',
          qaStatus: 'pending_qa',
          status: 'donated',
        ),
        const Device(
          id: '3',
          brand: 'Signia',
          model: 'Pure 7Nx',
          type: 'RIC',
          year: '2020',
          batterySize: '312',
          qaStatus: 'passed',
          status: 'matched',
        ),
        const Device(
          id: '4',
          brand: 'GN Resound',
          model: 'ONE 9',
          type: 'RIC',
          year: '2023',
          batterySize: 'Rechargeable',
          qaStatus: 'pending_qa',
          status: 'donated',
        ),
        const Device(
          id: '5',
          brand: 'Widex',
          model: 'Moment 440',
          type: 'RIC',
          year: '2021',
          batterySize: '10',
          qaStatus: 'failed',
          status: 'servicing',
        ),
      ];
}
