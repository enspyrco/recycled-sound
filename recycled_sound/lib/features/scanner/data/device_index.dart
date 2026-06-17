import 'dart:async';

import 'package:flutter/foundation.dart';

import 'brand_matcher.dart';
import 'device_catalog.dart';

/// Fields that can be narrowed / auto-locked during a scan.
enum DeviceField {
  brand,
  model,
  type, // BTE, RIC, ITE, CIC, ITC, IIC
  batterySize, // Size 10, 13, 312, 675, Rechargeable
  power, // Battery | Rechargeable (derived from batterySize)
  tubing, // Standard | Slim | None (derived from type)
  colour, // Not in catalog — always open
}

/// How a field value was determined.
enum DetectionSource { ocr, neuralNet, catalog, inferred, manual }

/// A single locked field with its value and provenance.
class LockedField {
  const LockedField({
    required this.value,
    required this.source,
    this.confidence,
    required this.lockedAt,
  });

  final String value;
  final DetectionSource source;

  /// e.g. "EXACT", "85% AI", "CATALOG"
  final String? confidence;
  final DateTime lockedAt;
}

/// One rejected-override event captured by the narrowing guard.
///
/// Each record is a single instance of "evidence arrived but didn't beat
/// the existing lock." Aggregated per scan to reveal which OCR patterns,
/// neural-net guesses, or catalog cascades are noisiest. Feeds future
/// brand_matcher tuning + the full backtracking work (stream γ).
class ContradictionRecord {
  ContradictionRecord({
    required this.field,
    required this.keptValue,
    required this.keptConfidence,
    required this.keptRank,
    required this.rejectedValue,
    required this.rejectedConfidence,
    required this.rejectedRank,
    required this.rejectedSource,
    required this.at,
  });

  final DeviceField field;
  final String keptValue;
  final String? keptConfidence;
  final int keptRank;
  final String rejectedValue;
  final String? rejectedConfidence;
  final int rejectedRank;
  final DetectionSource rejectedSource;
  final DateTime at;

  @override
  String toString() => '$field: kept "$keptValue"($keptConfidence,r=$keptRank) '
      'over "$rejectedValue"($rejectedConfidence,r=$rejectedRank,'
      'src=${rejectedSource.name})';
}

/// Immutable snapshot of detection state.
class DetectionState {
  const DetectionState({
    required this.locked,
    required this.candidateCount,
  });

  /// Locked fields and their values.
  final Map<DeviceField, LockedField> locked;

  /// How many devices remain in the candidate set.
  final int candidateCount;

  bool isLocked(DeviceField f) => locked.containsKey(f);
  String? valueOf(DeviceField f) => locked[f]?.value;
  LockedField? fieldOf(DeviceField f) => locked[f];
  int get filledCount => locked.length;

  static const empty = DetectionState(
    locked: {},
    candidateCount: 0,
  );
}

/// Catalog-driven elimination tree for hearing aid identification.
///
/// Builds inverted indexes from [DeviceCatalog] at load time. Each detection
/// signal narrows the candidate set via [narrow]. Fields auto-lock when
/// only one possible value remains. [possibleValues] feeds slot reel
/// animations with dynamically shrinking candidate lists.
///
/// Layers on top of [BrandMatcher] — uses its fuzzy matching for OCR text,
/// then maps results to catalog device IDs for elimination.
class DeviceIndex {
  DeviceIndex._();

  /// Singleton instance — loaded once alongside DeviceCatalog.
  static final DeviceIndex instance = DeviceIndex._();

  bool _loaded = false;
  bool get isLoaded => _loaded;

  // ── Inverted indexes (built at load time) ────────────────────────────

  /// brand (lowercase, normalized) → device IDs
  final _brandIndex = <String, Set<String>>{};

  /// model text (lowercase) → device IDs
  final _modelIndex = <String, Set<String>>{};

  /// device type prefix (lowercase, e.g. "bte") → device IDs
  final _typeIndex = <String, Set<String>>{};

  /// battery size (lowercase, e.g. "size 312") → device IDs
  final _batteryIndex = <String, Set<String>>{};

