// Excluded from coverage: uses Firestore.instance singleton directly; needs emulator
// coverage:ignore-file
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import 'device_catalog.dart';

/// The type of insight the engine surfaces.
enum InsightType {
  /// Inventory observation: "First P90 in the register"
  inventory,

  /// Notable capability: "Supports Auracast — only 2 devices do"
  capability,

  /// Recipient match: "Recipient #4 is waiting for this type"
  match,

  /// Teaching moment: "Battery door shape = size 312"
  teaching,
}

/// A single proactive observation from the Insight Engine.
class Insight {
  const Insight({
    required this.type,
    required this.text,
    this.priority = 0.5,
  });

  final InsightType type;
  final String text;

  /// 0.0–1.0. Higher = more important. Used to rank when multiple
  /// insights compete for limited HUD space (max 3 shown).
  final double priority;
}

/// Proactive scanner intelligence — notices things and speaks up.
///
/// Sits between detection and HUD. Takes a scan result + context and
/// outputs 0–3 ranked observations. Uses graduated exposure: verbosity
/// decreases as the user becomes familiar with each brand/model.
///
/// The insight engine doesn't just identify — it connects the device
/// to the inventory, the recipient queue, and the user's knowledge.
class InsightEngine {
  InsightEngine._();

  static final _firestore = FirebaseFirestore.instance;
  static final _catalog = DeviceCatalog.instance;

  // ── Cache: how many times each brand/model has been scanned ──────────
  static final Map<String, int> _scanCounts = {};
  static bool _loaded = false;

  /// Generate insights for a detected device.
  ///
  /// Returns 0–3 insights ranked by priority. The [familiarityScore]
  /// controls verbosity:
  /// - 0 scans: full context (teaching + capability + inventory + match)
  /// - 1-4 scans: capability + inventory + match
  /// - 5-9 scans: inventory + match
  /// - 10+ scans: match only (or nothing)
  static Future<List<Insight>> generate({
    required String brand,
    String? model,
    String? colour,
    String? deviceType, // BTE, RIC, etc.
  }) async {
    if (!_loaded) await _loadScanCounts();

    final key = '$brand|${model ?? '*'}'.toLowerCase();
    final familiarity = _scanCounts[key] ?? 0;

    final insights = <Insight>[];

    // All verbosity levels: try match insights
    final matchInsights = await _matchInsights(brand, model, deviceType);
    insights.addAll(matchInsights);

    // Familiarity < 10: inventory insights
    if (familiarity < 10) {
      final inventoryInsights = await _inventoryInsights(brand, model);
      insights.addAll(inventoryInsights);
    }

    // Familiarity < 5: capability insights
    if (familiarity < 5) {
      final capInsights = _capabilityInsights(brand, model);
      insights.addAll(capInsights);
    }

    // Familiarity < 2: teaching insights
    if (familiarity < 2) {
      final teachInsights = _teachingInsights(brand, model, deviceType);
      insights.addAll(teachInsights);
    }

    // Update scan count
    _scanCounts[key] = familiarity + 1;

    // Rank by priority, cap at 3
    insights.sort((a, b) => b.priority.compareTo(a.priority));
    return insights.take(3).toList();
  }

  // ── Match insights: connect device to waiting recipients ─────────────

  static Future<List<Insight>> _matchInsights(
    String brand,
    String? model,
    String? deviceType,
  ) async {
    final insights = <Insight>[];

    try {
      // Query recipients waiting for a device of this type
      var query = _firestore
          .collection('recipients')
          .where('status', isEqualTo: 'waiting');

      if (deviceType != null) {
        query = query.where('preferred_type', isEqualTo: deviceType);
      }

      final snapshot = await query.limit(5).get();

      if (snapshot.docs.isNotEmpty) {
        final count = snapshot.docs.length;
        if (count == 1) {
          final name = snapshot.docs.first.data()['display_name'] ?? 'A recipient';
          insights.add(Insight(
            type: InsightType.match,
            text: '$name is waiting for a ${deviceType ?? brand}.',
            priority: 0.95, // Matches are highest priority
          ));
        } else {
          insights.add(Insight(
            type: InsightType.match,
            text: '$count recipients waiting for a ${deviceType ?? brand}.',
            priority: 0.9,
          ));
        }
      }
    } catch (e) {
      if (kDebugMode) debugPrint('INSIGHT: match query failed: $e');
    }

    return insights;
  }

  // ── Inventory insights: what do we have / not have ───────────────────

  static Future<List<Insight>> _inventoryInsights(
    String brand,
    String? model,
  ) async {
    final insights = <Insight>[];

    try {
      // Count how many of this brand we have in the register
      final brandQuery = await _firestore
          .collection('devices')
          .where('brand', isEqualTo: brand)
          .get();

      final brandCount = brandQuery.docs.length;

      if (model != null) {
        // Count this specific model
        final modelQuery = await _firestore
            .collection('devices')
            .where('brand', isEqualTo: brand)
            .where('model', isEqualTo: model)
            .get();

        final modelCount = modelQuery.docs.length;

        if (modelCount == 0) {
          insights.add(Insight(
            type: InsightType.inventory,
            text: 'First $brand $model in the register.',
            priority: 0.7,
          ));
        } else {
          insights.add(Insight(
            type: InsightType.inventory,
            text: '$modelCount $brand $model already in stock.',
            priority: 0.3,
          ));
        }
      } else if (brandCount == 0) {
        insights.add(Insight(
          type: InsightType.inventory,
          text: 'First $brand device in the register.',
          priority: 0.8,
        ));
      } else {
        insights.add(Insight(
          type: InsightType.inventory,
          text: '$brandCount $brand devices in stock.',
          priority: 0.2,
        ));
      }
    } catch (e) {
      if (kDebugMode) debugPrint('INSIGHT: inventory query failed: $e');
    }

    return insights;
  }

