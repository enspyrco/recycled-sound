import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/scan_result.dart';

/// A single human correction to an AI-identified field.
///
/// Captures enough context for two purposes:
/// 1. **Now**: Improving OCR fuzzy-match patterns in the lookup table
///    (e.g. OCR read "Phona" → user corrected to "Phonak").
/// 2. **Future**: Labeled training data for a custom vision model once
///    thousands of corrections accumulate over time.
class Correction {
  const Correction({
    required this.field,
    required this.originalValue,
    required this.originalConfidence,
    required this.correctedValue,
    required this.rawLabels,
    required this.timestamp,
  });

  /// Which spec field was corrected (e.g. 'brand', 'model').
  final String field;

  /// The AI's original identification.
  final String originalValue;

  /// The AI's confidence before correction (useful for calibration).
  final int originalConfidence;

  /// The human-verified value.
  final String correctedValue;

  /// Raw detection tokens present at scan time — ML Kit OCR lines on the
  /// live path, Vision API labels on the legacy cloud path. Links the
  /// correction back to what the AI "saw", enabling label→value
  /// association learning.
  final List<String> rawLabels;

  final DateTime timestamp;

  Map<String, dynamic> toJson() => {
    'field': field,
    'originalValue': originalValue,
    'originalConfidence': originalConfidence,
    'correctedValue': correctedValue,
    'rawLabels': rawLabels,
    'timestamp': timestamp.toIso8601String(),
  };
}

/// Holds the current scan result in memory, allowing inline edits.
///
/// In the MVP this starts with mock data. Once the Cloud Function is wired up,
/// this will be populated from the Firestore scan document.
class ScanResultNotifier extends Notifier<ScanResult> {
  final List<Correction> _corrections = [];

  @override
  ScanResult build() => ScanResult.mock();

  /// Set the scan result from the real pipeline.
  void setResult(ScanResult result) {
    _corrections.clear();
    state = result;
  }

  /// Update a single spec field and record the correction with full context.
  ///
  /// Takes a [ScanField] enum — the compiler enforces exhaustive handling,
  /// so adding a field to [ScanResult] without updating the read/write
  /// switches is a compile error, not a silent bug.
  void updateField(ScanField field, String newValue) {
    final current = state;
    final oldField = current.fieldFor(field);

    // For fields that start null (tubing, powerSource, colour),
    // record the correction from empty.
    final originalValue = oldField?.value ?? '';
    final originalConfidence = oldField?.confidence ?? 0;
    if (originalValue == newValue) return;

    _corrections.add(
      Correction(
        field: field.name,
        originalValue: originalValue,
        originalConfidence: originalConfidence,
        correctedValue: newValue,
        rawLabels: current.rawLabels,
        timestamp: DateTime.now(),
      ),
    );

    // Update the field with 100% confidence and human provenance. The source
    // stamp is what lets a deliberate "Unknown" verdict be told apart from the
    // AI pipeline's own low-confidence 'Unknown' default downstream.
    final corrected = SpecField(
      value: newValue,
      confidence: 100,
      source: FieldSource.human,
    );
    state = current.withField(field, corrected);
  }

  /// Returns all corrections made during this session.
  List<Correction> get corrections => List.unmodifiable(_corrections);
}

final scanResultProvider = NotifierProvider<ScanResultNotifier, ScanResult>(
  ScanResultNotifier.new,
);