  /// All device IDs in the catalog.
  final _allDeviceIds = <String>{};

  /// device ID → DeviceEntry for quick lookups.
  final _devices = <String, DeviceEntry>{};

  /// Brand alias map: normalized alias → canonical display name.
  /// Merged from BrandMatcher.brands and catalog manufacturers.
  final _brandAliases = <String, String>{};

  /// Rejected-override events from the current scan session.
  /// Cleared on reset(). Read via [contradictions] for inspection /
  /// summary logging. Bounded (last 200 entries) to cap memory if a
  /// long-running scan keeps firing rejections.
  final _contradictions = <ContradictionRecord>[];
  static const int _kMaxContradictions = 200;

  /// Live tally of how many times a *specific* alternative value has been
  /// rejected **consecutively** for a still-locked field, keyed by
  /// "field|rejectedValue" (lowercased). This is the lever the contradiction-
  /// aware re-open uses: it counts a CONSECUTIVE run of the same alternative
  /// arriving (the fingerprint of a wrong early lock), and resets that run
  /// the moment a *different* alternative is rejected for the same field —
  /// which is the exact opposite of frame-to-frame flapping (oscillation
  /// between values, where each value's run is broken every frame so neither
  /// ever accumulates ≥ 2). Reset on reset() and cleared per-field when that
  /// field re-opens or relocks.
  final _rejectedValueCounts = <String, int>{};

  /// How many times the SAME alternative value must be rejected against a
  /// locked field before the override guard re-opens that field for
  /// re-narrowing. Must be > 1 so a single weaker reading (the common,
  /// genuinely-noisy case the guard was built to suppress on 2026-05-07)
  /// is still rejected — only a *persistent* contradiction breaks the lock.
  ///
  /// ## Why a COUNT (and the assumption it rests on)
  ///
  /// This is a count threshold, not a time threshold, and that choice carries
  /// an explicit, currently-unverified assumption: that the OCR signal-to-
  /// noise ratio per *frame* is roughly stable. The guarantee the count
  /// actually buys is **shape-based, not magnitude-based** and is frame-rate
  /// invariant:
  ///
  ///   - Frame-to-frame FLAPPING oscillates between competing values, so the
  ///     consecutive run for any *single* value is broken every frame and
  ///     never reaches ≥ 2 — it can never trip this path, at ANY frame rate.
  ///     This part is proven (see `_rejectedValueCounts` consecutive-run reset
  ///     + the anti-flap regression test `oscillating contradictions never
  ///     trip the re-open` in device_index_test.dart). Raising fps does NOT
  ///     erode it.
  ///
  ///   - A WRONG early lock produces the *same* contradicting value on
  ///     consecutive readable frames, so it accumulates and (correctly)
  ///     re-opens.
  ///
  /// What the count does NOT pin down is the MAGNITUDE. "2" means "two frames
  /// in which the contradicting value was read." At ~2 fps that is ~1 second
  /// of corroboration; if the capture loop ever speeds up materially (more
  /// readable frames per second), two frames becomes a shorter real-world
  /// dwell, weakening the corroboration window toward the threshold-1 limit
  /// the guard was specifically built to avoid. The reverse (slower fps /
  /// heavier hand-shake) makes "2" harder to reach and re-open laggier.
  ///
  /// ## Frame-rate dependency — the named tradeoff
  ///
  /// Count=2 is therefore correct *for the current scan loop's frame rate*
  /// (~2 fps, the FramePreprocessor cadence as of 2026-04), not unconditionally.
  /// We keep it count-based because the only honest alternative — a time-based
  /// threshold (re-open after the value persists for N ms) — needs a principled
  /// N, and N can only come from real on-device data we do not yet have:
  /// actual scan fps and the inter-arrival time of contradicting reads. Picking
  /// an N now would just swap this magic number for a less-testable one (the
  /// replay harness is deliberately clock-free; see scan_replay_engine.dart).
  ///
  /// Follow-up (device-data gate): once a real scan's per-frame OCR
  /// is captured with timestamps, measure (a) effective readable-frame rate and
  /// (b) contradiction inter-arrival, then EITHER confirm count=2 spans the
  /// intended ~1s window across the device fleet, OR migrate to a time-based
  /// threshold (which would require threading frame timestamps through
  /// [narrow] and the replay harness). Do not migrate before that data exists.
  static const int _kReopenThreshold = 2;

