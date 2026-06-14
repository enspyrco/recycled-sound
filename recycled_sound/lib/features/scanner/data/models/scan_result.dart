/// Enumeration of all editable spec fields on a scan result.
///
/// Used by [ScanResultNotifier.updateField] so the compiler enforces
/// exhaustive handling — adding a field to [ScanResult] without handling
/// it in the read/write switches is a compile error, not a silent bug.
enum ScanField {
  brand,
  model,
  type,
  year,
  batterySize,
  domeType,
  waxFilter,
  receiver,
  colour,
  tubing,
  powerSource,
}

/// Sentinel value for a constrained field the volunteer has deliberately
/// marked as undetermined ("I looked, I can't tell — needs the audiologist").
///
/// This is epistemic, NOT the same as a determinate absence like tubing
/// `None` or battery `N/A` — those are facts about the device; `Unknown` is a
/// flag that the value still needs expert determination. It counts toward
/// [ScanResult.filledFieldCount] (so it satisfies the completion gate and the
/// volunteer is never stalled on a field the scanner can't fill) while
/// remaining distinguishable via [SpecField.isUnknown] so it can be surfaced
/// downstream as work for the audiologist.
const String kUnknownValue = 'Unknown';

/// Represents a single identified spec field with its confidence score.
class SpecField {
  const SpecField({required this.value, required this.confidence});

  final String value;

  /// 0–100 confidence percentage.
  final int confidence;

  /// Whether the volunteer explicitly flagged this field as undetermined.
  /// See [kUnknownValue] for why this is distinct from an empty or absent value.
  bool get isUnknown => value == kUnknownValue;

  SpecField copyWith({String? value, int? confidence}) => SpecField(
    value: value ?? this.value,
    confidence: confidence ?? this.confidence,
  );

  factory SpecField.fromJson(Map<String, dynamic> json) => SpecField(
    value: json['value'] as String,
    confidence: json['confidence'] as int,
  );

  Map<String, dynamic> toJson() => {'value': value, 'confidence': confidence};
}

/// The result of a hearing aid scan, returned by the Cloud Function.
class ScanResult {
  const ScanResult({
    required this.scanId,
    required this.imageUrl,
    required this.brand,
    required this.model,
    required this.type,
    required this.year,
    required this.batterySize,
    required this.domeType,
    required this.waxFilter,
    required this.receiver,
    this.colour,
    this.tubing,
    this.powerSource,
    this.rawLabels = const [],
  });

  final String scanId;
  final String imageUrl;
  final SpecField brand;
  final SpecField model;

  /// Style/form factor: BTE, RIC, ITE, CIC, ITC, IIC.
  final SpecField type;

  final SpecField year;
  final SpecField batterySize;
  final SpecField domeType;
  final SpecField waxFilter;
  final SpecField receiver;

  /// Device colour identified by on-device colour sampling.
  final SpecField? colour;

  /// Tubing type: slim, standard, or none (Seray's field 4).
  final SpecField? tubing;

  /// Power source: Battery or Rechargeable (Seray's field 5).
  final SpecField? powerSource;

  final List<String> rawLabels;

  /// The 7 fields Seray's audiologist model requires, in order.
  /// Returns a map of field key → (label, SpecField?, whether AI can fill it).
  List<({String key, String label, SpecField? field, bool aiAssisted})>
  get sevenFields => [
    (key: 'brand', label: 'Make', field: brand, aiAssisted: true),
    (key: 'model', label: 'Model', field: model, aiAssisted: true),
    (key: 'type', label: 'Style', field: type, aiAssisted: true),
    (key: 'tubing', label: 'Tubing', field: tubing, aiAssisted: true),
    (key: 'powerSource', label: 'Power', field: powerSource, aiAssisted: true),
    (
      key: 'batterySize',
      label: 'Battery Size',
      field: batterySize,
      aiAssisted: true,
    ),
    (key: 'colour', label: 'Colour', field: colour, aiAssisted: true),
  ];

  /// How many of the 7 fields have a non-empty value.
  int get filledFieldCount => sevenFields
      .where(
        (f) =>
            f.field != null &&
            f.field!.value.isNotEmpty &&
            f.field!.value != '—',
      )
      .length;

  /// How many of the 7 fields the volunteer flagged as [kUnknownValue].
  /// These count as filled (so they don't block completion) but flag work for
  /// the audiologist — surfaced on the confirm screen and the register card.
  int get unknownFieldCount =>
      sevenFields.where((f) => f.field?.isUnknown ?? false).length;

  /// Whether all 7 fields are filled. An `Unknown` flag counts as filled — the
  /// gate asks "has every field been acknowledged?", not "is every value
  /// confirmed?" — so a volunteer is never stranded on a field the scanner
  /// can't determine (e.g. tubing). See [unknownFieldCount] for the residual.
  bool get isComplete => filledFieldCount == 7;

  /// Whether every field has a confirmed (non-`Unknown`) value. The confirm
  /// button enables on [isComplete]; this drives the "needs audiologist input"
  /// flag shown when some fields were acknowledged as undetermined.
  bool get isFullyVerified => isComplete && unknownFieldCount == 0;

