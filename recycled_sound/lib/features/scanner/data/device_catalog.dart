import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// Loads and provides access to the bundled device catalog.
///
/// The catalog maps embedding indices to device IDs (via [embeddingIndex])
/// and device IDs to full metadata (via [devices]). This two-level lookup
/// allows the similarity search to return embedding matches which are then
/// resolved to actual device specs.
class DeviceCatalog {
  DeviceCatalog._();

  bool _loaded = false;

  /// Maps embedding index → list of device IDs that image represents.
  late final List<List<String>> _embeddingIndex;

  /// Maps device ID → full device metadata.
  late final Map<String, DeviceEntry> _devices;

  /// Index from lowercase 'manufacturer|model' → device ID for OCR lookup.
  late final Map<String, String> _nameIndex;

  /// Singleton instance — loaded once and cached.
  static final DeviceCatalog instance = DeviceCatalog._();

  bool get isLoaded => _loaded;
  int get deviceCount => _devices.length;
  int get embeddingCount => _embeddingIndex.length;

  /// Load the device catalog from the bundled JSON asset.
  Future<void> loadFromAsset({
    String assetPath = 'assets/device_catalog.json',
  }) async {
    if (_loaded) return;

    final jsonStr = await rootBundle.loadString(assetPath);
    final data = json.decode(jsonStr) as Map<String, dynamic>;

    // Parse embedding index
    final indexList = data['embeddingIndex'] as List<dynamic>;
    _embeddingIndex = indexList.map((entry) {
      final map = entry as Map<String, dynamic>;
      return (map['deviceIds'] as List<dynamic>).cast<String>();
    }).toList();

    // Parse devices
    final devicesMap = data['devices'] as Map<String, dynamic>;
    _devices = devicesMap.map((id, json) => MapEntry(
          id,
          DeviceEntry.fromJson(id, json as Map<String, dynamic>),
        ));

    // Build name index for OCR cross-reference
    _nameIndex = {};
    for (final entry in _devices.entries) {
      final key =
          '${entry.value.manufacturer}|${entry.value.model}'.toLowerCase();
      _nameIndex[key] = entry.key;

      // Also index by manufacturer|name for broader matching
      final nameKey =
          '${entry.value.manufacturer}|${entry.value.name}'.toLowerCase();
      _nameIndex[nameKey] = entry.key;
    }

    _loaded = true;
  }

  /// Get device IDs linked to an embedding at [index].
  List<String> deviceIdsForEmbedding(int index) {
    assert(_loaded, 'Call loadFromAsset() first');
    if (index < 0 || index >= _embeddingIndex.length) return const [];
    return _embeddingIndex[index];
  }

  /// Get full device metadata by ID.
  DeviceEntry? getDevice(String deviceId) {
    return _devices[deviceId];
  }

  /// Look up a device by manufacturer and model name (case-insensitive).
  ///
  /// Used for OCR cross-reference: if OCR detects "Phonak" + "Audeo",
  /// this finds the matching device in the catalog.
  DeviceEntry? findByName(String manufacturer, String modelOrName) {
    final key = '$manufacturer|$modelOrName'.toLowerCase();
    final id = _nameIndex[key];
    if (id != null) return _devices[id];

    // Fallback: fuzzy match against the full device name.
    // OCR reads marketing names like "Agil Pro" but the catalog stores
    // form factor codes like "312". The full name field bridges them:
    // "Phonak Audéo Lumity RT" contains "Audéo" and "Lumity".
    return findByNameFuzzy(manufacturer, modelOrName);
  }

  /// Fuzzy name search — finds the best matching device by checking if
  /// the OCR text appears in the full device name field.
  ///
  /// Returns the first match where all significant words from the OCR text
  /// appear in the device name. Handles accent-insensitive matching.
  DeviceEntry? findByNameFuzzy(String manufacturer, String ocrText) {
    if (ocrText.isEmpty) return null;

    final brandLower = manufacturer.toLowerCase();
    final searchWords = _normalizeAccents(ocrText.toLowerCase())
        .split(RegExp(r'\s+'))
        .where((w) => w.length >= 3) // skip short noise
        .toList();
    if (searchWords.isEmpty) return null;

    DeviceEntry? bestMatch;
    var bestScore = 0;

    for (final entry in _devices.values) {
      if (entry.manufacturer.toLowerCase() != brandLower) continue;

      final nameLower = _normalizeAccents(entry.name.toLowerCase());

      // Count how many OCR words appear in the device name
      var score = 0;
      for (final word in searchWords) {
        if (nameLower.contains(word)) score++;
      }

      if (score > bestScore) {
        bestScore = score;
        bestMatch = entry;
      }
    }

    // Require at least one significant word to match
    return bestScore > 0 ? bestMatch : null;
  }

  /// Strip common accented characters for matching.
  static String _normalizeAccents(String s) => s
      .replaceAll('é', 'e')
      .replaceAll('è', 'e')
      .replaceAll('ê', 'e')
      .replaceAll('á', 'a')
      .replaceAll('à', 'a')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ü', 'u');

  /// Search for devices whose manufacturer matches [brand] (case-insensitive).
  ///
  /// Returns all matching device IDs. Used when OCR detects a brand name
  /// but not a specific model.
  List<String> findByBrand(String brand) {
    final brandLower = brand.toLowerCase();
    return _devices.entries
        .where((e) => e.value.manufacturer.toLowerCase() == brandLower)
        .map((e) => e.key)
        .toList();
  }
}

/// A single device entry from the catalog with all spec fields.
class DeviceEntry {
  const DeviceEntry({
    required this.id,
    required this.manufacturer,
    required this.model,
    required this.name,
    required this.type,
    required this.year,
    required this.batterySize,
    required this.technologyTier,
    required this.features,
    required this.suitability,
    required this.batteryLife,
    required this.bluetooth,
    required this.noiseReduction,
    required this.waterResistant,
    required this.hspSubsidised,
    required this.recycledSoundBrand,
  });

  final String id;
  final String manufacturer;
  final String model;
  final String name;
  final String type;
  final String year;
  final String batterySize;
  final String technologyTier;
  final List<String> features;
  final List<String> suitability;
  final String batteryLife;
  final bool bluetooth;
  final String noiseReduction;
  final bool waterResistant;
  final bool hspSubsidised;
  final bool recycledSoundBrand;

  factory DeviceEntry.fromJson(String id, Map<String, dynamic> json) {
    return DeviceEntry(
      id: id,
      manufacturer: json['manufacturer'] as String? ?? 'Unknown',
      model: json['model'] as String? ?? 'Unknown',
      name: json['name'] as String? ?? 'Unknown',
      type: json['type'] as String? ?? 'Unknown',
      year: json['year'] as String? ?? 'Unknown',
      batterySize: json['batterySize'] as String? ?? 'Unknown',
      technologyTier: json['technologyTier'] as String? ?? 'Unknown',
      features: (json['features'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      suitability: (json['suitability'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          const [],
      batteryLife: json['batteryLife'] as String? ?? 'Unknown',
      bluetooth: json['bluetooth'] as bool? ?? false,
      noiseReduction: json['noiseReduction'] as String? ?? 'Unknown',
      waterResistant: json['waterResistant'] as bool? ?? false,
      hspSubsidised: json['hspSubsidised'] as bool? ?? false,
      recycledSoundBrand: json['recycledSoundBrand'] as bool? ?? false,
    );
  }
}