  String _rejKey(DeviceField field, String value) =>
      '${field.name}|${value.toLowerCase().trim()}';

  /// Read-only view of contradictions from the current scan session.
  List<ContradictionRecord> get contradictions =>
      List.unmodifiable(_contradictions);

  /// Count of contradictions grouped by field name — handy for the
  /// "X overrides rejected on brand, Y on model" summary at scan end.
  Map<String, int> get contradictionsByField {
    final result = <String, int>{};
    for (final r in _contradictions) {
      result.update(r.field.name, (n) => n + 1, ifAbsent: () => 1);
    }
    return result;
  }

  // ── Live scan state ──────────────────────────────────────────────────

  var _candidates = <String>{};
  final _locked = <DeviceField, LockedField>{};
  final _stateController = StreamController<DetectionState>.broadcast();

  /// Build all inverted indexes from the catalog and BrandMatcher patterns.
  Future<void> load(DeviceCatalog catalog) async {
    if (_loaded) return;
    if (!catalog.isLoaded) {
      debugPrint('DeviceIndex: catalog not loaded yet');
      return;
    }

    // Build brand alias map from BrandMatcher
    for (final entry in BrandMatcher.brands.entries) {
      _brandAliases[entry.key] = entry.value;
    }

    // Index each device
    for (final device in catalog.allDevices) {
      final id = device.id;
      _allDeviceIds.add(id);
      _devices[id] = device;

      // Brand index — normalize to lowercase
      final brandKey = device.manufacturer.toLowerCase();
      _brandIndex.putIfAbsent(brandKey, () => {}).add(id);

      // Also index via aliases pointing to this brand
      final canonicalBrand = device.manufacturer;
      for (final alias in BrandMatcher.brands.entries) {
        if (alias.value == canonicalBrand) {
          _brandIndex.putIfAbsent(alias.key, () => {}).add(id);
        }
      }

      // Model index — index both the model code and full name
      final modelKey = device.model.toLowerCase();
      _modelIndex.putIfAbsent(modelKey, () => {}).add(id);

      // Index individual words from the full name (for fuzzy model matching)
      final nameWords = device.name
          .toLowerCase()
          .replaceAll(RegExp(r'[^\w\s]'), '')
          .split(RegExp(r'\s+'))
          .where((w) => w.length >= 3);
      for (final word in nameWords) {
        // Skip the brand name itself as a model index entry
        if (word == brandKey) continue;
        _modelIndex.putIfAbsent(word, () => {}).add(id);
      }

      // Type index — extract prefix (BTE, RIC, ITE, etc.)
      final typePrefix = _extractTypePrefix(device.type);
      if (typePrefix != null) {
        _typeIndex.putIfAbsent(typePrefix, () => {}).add(id);
      }

      // Battery index
      final batteryKey = device.batterySize.toLowerCase();
      if (batteryKey.isNotEmpty && batteryKey != 'unknown') {
        _batteryIndex.putIfAbsent(batteryKey, () => {}).add(id);
      }
    }

    // Merge BrandMatcher model patterns as loose associations.
    // E.g., "ino" → all Oticon devices (since Ino isn't in catalog model field
    // but IS a real Oticon model).
    for (final entry in BrandMatcher.modelPatterns.entries) {
      final brandName = BrandMatcher.brands[entry.key];
      if (brandName == null) continue;
      final brandDevices = _brandIndex[entry.key] ?? {};

      for (final pattern in entry.value) {
        // Only add if not already indexed from catalog
        if (!_modelIndex.containsKey(pattern)) {
          _modelIndex[pattern] = Set.from(brandDevices);
        }
      }
    }

    _candidates = Set.from(_allDeviceIds);
    _loaded = true;
    debugPrint(
      'DeviceIndex: loaded ${_allDeviceIds.length} devices, '
      '${_brandIndex.length} brand keys, '
      '${_modelIndex.length} model keys, '
      '${_typeIndex.length} type keys, '
      '${_batteryIndex.length} battery keys',
    );
  }

