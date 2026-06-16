import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:recycled_sound/features/scanner/data/models/scan_result.dart';
import 'package:recycled_sound/features/scanner/providers/scanner_providers.dart';

// ScanField enum is exported from scan_result.dart

void main() {
  group('ScanResultNotifier', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
    });

    tearDown(() {
      container.dispose();
    });

    test('initial state is mock data', () {
      final result = container.read(scanResultProvider);
      expect(result.scanId, 'mock-001');
      expect(result.brand.value, 'Phonak');
      expect(result.brand.confidence, 95);
    });

    test('updateField changes value and sets confidence to 100', () {
      final notifier = container.read(scanResultProvider.notifier);
      notifier.updateField(ScanField.brand, 'Oticon');

      final result = container.read(scanResultProvider);
      expect(result.brand.value, 'Oticon');
      expect(result.brand.confidence, 100);
    });

    test('updateField records correction', () {
      final notifier = container.read(scanResultProvider.notifier);
      notifier.updateField(ScanField.model, 'Real 1');

      final corrections = notifier.corrections;
      expect(corrections, hasLength(1));
      expect(corrections.first.field, 'model');
      expect(corrections.first.originalValue, 'Audéo P90');
      expect(corrections.first.correctedValue, 'Real 1');
      expect(corrections.first.originalConfidence, 88);
    });

    test('same value records no correction but still upgrades provenance', () {
      final notifier = container.read(scanResultProvider.notifier);
      // mock brand is AI-sourced 'Phonak'; tapping the same value is a no-op
      // for the value (no correction) but a deliberate human confirmation.
      notifier.updateField(ScanField.brand, 'Phonak');

      final brand = container.read(scanResultProvider).brand;
      expect(notifier.corrections, isEmpty, reason: 'value did not change');
      expect(brand.value, 'Phonak');
      expect(
        brand.source,
        FieldSource.human,
        reason: 'confirming the AI value is still a human act',
      );
    });

    test('confirming an AI Unknown flags it as a volunteer handoff', () {
      // The case Carnot caught: scan fusion emits an AI-sourced 'Unknown' for
      // a field it cannot determine (e.g. batterySize). The volunteer taps the
      // visible Unknown chip — same string value — and that confirmation MUST
      // register as the audiologist handoff, not get swallowed by an early
      // same-value return.
      final notifier = container.read(scanResultProvider.notifier);
      notifier.setResult(
        ScanResult.mock().copyWith(
          batterySize: const SpecField(
            value: kUnknownValue,
            confidence: 10,
            source: FieldSource.ai,
          ),
        ),
      );

      notifier.updateField(ScanField.batterySize, kUnknownValue);

      final result = container.read(scanResultProvider);
      expect(result.batterySize.source, FieldSource.human);
      expect(result.batterySize.isVolunteerUnknown, isTrue);
      expect(result.volunteerUnknownFields, contains(ClinicalField.batterySize));
    });

    // Note: the old "invalid field does nothing" test is no longer needed —
    // ScanField is an enum, so the compiler prevents invalid field names.

    test('multiple corrections are tracked in order', () {
      final notifier = container.read(scanResultProvider.notifier);
      notifier.updateField(ScanField.brand, 'Signia');
      notifier.updateField(ScanField.type, 'BTE');
      notifier.updateField(ScanField.batterySize, '13');

      final corrections = notifier.corrections;
      expect(corrections, hasLength(3));
      expect(corrections[0].field, 'brand');
      expect(corrections[1].field, 'type');
      expect(corrections[2].field, 'batterySize');
    });

    test('corrections include raw labels from scan', () {
      final notifier = container.read(scanResultProvider.notifier);
      notifier.updateField(ScanField.brand, 'Widex');

      final correction = notifier.corrections.first;
      expect(correction.rawLabels, isNotEmpty);
      expect(correction.rawLabels, contains('hearing aid'));
      expect(correction.rawLabels, contains('Phonak'));
    });

    test('correction toJson produces valid map', () {
      final notifier = container.read(scanResultProvider.notifier);
      notifier.updateField(ScanField.year, '2023');

      final json = notifier.corrections.first.toJson();
      expect(json['field'], 'year');
      expect(json['originalValue'], '2021');
      expect(json['correctedValue'], '2023');
      expect(json['originalConfidence'], 75);
      expect(json['rawLabels'], isList);
      expect(json['timestamp'], isA<String>());
    });
  });

  group('ScanResult', () {
    test('mock factory creates valid result', () {
      final result = ScanResult.mock();
      expect(result.scanId, 'mock-001');
      expect(result.brand.value, isNotEmpty);
      expect(result.rawLabels, isNotEmpty);
    });

    test('copyWith preserves unchanged fields', () {
      final original = ScanResult.mock();
      final updated = original.copyWith(
        brand: const SpecField(value: 'Oticon', confidence: 100),
      );

      expect(updated.brand.value, 'Oticon');
      expect(updated.model.value, original.model.value); // unchanged
      expect(updated.scanId, original.scanId); // unchanged
    });

    test('SpecField fromJson/toJson roundtrip', () {
      const field = SpecField(value: 'Phonak', confidence: 95);
      final json = field.toJson();
      final restored = SpecField.fromJson(json);

      expect(restored.value, field.value);
      expect(restored.confidence, field.confidence);
    });

    test('ScanResult fromJson creates valid object', () {
      final json = {
        'scanId': 'test-123',
        'imageUrl': 'https://example.com/img.jpg',
        'brand': {'value': 'Phonak', 'confidence': 90},
        'model': {'value': 'P90', 'confidence': 85},
        'type': {'value': 'RIC', 'confidence': 80},
        'year': {'value': '2021', 'confidence': 70},
        'batterySize': {'value': '312', 'confidence': 75},
        'domeType': {'value': 'Closed', 'confidence': 60},
        'waxFilter': {'value': 'CeruShield', 'confidence': 55},
        'receiver': {'value': 'M', 'confidence': 65},
        'rawLabels': ['hearing aid', 'medical'],
      };

      final result = ScanResult.fromJson(json);
      expect(result.scanId, 'test-123');
      expect(result.brand.value, 'Phonak');
      expect(result.rawLabels, hasLength(2));
    });
  });
}
