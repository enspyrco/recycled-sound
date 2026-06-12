import 'dart:math';

/// Result of a brand match, including how the match was made.
class BrandMatchResult {
  const BrandMatchResult({
    required this.displayName,
    required this.distance,
    required this.matchType,
  });

  final String displayName;

  /// Levenshtein distance (0 = exact).
  final int distance;

  /// How the match was found: 'EXACT', 'CONTAINS', or 'FUZZY'.
  final String matchType;

  /// Human-readable confidence label for the HUD.
  String get confidenceLabel => switch (matchType) {
        'EXACT' => 'EXACT',
        'CONTAINS' => 'EXACT',
        'FUZZY' => 'FUZZY \u2264$distance',
        _ => '',
      };
}

/// Fuzzy text matcher for hearing aid brands and models.
///
/// Uses Levenshtein distance to handle OCR misreads like "oricon" → "oticon"
/// and "movi" → "moxi". Threshold of 2 catches single-character substitutions,
/// insertions, and deletions — the most common OCR failure modes on small
/// printed text.
class BrandMatcher {
  BrandMatcher._();

  /// Known hearing aid manufacturers, lowercase → display name.
  ///
  /// Includes aliases for common OCR misreads and legacy brand names.
  /// Public so DeviceIndex can merge these aliases into the catalog index.
  static const brands = <String, String>{
    // Primary brands (from our device catalog)
    'oticon': 'Oticon',
    'phonak': 'Phonak',
    'signia': 'Signia',
    'widex': 'Widex',
    'resound': 'ReSound',
    'starkey': 'Starkey',
    'unitron': 'Unitron',
    'bernafon': 'Bernafon',
    'beltone': 'Beltone',
    'rexton': 'Rexton',
    'hansaton': 'Hansaton',
    'jabra': 'Jabra',
    'philips': 'Philips',
    'amplifon': 'Amplifon',
    // Aliases and legacy names
    'siemens': 'Signia', // Siemens hearing aids rebranded to Signia
    'gn resound': 'ReSound',
    'gn hearing': 'ReSound',
    'blamey saunders': 'Blamey Saunders',
    'blamey & saunders': 'Blamey Saunders',
    'specsavers': 'Specsavers Advance',
    'hearing australia': 'Hearing Australia',
    // Demant group brands
    'sonic': 'Sonic',
    'sonic innovations': 'Sonic',
  };

  /// Minimum text length to attempt matching. Short strings produce
  /// too many false positives with Levenshtein distance ≤ 2.
  static const _minLength = 4;

  /// Maximum Levenshtein distance for a fuzzy match.
  static const _maxDistance = 2;

  /// Simple brand match (backwards compatible) — returns display name or null.
  static String? matchBrand(String text) {
    return matchBrandDetailed(text)?.displayName;
  }

  /// Detailed brand match — returns match result with confidence info.
  static BrandMatchResult? matchBrandDetailed(String text) {
    final normalized = text.toLowerCase().trim();
    if (normalized.length < _minLength) return null;

    // Exact match (handles multi-word brands too)
    final exact = brands[normalized];
    if (exact != null) {
      return BrandMatchResult(
          displayName: exact, distance: 0, matchType: 'EXACT');
    }

    // Check if the text contains a brand name as a substring
    for (final entry in brands.entries) {
      if (normalized.contains(entry.key)) {
        return BrandMatchResult(
            displayName: entry.value, distance: 0, matchType: 'CONTAINS');
      }
      if (entry.key.contains(normalized) && normalized.length >= 5) {
        return BrandMatchResult(
            displayName: entry.value, distance: 0, matchType: 'CONTAINS');
      }
    }

    // Fuzzy match against single-word brands only
    for (final entry in brands.entries) {
      if (entry.key.contains(' ')) continue;
      if ((normalized.length - entry.key.length).abs() > _maxDistance) continue;
      final dist = _levenshtein(normalized, entry.key);
      if (dist <= _maxDistance) {
        return BrandMatchResult(
            displayName: entry.value, distance: dist, matchType: 'FUZZY');
      }
    }

    return null;
  }