  /// Reset to full candidate set. Call at the start of each new scan.
  /// Also clears any contradictions from the previous scan so the
  /// summary at the next scan-end reflects only this run.
  void reset() {
    _candidates = Set.from(_allDeviceIds);
    _locked.clear();
    _contradictions.clear();
    _rejectedValueCounts.clear();
    _emitState();
  }

  /// Re-open a wrong-locked [field] (contradiction-aware re-open, #733).
  ///
  /// Drops the field's lock and any fields derived from it, then rebuilds
  /// the candidate set from the *surviving* locks alone — so the candidates
  /// the bad lock wrongly eliminated come back into play. The caller then
  /// re-narrows with the persistently-contradicting value. The rejected-
  /// value tally for this field is cleared so the freshly-applied value
  /// starts from a clean slate (no immediate re-trigger).
  void _reopenField(DeviceField field) {
    // Remove the field and its derived children so a stale cascade can't
    // pin the candidate set back to the wrong narrowing.
    _locked.remove(field);
    for (final derived in _derivedOf(field)) {
      // Only drop derived locks that were auto-filled, never a manual one.
      final lf = _locked[derived];
      if (lf != null && lf.source != DetectionSource.manual) {
        _locked.remove(derived);
      }
    }

    // Rebuild candidates from the surviving locks (intersection of each
    // locked field's matches). Start from the full set; an empty surviving
    // lock set restores everything, exactly like a fresh scan.
    var rebuilt = Set<String>.from(_allDeviceIds);
    for (final entry in _locked.entries) {
      final idx = _indexForField(entry.key);
      if (idx == null) continue; // derived/colour fields don't narrow
      final m = _fuzzyLookup(
          entry.key, entry.value.value.toLowerCase().trim(), idx);
      if (m != null && m.isNotEmpty) {
        final next = rebuilt.intersection(m);
        if (next.isNotEmpty) rebuilt = next; // keep open-mode semantics
      }
    }
    _candidates = rebuilt;

    // Clear this field's contradiction tallies so the incoming value lands
    // fresh and a future genuine contradiction must re-accumulate.
    _rejectedValueCounts
        .removeWhere((k, _) => k.startsWith('${field.name}|'));
  }

  /// Fields auto-derived from [field] (so they must be dropped when it
  /// re-opens). Mirrors [_autoLockDerived].
  static List<DeviceField> _derivedOf(DeviceField field) {
    switch (field) {
      case DeviceField.batterySize:
        return const [DeviceField.power];
      case DeviceField.type:
        return const [DeviceField.tubing];
      default:
        return const [];
    }
  }

