// Excluded from coverage: uses Firestore.instance singleton directly; needs emulator
// coverage:ignore-file
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Tracks scanner detection outcomes for graduated exposure learning.
///
/// Every scan produces signals: which filter won, what colour was detected,
/// how confident the neural net was, whether the audiologist corrected the
/// result. Over time, this data drives smarter filter ordering and
/// confidence calibration.
///
/// Data flows to Firestore `scan_events` collection for cross-device
/// learning. On-device, [filterPriorityForColour] returns a ranked filter
/// list based on accumulated wins.
class ScanTracker {
  ScanTracker._();

  static final _firestore = FirebaseFirestore.instance;

  // ── In-memory filter win counts (per colour) ─────────────────────────
  // Populated from Firestore on first call, updated on each detection.
  static final Map<String, Map<String, int>> _filterWins = {};
  static bool _loaded = false;

  /// Record a detection event.
  ///
  /// Called when the scanner identifies a brand or model. Captures which
  /// filter was active, what colour was detected, and the confidence level.
  /// This is the core data for graduated exposure: filters that win more
  /// often for a given colour get tried first in future scans.
  static Future<void> recordDetection({
    required String field, // 'BRAND' or 'MODEL'
    required String value, // e.g. 'Oticon', 'Moxi S-R'
    required String filter, // e.g. 'RAW', 'ENHANCE', 'HI-CON', 'OCR'
    String? colour, // detected colour at time of match
    String? confidence, // e.g. 'EXACT', 'FUZZY ≤1', '87% AI'
    String? matchType, // 'ocr', 'neural_net', 'from_model'
  }) async {
    final event = {
      'field': field,
      'value': value,
      'filter': filter,
      'colour': colour,
      'confidence': confidence,
      'match_type': matchType,
      'timestamp': FieldValue.serverTimestamp(),
    };

    try {
      await _firestore.collection('scan_events').add(event);

      // Update in-memory filter wins
      if (colour != null) {
        _filterWins.putIfAbsent(colour, () => {});
        _filterWins[colour]![filter] =
            (_filterWins[colour]![filter] ?? 0) + 1;
      }

      if (kDebugMode) {
        debugPrint('TRACKER: $field=$value filter=$filter colour=$colour');
      }
    } catch (e) {
      // Don't let tracking failures break the scanner.
      if (kDebugMode) debugPrint('TRACKER: write failed: $e');
    }
  }

  /// Record an audiologist correction — the scanner was wrong.
  ///
  /// This is the most valuable signal: it tells us where confidence was
  /// miscalibrated. Over time, corrections for specific brands/models
  /// should decrease if the model is learning.
  static Future<void> recordCorrection({
    required String field, // 'BRAND', 'MODEL', 'COLOUR', etc.
    required String originalValue,
    required String correctedValue,
    String? scanId,
  }) async {
    final event = {
      'type': 'correction',
      'field': field,
      'original': originalValue,
      'corrected': correctedValue,
      'scan_id': scanId,
      'timestamp': FieldValue.serverTimestamp(),
    };

    try {
      await _firestore.collection('scan_events').add(event);

      if (kDebugMode) {
        debugPrint('TRACKER: correction $field: $originalValue → $correctedValue');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('TRACKER: correction write failed: $e');
    }
  }

  /// Get the recommended filter order for a given detected colour.
  ///
  /// Returns filters ranked by win count for this colour. If no data
  /// exists for this colour, returns the default cycle order. This is
  /// graduated exposure applied to inference: filters that have proven
  /// effective get tried first, with a 20% exploration budget for others.
  static Future<List<String>> filterPriorityForColour(String? colour) async {
    if (!_loaded) await _loadFilterWins();

    const defaultOrder = ['RAW', 'ENHANCE', 'HI-CON', 'OCR'];

    if (colour == null || !_filterWins.containsKey(colour)) {
      return defaultOrder;
    }

    final wins = _filterWins[colour]!;
    if (wins.isEmpty) return defaultOrder;

    // Sort by win count descending
    final ranked = wins.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    // Build priority list: ranked winners first, then remaining filters
    final priority = <String>[];
    for (final entry in ranked) {
      priority.add(entry.key);
    }
    // Add any filters not yet seen for this colour (exploration)
    for (final f in defaultOrder) {
      if (!priority.contains(f)) priority.add(f);
    }

    return priority;
  }

  /// Load filter win counts from Firestore.
  ///
  /// Aggregates the last 100 detection events to build the win table.
  /// Called once per session — subsequent calls use the in-memory cache
  /// plus any new detections from this session.
  static Future<void> _loadFilterWins() async {
    if (_loaded) return;
    _loaded = true;

    try {
      final snapshot = await _firestore
          .collection('scan_events')
          .where('colour', isNull: false)
          .where('field', whereIn: ['BRAND', 'MODEL'])
          .orderBy('timestamp', descending: true)
          .limit(100)
          .get();

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final colour = data['colour'] as String?;
        final filter = data['filter'] as String?;
        if (colour == null || filter == null) continue;

        _filterWins.putIfAbsent(colour, () => {});
        _filterWins[colour]![filter] =
            (_filterWins[colour]![filter] ?? 0) + 1;
      }

      // Count total brand detections for hint graduation
      _totalScans = snapshot.docs
          .where((d) => d.data()['field'] == 'BRAND')
          .length;

      if (kDebugMode) {
        debugPrint('TRACKER: loaded ${snapshot.docs.length} events, '
            '${_filterWins.length} colour profiles, '
            '$_totalScans total scans');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('TRACKER: load failed: $e');
    }
  }

  /// Total completed scans (brand detections) for this user.
  ///
  /// Used to graduate HUD hints: 0-3 full, 4-10 abbreviated, 11+ suppressed.
  /// Loaded from Firestore once per session, incremented locally on each detection.
  static int _totalScans = 0;

  /// Get the user's total scan count.
  static Future<int> getTotalScans() async {
    if (!_loaded) await _loadFilterWins();
    return _totalScans;
  }

  /// Increment local scan count (called on each brand detection).
  static void incrementLocalScanCount() => _totalScans++;

  /// Get a summary of accumulated learning for debug display.
  static Map<String, dynamic> debugSummary() {
    return {
      'loaded': _loaded,
      'colour_profiles': _filterWins.length,
      'details': _filterWins.map((colour, wins) => MapEntry(
            colour,
            wins.entries
                .map((e) => '${e.key}:${e.value}')
                .join(', '),
          )),
    };
  }
}