  /// Reverse-lookup: given OCR text, check if it matches a known model
  /// across ALL brands. Returns (brand, modelText) if found.
  ///
  /// This allows model text like "moxi2 kiss" to identify both the brand
  /// (Unitron) and the model, even when the brand name isn't visible.
  ///
  /// More conservative than brand-specific matching — only matches
  /// distinctive model names (5+ chars) to avoid false positives like
  /// random text matching "nera", "key", "own", etc.
  static ({String brand, String model})? matchModelAnyBrand(String text) {
    final normalized = text.trim();
    if (normalized.length < 4 || normalized.length > 30) return null;
    final lower = normalized.toLowerCase();

    // Brand/model disambiguation: a whole token that is itself a (fuzzy)
    // brand name is far more likely a misread brand than a misread model.
    // "oricon" is Levenshtein-1 from BOTH the brand "Oticon" and Signia's
    // model "Orion" — without this guard the fuzzy model branch below wins,
    // locks the wrong brand (Signia) FROM MODEL, and the DeviceIndex
    // override guard then refuses to self-correct when the clean "nera"
    // signal arrives. Brand names are the primary printed signal, so when
    // the token reads as a brand we suppress the *fuzzy* model branch and
    // let the caller's direct brand-matching step claim it. Exact and
    // substring model matches are left untouched (e.g. "oticon ino" still
    // yields the Ino model) — only the approximate whole-token branch is
    // gated. See feedback_elimination_tree_backtracking + the B2 fixture
    // in scan_replay_harness_test.dart.
    final tokenLooksLikeBrand = matchBrand(normalized) != null;

    for (final entry in modelPatterns.entries) {
      final brandKey = entry.key;
      for (final pattern in entry.value) {
        String? brandName;

        // Exact match: any length — "Ino" exactly matches "ino"
        if (lower == pattern) {
          brandName = brands[brandKey];
        }
        // Substring: 4+ chars is reliable (catches "moxi" in "moxi2 kiss")
        else if (pattern.length >= 4 && lower.contains(pattern)) {
          brandName = brands[brandKey];
        }
        // Fuzzy: 5+ chars only to avoid false positives on short words —
        // and never when the token already reads as a brand name.
        else if (pattern.length >= 5 &&
            !tokenLooksLikeBrand &&
            _levenshtein(lower, pattern) <= 1) {
          brandName = brands[brandKey];
        }

        if (brandName == null) continue;

        // Clean the model name: extract just the model portion.
        // OCR often reads brand+model as one garbled word:
        //   "otconActo" → should be "Acto" (brand "oticon" is garbled)
        //   "phonakaudeo" → should be "audeo"
        //
        // Strategy: find where the pattern starts and extract from there.
        var model = normalized;
        final patIdx = lower.indexOf(pattern);
        if (patIdx > 0) {
          // Pattern is embedded — extract from pattern start onward
          // e.g. "otconActo" with pattern "acto" → "Acto"
          model = normalized.substring(patIdx);
        } else if (patIdx == 0 && normalized.length > pattern.length) {
          // Pattern is at the start — take the whole thing
          model = normalized;
        }
        // If model is still the full garbled text and contains brand,
        // use just the capitalized pattern as a clean display name
        if (model.length > pattern.length + 3 && model.toLowerCase().contains(brandKey)) {
          model = pattern[0].toUpperCase() + pattern.substring(1);
        }
        if (model.isEmpty) {
          model = pattern[0].toUpperCase() + pattern.substring(1);
        }

        return (brand: brandName, model: model);
      }
    }

    return null;
  }