  /// Narrow candidates by a detected field value.
  ///
  /// If narrowing would produce 0 candidates (device not in catalog),
  /// enters **open mode**: locks the field with [DetectionSource.ocr]
  /// but keeps the previous candidate set intact.
  ///
  /// After narrowing, auto-locks any other fields that have only one
  /// remaining possible value.
  DetectionState narrow(
    DeviceField field,
    String value, {
    DetectionSource source = DetectionSource.ocr,
    String? confidence,
  }) {
    // Don't re-narrow a field to the same value. A re-read that CORROBORATES the
    // current lock is positive evidence FOR it, so it must also break every
    // competing value's consecutive-contradiction run — otherwise a contradiction
    // split by reads that re-affirm the lock (A_lock, B_rej, A_corroborate, B_rej)
    // would still re-open on the 2nd B, which is not two CONSECUTIVE frames of
    // contradiction (Carnot, #88 cage-match — the "consecutive frames" invariant
    // must survive interleaved corroboration, not just interleaved alternatives).
    if (_locked[field]?.value == value) {
      _rejectedValueCounts.removeWhere((k, _) => k.startsWith('${field.name}|'));
      return state;
    }

    // Override guard: stops the "right answer then noisy override" flapping
    // observed live on 2026-05-07. If the field is already locked, require
    // strictly stronger evidence to flip it. Manual overrides always win.
    // Each rejected override is appended to _contradictions for the scan-
    // end summary and for future backtracking (γ) — frequent rejections
    // are the signal that the brand_matcher pattern is too aggressive.
    final existing = _locked[field];
    if (existing != null && source != DetectionSource.manual) {
      final existingRank = _confidenceRank(existing.confidence);
      final newRank = _confidenceRank(confidence);
      if (newRank <= existingRank) {
        _recordContradiction(
          field: field,
          existing: existing,
          existingRank: existingRank,
          newValue: value,
          newConfidence: confidence,
          newRank: newRank,
          newSource: source,
        );

        // Contradiction-aware re-open (issue #733). The guard above is a
        // one-way ratchet: once a transient misread locks a field, every
        // equal/lower-rank signal — even the CORRECT one — is rejected
        // forever, freezing a wrong ID. To break that ratchet WITHOUT
        // reintroducing flapping, we count CONSECUTIVE rejections of the
        // *same* alternative value. A single weaker reading (noise) is still
        // rejected; but the SAME contradicting value arriving
        // _kReopenThreshold times *in a row* is not noise — it is steady
        // evidence the lock is wrong. At that point we re-open the field and
        // let this value narrow normally below.
        //
        // The count is a CONSECUTIVE run, not a cumulative tally: the run for a
        // value is broken by EITHER a rejection of a *different* value (below)
        // OR a frame that corroborates the current lock (the early-return at the
        // top of narrow()). So a re-open needs _kReopenThreshold frames that ALL
        // read the SAME contradicting value, uninterrupted — genuinely
        // consecutive readable frames, not merely consecutive among rejected
        // alternatives. This is what makes the anti-flap guarantee real: classic
        // flapping oscillates A,B,A,B…, so each value's run is broken every frame
        // and neither ever reaches 2; and a lock that keeps reading true (A,B,A
        // where the middle A re-affirms the lock) likewise never lets B
        // accumulate. (A cumulative tally would wrongly re-open on the second B —
        // the bug the consecutive reset fixes, #778; the corroboration reset
        // closes the interleaved-corroboration gap, #88.)
        final key = _rejKey(field, value);
        // Break the run of every OTHER contradicting value for this field:
        // a switch to a new alternative means the previous one is no longer
        // arriving consecutively, so it must not retain accumulated count.
        final prefix = '${field.name}|';
        _rejectedValueCounts.removeWhere(
            (k, _) => k != key && k.startsWith(prefix));
        final count = (_rejectedValueCounts[key] ?? 0) + 1;
        _rejectedValueCounts[key] = count;

        if (count < _kReopenThreshold) {
          if (kDebugMode) {
            debugPrint('DeviceIndex: REJECT override on ${field.name} — '
                'kept "${existing.value}" (${existing.confidence}, '
                'rank=$existingRank) over incoming "$value" '
                '($confidence, rank=$newRank) [contradiction $count/'
                '$_kReopenThreshold]');
          }
          return state;
        }

        // Threshold reached — re-open the field and fall through so the
        // persistently-contradicting value re-narrows the candidate set.
        if (kDebugMode) {
          debugPrint('DeviceIndex: RE-OPEN ${field.name} — "$value" '
              'contradicted the "${existing.value}" lock $count× '
              '(≥ $_kReopenThreshold); breaking the ratchet');
        }
        _reopenField(field);
      }
    }

    // Reaching here means this value is being ACCEPTED — it cleared the guard as
    // strictly stronger evidence, it's a manual override (which bypasses the
    // guard), or the field was just re-opened above and is re-narrowing. In every
    // case the field is about to (re)lock, so its old per-value contradiction runs
    // are stale and must be cleared — otherwise a count accumulated against the
    // PREVIOUS lock could re-open the NEW one after a single contradiction. This
    // honors the _rejectedValueCounts doc-comment ("cleared per-field when that
    // field re-opens or relocks") which the relock + manual-override paths
    // previously violated (Carnot, #88 cage-match — per-lock state isolation).
    _rejectedValueCounts.removeWhere((k, _) => k.startsWith('${field.name}|'));

    final normalized = value.toLowerCase().trim();
    final index = _indexForField(field);

    Set<String>? matches;
    if (index != null) {
      matches = _fuzzyLookup(field, normalized, index);
    }

    final now = DateTime.now();

    if (matches != null && matches.isNotEmpty) {
      // Narrow the candidate set
      final intersection = _candidates.intersection(matches);

      if (intersection.isNotEmpty) {
        _candidates = intersection;
        _locked[field] = LockedField(
          value: value,
          source: source,
          confidence: confidence,
          lockedAt: now,
        );

        // Auto-lock derived fields
        _autoLockDerived(field, value, now);

        // Auto-lock any field with only one remaining possibility
        _autoLockSingletons(now);
      } else {
        // Intersection empty — open mode: lock field, keep candidates
        _locked[field] = LockedField(
          value: value,
          source: source,
          confidence: confidence ?? 'OCR',
          lockedAt: now,
        );
      }
    } else {
      // No index for this field or no match — open mode
      _locked[field] = LockedField(
        value: value,
        source: source,
        confidence: confidence ?? 'OCR',
        lockedAt: now,
      );
    }

    _emitState();
    return state;
  }

