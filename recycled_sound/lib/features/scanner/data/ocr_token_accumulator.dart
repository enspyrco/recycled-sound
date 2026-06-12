import 'dart:collection';

/// Accumulates the OCR text tokens seen during a live scan session so
/// they can be attached to the [ScanResult] as `rawLabels`.
///
/// Corrections made on the confirm screen copy `rawLabels` from the
/// current result — that's what links a human correction back to what
/// the AI actually "saw" (e.g. OCR read "oricon", human corrected brand
/// to "Oticon"). Without this, correction docs carry an empty list and
/// the training-data flywheel loses its evidence.
///
/// Design constraints:
/// - Called from `_processFrame` for every OCR line, so adds must be
///   cheap: one map remove + insert, no per-call allocation.
/// - Bounded: keeps at most [capacity] unique tokens. Re-seeing a token
///   refreshes its recency, so eviction drops the stalest reading first
///   (e.g. desk clutter read before the device was in frame).
/// - Case-insensitive dedupe, keeping the most recent casing — OCR
///   casing flickers frame to frame ("OTICON" / "Oticon").
class OcrTokenAccumulator {
  OcrTokenAccumulator({this.capacity = 50});

  /// Maximum number of unique tokens retained.
  final int capacity;

  /// Lowercased token → most recently seen original casing,
  /// in least-recently-seen-first order.
  final LinkedHashMap<String, String> _tokens =
      LinkedHashMap<String, String>();

  /// Records one OCR line. Trims whitespace; ignores tokens shorter
  /// than 2 characters (matches the frame loop's own filter).
  void add(String text) {
    final trimmed = text.trim();
    if (trimmed.length < 2) return;
    final key = trimmed.toLowerCase();
    // Remove-then-insert moves the token to the most-recent end.
    _tokens.remove(key);
    _tokens[key] = trimmed;
    if (_tokens.length > capacity) {
      _tokens.remove(_tokens.keys.first);
    }
  }

  /// The retained tokens, least recently seen first.
  List<String> get tokens => List.unmodifiable(_tokens.values);
}