  /// Try to extract a model identifier from [text] given a known [brand].
  ///
  /// If the text contains the brand name as a prefix (e.g. "Oticon Ino"),
  /// it's stripped so the model value is clean (e.g. "Ino" not "Oticon Ino").
  static String? matchModel(String text, String brand) {
    final normalized = text.trim();
    if (normalized.length < 3 || normalized.length > 30) return null;

    // Don't match the brand itself as a model
    if (normalized.toLowerCase() == brand.toLowerCase()) return null;

    final patterns = modelPatterns[brand.toLowerCase()];
    if (patterns == null) return null;

    // Strip brand prefix if present (e.g. "Oticon Ino" → "Ino")
    var candidate = normalized;
    final lower = candidate.toLowerCase();
    final brandLower = brand.toLowerCase();
    if (lower.startsWith(brandLower)) {
      candidate = candidate.substring(brand.length).trim();
      if (candidate.isEmpty) return null; // was just the brand name
    }

    final candidateLower = candidate.toLowerCase();
    for (final pattern in patterns) {
      // Substring match: any length pattern works if text is long enough
      if (candidateLower.contains(pattern)) return candidate;
      // Fuzzy: only for 4+ char patterns to avoid false positives
      if (pattern.length >= 4 && _levenshtein(candidateLower, pattern) <= 1) {
        return candidate;
      }
    }

    return null;
  }

  /// Common model name fragments by brand (lowercase).
  ///
  /// Verified against manufacturer product lines 2026-04-22.
  /// Each entry is a real product name that might appear printed on
  /// a hearing aid or its packaging.
  /// Public so DeviceIndex can merge these into the catalog index.
  static const modelPatterns = <String, List<String>>{
    'oticon': [
      // Current
      'real', 'more', 'intent', 'zircon', 'zeal', 'xceed', 'play', 'own',
      // Recent
      'opn s', 'opn', 'siya', 'ruby', 'ria',
      // Legacy (still in circulation)
      'nera', 'alta', 'agil', 'acto', 'ino', 'dynamo', 'sensei', 'safari',
      'chili', 'sumo',
    ],
    'phonak': [
      // Current
      'audeo', 'audéo', 'naida', 'naída', 'virto', 'infinio', 'sphere',
      'lumity', 'slim', 'terra',
      // Recent
      'paradise', 'marvel', 'belong', 'venture', 'bolero', 'sky',
      // Legacy
      'ambra', 'solana', 'cassia', 'dalia', 'baseo', 'exelia',
      'cerena', 'nathos', 'quest', 'lyric', 'brio', 'cros',
    ],
    'signia': [
      // Current
      'pure', 'styletto', 'silk', 'motion', 'insio', 'active',
      // Entry-level
      'intuis', 'prompt',
      // Legacy
      'cellion', 'carat', 'orion',
    ],
    'widex': [
      // Current
      'moment', 'allure', 'smartric', 'magnify',
      // Recent
      'evoke', 'beyond', 'unique',
      // Legacy
      'dream', 'super', 'clear',
    ],
    'resound': [
      // Current
      'nexia', 'vivia', 'savi', 'omnia', 'one', 'key',
      // Recent
      'linx', 'enzo', 'quattro',
      // Legacy
      'verso', 'enya', 'alera',
    ],
    'starkey': [
      // Current
      'genesis', 'omega', 'edge', 'signature', 'evolv',
      // Recent
      'livio', 'muse', 'halo',
      // Legacy
      'picasso',
    ],
    'unitron': [
      // Current
      'vivante', 'smile', 'moxi', 'stride', 'insera', 'blu',
      // Recent
      'discover', 'tempus',
    ],
    'bernafon': [
      // Current
      'encanta', 'alpha', 'viron', 'zerena', 'leox',
      // Legacy
      'juna', 'nevara', 'carista',
    ],
    'beltone': [
      // Current
      'envision', 'serene', 'commence', 'achieve', 'imagine',
      'amaze', 'rely',
      // Power
      'boost max', 'boost ultra',
      // Legacy
      'trust', 'legend', 'first',
    ],
    'sonic': [
      'captivate', 'enchant', 'celebrate', 'cheer', 'bliss',
      'charm', 'radiance',
    ],
  };

  /// Standard Levenshtein distance between two strings.
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
        ].reduce(min);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }

    return prev[b.length];
  }
}