  /// Append a contradiction record for the override-guard rejection
  /// path. Bounded by _kMaxContradictions — drops oldest on overflow
  /// (rare in practice; a 200-rejection scan would be diagnostic chaos
  /// regardless of buffer size).
  void _recordContradiction({
    required DeviceField field,
    required LockedField existing,
    required int existingRank,
    required String newValue,
    required String? newConfidence,
    required int newRank,
    required DetectionSource newSource,
  }) {
    _contradictions.add(ContradictionRecord(
      field: field,
      keptValue: existing.value,
      keptConfidence: existing.confidence,
      keptRank: existingRank,
      rejectedValue: newValue,
      rejectedConfidence: newConfidence,
      rejectedRank: newRank,
      rejectedSource: newSource,
      at: DateTime.now(),
    ));
    if (_contradictions.length > _kMaxContradictions) {
      _contradictions.removeRange(
          0, _contradictions.length - _kMaxContradictions);
    }
  }

  /// Numeric confidence rank used by the override guard. Higher beats
  /// lower. Unknown labels fall back to a low rank so the guard fails
  /// permissively rather than getting permanently stuck.
  ///
  /// Tiering:
  ///   HIGH ocr exact     80   — multi-pattern OCR hit, strongest signal
  ///   FROM MODEL         70   — model→brand cross-ref, very high signal
  ///   CATALOG cascade    60   — derived from a locked field, authoritative
  ///   INFERRED           50   — auto-locked singleton after narrowing
  ///   MEDIUM ocr         40   — single-pattern OCR hit
  ///   NEURAL net         30   — visual classifier, can be wrong on bg
  ///   OCR (no label)     20   — raw OCR text, no pattern confidence
  ///   LOW ocr            15   — fuzzy match, often noise
  ///   unknown            10   — fail-open default
  static int _confidenceRank(String? confidence) {
    if (confidence == null) return 10;
    final c = confidence.toUpperCase();
    if (c.contains('HIGH')) return 80;
    if (c.contains('FROM MODEL')) return 70;
    if (c.contains('CATALOG')) return 60;
    if (c.contains('INFERRED')) return 50;
    if (c.contains('MEDIUM')) return 40;
    if (c.contains('NEURAL')) return 30;
    if (c.contains('LOW')) return 15;
    if (c.contains('OCR')) return 20;
    return 10;
  }