  // ── Capability insights: what's special about this device ────────────

  static List<Insight> _capabilityInsights(String brand, String? model) {
    if (!_catalog.isLoaded || model == null) return [];

    final device = _catalog.findByName(brand, model);
    if (device == null) return [];

    final insights = <Insight>[];

    // Flag notable features
    final notable = <String>[];

    if (device.features.any((f) => f.toLowerCase().contains('auracast'))) {
      notable.add('Auracast (Bluetooth LE broadcast)');
    }
    if (device.features.any((f) => f.toLowerCase().contains('ai'))) {
      notable.add('AI-powered noise management');
    }
    if (device.features.any((f) => f.toLowerCase().contains('tinnitus'))) {
      notable.add('built-in tinnitus relief');
    }
    if (device.hspSubsidised) {
      notable.add('HSP subsidised');
    }
    if (device.waterResistant) {
      notable.add('water resistant');
    }

    if (notable.isNotEmpty) {
      final featStr = notable.length == 1
          ? notable.first
          : '${notable.take(notable.length - 1).join(', ')} and ${notable.last}';
      insights.add(Insight(
        type: InsightType.capability,
        text: '${device.technologyTier}-tier. Supports $featStr.',
        priority: 0.6,
      ));
    }

    // Suitability insight
    if (device.suitability.isNotEmpty) {
      insights.add(Insight(
        type: InsightType.capability,
        text: 'Suitable for ${device.suitability.join(', ')} hearing loss.',
        priority: 0.4,
      ));
    }

    return insights;
  }

  // ── Teaching insights: clinical knowledge for students ───────────────

  static List<Insight> _teachingInsights(
    String brand,
    String? model,
    String? deviceType,
  ) {
    final insights = <Insight>[];

    // Type-based teaching
    if (deviceType != null) {
      final teaching = switch (deviceType.toUpperCase()) {
        'BTE' => 'BTE = Behind-The-Ear. Earhook curves over the pinna. '
            'Most powerful style — handles severe/profound loss.',
        'RIC' => 'RIC = Receiver-In-Canal. Thin wire replaces the earhook. '
            'Most popular style — discreet with natural sound.',
        'ITE' => 'ITE = In-The-Ear. Custom-moulded to fill the outer ear. '
            'Larger battery, easier handling for dexterity issues.',
        'CIC' => 'CIC = Completely-In-Canal. Nearly invisible. '
            'Limited power — best for mild-to-moderate loss.',
        'IIC' => 'IIC = Invisible-In-Canal. Deepest insertion. '
            'Removed with a pull cord. Mild loss only.',
        'ITC' => 'ITC = In-The-Canal. Partially visible. '
            'Good balance of size and features.',
        _ => null,
      };

      if (teaching != null) {
        insights.add(Insight(
          type: InsightType.teaching,
          text: teaching,
          priority: 0.35,
        ));
      }
    }

    // Battery teaching (if we know the device)
    if (_catalog.isLoaded && model != null) {
      final device = _catalog.findByName(brand, model);
      if (device != null && device.batterySize != 'Unknown') {
        final batteryTeaching = switch (device.batterySize.toLowerCase()) {
          '10' => 'Size 10 (yellow tab). Smallest. 3-7 day life. '
              'Round door, tiny — check with magnification.',
          '13' => 'Size 13 (orange tab). Mid-size. 6-14 day life. '
              'Most common for BTE devices.',
          '312' => 'Size 312 (brown tab). Most popular overall. '
              '3-10 day life. Standard for RIC and ITC.',
          '675' => 'Size 675 (blue tab). Largest. 9-20 day life. '
              'Used in power BTEs for severe loss.',
          _ => null,
        };

        if (batteryTeaching != null) {
          insights.add(Insight(
            type: InsightType.teaching,
            text: 'Battery: ${device.batterySize}. $batteryTeaching',
            priority: 0.3,
          ));
        }
      }
    }

    return insights;
  }

  // ── Load scan counts from Firestore ─────────────────────────────────

  static Future<void> _loadScanCounts() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final snapshot = await _firestore
          .collection('scan_events')
          .where('field', isEqualTo: 'BRAND')
          .orderBy('timestamp', descending: true)
          .limit(200)
          .get();

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final brand = data['value'] as String? ?? '';
        // Use brand-only key for familiarity (model-level is too sparse early on)
        final key = '$brand|*'.toLowerCase();
        _scanCounts[key] = (_scanCounts[key] ?? 0) + 1;
      }

      if (kDebugMode) {
        debugPrint('INSIGHT: loaded scan counts for '
            '${_scanCounts.length} brand/model combinations');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('INSIGHT: scan count load failed: $e');
    }
  }

  /// Reset familiarity for testing / demo purposes.
  @visibleForTesting
  static void resetFamiliarity() {
    _scanCounts.clear();
    _loaded = false;
  }
}