  /// Read a field by enum. Returns null for optional fields that aren't set.
  SpecField? fieldFor(ScanField f) => switch (f) {
    ScanField.brand => brand,
    ScanField.model => model,
    ScanField.type => type,
    ScanField.year => year,
    ScanField.batterySize => batterySize,
    ScanField.domeType => domeType,
    ScanField.waxFilter => waxFilter,
    ScanField.receiver => receiver,
    ScanField.colour => colour,
    ScanField.tubing => tubing,
    ScanField.powerSource => powerSource,
  };

  /// Return a copy with one field replaced. Exhaustive — compiler-enforced.
  ScanResult withField(ScanField f, SpecField value) => switch (f) {
    ScanField.brand => copyWith(brand: value),
    ScanField.model => copyWith(model: value),
    ScanField.type => copyWith(type: value),
    ScanField.year => copyWith(year: value),
    ScanField.batterySize => copyWith(batterySize: value),
    ScanField.domeType => copyWith(domeType: value),
    ScanField.waxFilter => copyWith(waxFilter: value),
    ScanField.receiver => copyWith(receiver: value),
    ScanField.colour => copyWith(colour: value),
    ScanField.tubing => copyWith(tubing: value),
    ScanField.powerSource => copyWith(powerSource: value),
  };

  ScanResult copyWith({
    String? scanId,
    String? imageUrl,
    SpecField? brand,
    SpecField? model,
    SpecField? type,
    SpecField? year,
    SpecField? batterySize,
    SpecField? domeType,
    SpecField? waxFilter,
    SpecField? receiver,
    SpecField? colour,
    SpecField? tubing,
    SpecField? powerSource,
    List<String>? rawLabels,
  }) => ScanResult(
    scanId: scanId ?? this.scanId,
    imageUrl: imageUrl ?? this.imageUrl,
    brand: brand ?? this.brand,
    model: model ?? this.model,
    type: type ?? this.type,
    year: year ?? this.year,
    batterySize: batterySize ?? this.batterySize,
    domeType: domeType ?? this.domeType,
    waxFilter: waxFilter ?? this.waxFilter,
    receiver: receiver ?? this.receiver,
    colour: colour ?? this.colour,
    tubing: tubing ?? this.tubing,
    powerSource: powerSource ?? this.powerSource,
    rawLabels: rawLabels ?? this.rawLabels,
  );

  Map<String, dynamic> toJson() => {
    'scanId': scanId,
    'imageUrl': imageUrl,
    'brand': brand.toJson(),
    'model': model.toJson(),
    'type': type.toJson(),
    'year': year.toJson(),
    'batterySize': batterySize.toJson(),
    'domeType': domeType.toJson(),
    'waxFilter': waxFilter.toJson(),
    'receiver': receiver.toJson(),
    if (colour != null) 'colour': colour!.toJson(),
    if (tubing != null) 'tubing': tubing!.toJson(),
    if (powerSource != null) 'powerSource': powerSource!.toJson(),
    'rawLabels': rawLabels,
  };

  factory ScanResult.fromJson(Map<String, dynamic> json) => ScanResult(
    scanId: json['scanId'] as String,
    imageUrl: json['imageUrl'] as String,
    brand: SpecField.fromJson(json['brand'] as Map<String, dynamic>),
    model: SpecField.fromJson(json['model'] as Map<String, dynamic>),
    type: SpecField.fromJson(json['type'] as Map<String, dynamic>),
    year: SpecField.fromJson(json['year'] as Map<String, dynamic>),
    batterySize: SpecField.fromJson(
      json['batterySize'] as Map<String, dynamic>,
    ),
    domeType: SpecField.fromJson(json['domeType'] as Map<String, dynamic>),
    waxFilter: SpecField.fromJson(json['waxFilter'] as Map<String, dynamic>),
    receiver: SpecField.fromJson(json['receiver'] as Map<String, dynamic>),
    colour: json['colour'] != null
        ? SpecField.fromJson(json['colour'] as Map<String, dynamic>)
        : null,
    tubing: json['tubing'] != null
        ? SpecField.fromJson(json['tubing'] as Map<String, dynamic>)
        : null,
    powerSource: json['powerSource'] != null
        ? SpecField.fromJson(json['powerSource'] as Map<String, dynamic>)
        : null,
    rawLabels:
        (json['rawLabels'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList() ??
        const [],
  );

  /// Returns a mock result for development/testing.
  ///
  /// Simulates a real scan: brand, model, and colour are AI-filled.
  /// Style is pre-populated from CLIP probe (91.2%). Tubing, power source,
  /// and battery size are left for the audiologist.
  factory ScanResult.mock() => const ScanResult(
    scanId: 'mock-001',
    imageUrl: '',
    brand: SpecField(value: 'Phonak', confidence: 95),
    model: SpecField(value: 'Audéo P90', confidence: 88),
    type: SpecField(value: 'RIC', confidence: 91),
    year: SpecField(value: '2021', confidence: 75),
    batterySize: SpecField(value: '', confidence: 0),
    domeType: SpecField(value: 'Closed', confidence: 70),
    waxFilter: SpecField(value: 'CeruShield Disk', confidence: 65),
    receiver: SpecField(value: 'M receiver', confidence: 72),
    colour: SpecField(value: 'Champagne', confidence: 85),
    rawLabels: ['hearing aid', 'Phonak', 'behind-the-ear', 'medical device'],
  );
}