  /// Possible values for [field] across remaining candidates.
  ///
  /// Returns an empty list if the field is already locked.
  /// For [DeviceField.colour], returns a static palette (not in catalog).
  /// For derived fields (power, tubing), returns computed possibilities.
  List<String> possibleValues(DeviceField field) {
    if (_locked.containsKey(field)) return const [];
    if (!_loaded) return _staticFallback(field);

    switch (field) {
      case DeviceField.brand:
        return _uniqueValues((d) => d.manufacturer);
      case DeviceField.model:
        return _uniqueValues((d) => d.model);
      case DeviceField.type:
        return _uniqueValues(
          (d) => _extractTypePrefix(d.type)?.toUpperCase(),
        );
      case DeviceField.batterySize:
        return _uniqueValues((d) {
          final bs = d.batterySize;
          return (bs.isEmpty || bs == 'Unknown') ? null : bs;
        });
      case DeviceField.power:
        return _uniqueValues((d) {
          final bs = d.batterySize.toLowerCase();
          if (bs.isEmpty || bs == 'unknown') return null;
          return bs == 'rechargeable' ? 'Rechargeable' : 'Battery';
        });
      case DeviceField.tubing:
        return _uniqueValues((d) => _inferTubing(d.type));
      case DeviceField.colour:
        return _colourPalette;
    }
  }

  /// Current detection state snapshot.
  DetectionState get state => DetectionState(
        locked: Map.unmodifiable(_locked),
        candidateCount: _candidates.length,
      );

  /// Stream of state changes — subscribe for cascade animations.
  Stream<DetectionState> get stateStream => _stateController.stream;

  /// Number of remaining candidates.
  int get candidateCount => _candidates.length;

  /// Number of devices in the catalog for a given brand.
  int brandDeviceCount(String brand) {
    final key = brand.toLowerCase();
    return _brandIndex[key]?.length ?? 0;
  }

  /// The single matched device, if exactly one candidate remains.
  DeviceEntry? get matchedDevice {
    if (_candidates.length != 1) return null;
    return _devices[_candidates.first];
  }

  /// Dispose the stream controller.
  void dispose() {
    _stateController.close();
  }

  // ── Private helpers ──────────────────────────────────────────────────

  /// Get the inverted index for a field, or null for derived/colour fields.
  Map<String, Set<String>>? _indexForField(DeviceField field) {
    switch (field) {
      case DeviceField.brand:
        return _brandIndex;
      case DeviceField.model:
        return _modelIndex;
      case DeviceField.type:
        return _typeIndex;
      case DeviceField.batterySize:
        return _batteryIndex;
      case DeviceField.power:
      case DeviceField.tubing:
      case DeviceField.colour:
        return null;
    }
  }

  /// Fuzzy lookup in an inverted index. Tries exact → substring → Levenshtein.
  Set<String>? _fuzzyLookup(
    DeviceField field,
    String normalized,
    Map<String, Set<String>> index,
  ) {
    // 1. Exact key match
    if (index.containsKey(normalized)) {
      return index[normalized]!;
    }

    // 2. For brand: try alias resolution
    if (field == DeviceField.brand) {
      final alias = _brandAliases[normalized];
      if (alias != null) {
        final aliasKey = alias.toLowerCase();
        if (index.containsKey(aliasKey)) return index[aliasKey]!;
      }
    }

    // 3. Substring match — check if normalized contains any key
    for (final entry in index.entries) {
      if (normalized.contains(entry.key) && entry.key.length >= 3) {
        return entry.value;
      }
      if (entry.key.contains(normalized) && normalized.length >= 3) {
        return entry.value;
      }
    }

    // 4. Fuzzy match — Levenshtein ≤ 2 for brand, ≤ 1 for model
    final maxDist = field == DeviceField.brand ? 2 : 1;
    for (final entry in index.entries) {
      if ((normalized.length - entry.key.length).abs() > maxDist) continue;
      if (_levenshtein(normalized, entry.key) <= maxDist) {
        return entry.value;
      }
    }

    return null;
  }

  /// Auto-lock derived fields (power from batterySize, tubing from type).
  void _autoLockDerived(DeviceField field, String value, DateTime now) {
    if (field == DeviceField.batterySize && !_locked.containsKey(DeviceField.power)) {
      final power = value.toLowerCase() == 'rechargeable'
          ? 'Rechargeable'
          : 'Battery';
      _locked[DeviceField.power] = LockedField(
        value: power,
        source: DetectionSource.inferred,
        confidence: 'INFERRED',
        lockedAt: now,
      );
    }

    if (field == DeviceField.type && !_locked.containsKey(DeviceField.tubing)) {
      final tubing = _inferTubing(value);
      if (tubing != null) {
        _locked[DeviceField.tubing] = LockedField(
          value: tubing,
          source: DetectionSource.inferred,
          confidence: 'INFERRED',
          lockedAt: now,
        );
      }
    }
  }

  /// Check all unlocked fields — if only one value remains, auto-lock it.
  void _autoLockSingletons(DateTime now) {
    for (final field in DeviceField.values) {
      if (_locked.containsKey(field)) continue;
      if (field == DeviceField.colour) continue; // Never auto-lock colour

      final values = possibleValues(field);
      if (values.length == 1) {
        _locked[field] = LockedField(
          value: values.first,
          source: DetectionSource.catalog,
          confidence: 'CATALOG',
          lockedAt: now,
        );

        // Derived field cascade
        _autoLockDerived(field, values.first, now);
      }
    }
  }

  /// Unique values for a field extractor across remaining candidates.
  List<String> _uniqueValues(String? Function(DeviceEntry) extractor) {
    final values = <String>{};
    for (final id in _candidates) {
      final device = _devices[id];
      if (device == null) continue;
      final v = extractor(device);
      if (v != null && v.isNotEmpty) values.add(v);
    }
    final sorted = values.toList()..sort();
    return sorted;
  }

  /// Extract type prefix from full type string.
  /// "BTE (Behind-the-Ear)" → "bte"
  static String? _extractTypePrefix(String type) {
    if (type.isEmpty || type == 'Unknown') return null;
    final prefix = type.split(' ').first.toLowerCase();
    return prefix.isNotEmpty ? prefix : null;
  }

  /// Infer tubing from device type.
  static String? _inferTubing(String type) {
    final prefix = _extractTypePrefix(type)?.toUpperCase();
    if (prefix == null) return null;
    if (prefix == 'BTE') return 'Standard';
    if ({'RIC', 'ITE', 'CIC', 'ITC', 'IIC'}.contains(prefix)) return 'None';
    return null;
  }

  void _emitState() {
    if (!_stateController.isClosed) {
      _stateController.add(state);
    }
  }

  /// Fallback static candidates when catalog isn't loaded.
  static List<String> _staticFallback(DeviceField field) {
    switch (field) {
      case DeviceField.brand:
        return const [
          'Oticon', 'Phonak', 'Signia', 'Widex', 'ReSound',
          'Starkey', 'Unitron', 'Bernafon', 'Beltone',
        ];
      case DeviceField.model:
        return const [
          'Real', 'More', 'Intent', 'Audeo', 'Naida', 'Pure',
          'Moment', 'Nexia', 'Genesis', 'Moxi',
        ];
      case DeviceField.type:
        return const ['BTE', 'RIC', 'ITE', 'CIC', 'ITC', 'IIC'];
      case DeviceField.batterySize:
        return const [
          'Size 10', 'Size 13', 'Size 312', 'Size 675', 'Rechargeable',
        ];
      case DeviceField.power:
        return const ['Battery', 'Rechargeable'];
      case DeviceField.tubing:
        return const ['Standard', 'Slim', 'None'];
      case DeviceField.colour:
        return _colourPalette;
    }
  }

  static const _colourPalette = [
    'Beige', 'Tan', 'Silver', 'Black', 'White', 'Brown',
    'Grey', 'Champagne', 'Sand', 'Espresso',
  ];

  /// Levenshtein distance (mirrors BrandMatcher's implementation).
  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var prev = List<int>.generate(b.length + 1, (i) => i);
    var curr = List<int>.filled(b.length + 1, 0);

    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = [
          prev[j] + 1,
          curr[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }

    return prev[b.length];
  }
}
