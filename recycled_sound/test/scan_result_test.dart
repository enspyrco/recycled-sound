import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/scanner/data/models/scan_result.dart';

void main() {
  group('SpecField', () {
    test('copyWith only overrides what is supplied', () {
      const s = SpecField(value: 'x', confidence: 50);
      final a = s.copyWith(value: 'y');
      expect(a.value, 'y');
      expect(a.confidence, 50);
      final b = s.copyWith(confidence: 90);
      expect(b.value, 'x');
      expect(b.confidence, 90);
    });

    test('toJson / fromJson round-trips', () {
      const s = SpecField(value: 'Phonak', confidence: 88);
      final j = s.toJson();
      expect(j['value'], 'Phonak');
      expect(j['confidence'], 88);
      final round = SpecField.fromJson(j);
      expect(round.value, s.value);
      expect(round.confidence, s.confidence);
    });

    test('isUnknown is true only for the Unknown sentinel', () {
      expect(const SpecField(value: kUnknownValue, confidence: 0).isUnknown,
          isTrue);
      // A determinate absence is NOT Unknown — these are facts, not flags.
      expect(const SpecField(value: 'None', confidence: 0).isUnknown, isFalse);
      expect(const SpecField(value: 'N/A', confidence: 0).isUnknown, isFalse);
      expect(const SpecField(value: '', confidence: 0).isUnknown, isFalse);
      expect(const SpecField(value: 'BTE', confidence: 90).isUnknown, isFalse);
    });
  });

  group('ScanResult mock + accessors', () {
    final m = ScanResult.mock();

    test('mock has expected scaffolding values', () {
      expect(m.scanId, isNotEmpty);
      expect(m.brand.value, 'Phonak');
      expect(m.model.value, 'Audéo P90');
      expect(m.type.value, 'RIC');
    });

    test('sevenFields returns 7 entries in audiologist order', () {
      final keys = m.sevenFields.map((f) => f.key).toList();
      expect(keys, [
        'brand',
        'model',
        'type',
        'tubing',
        'powerSource',
        'batterySize',
        'colour',
      ]);
    });

    test('filledFieldCount excludes empty and dash values', () {
      // Mock has empty batterySize → that one isn't filled.
      expect(m.filledFieldCount, lessThan(7));
    });

    test('isComplete is false on mock', () {
      expect(m.isComplete, isFalse);
    });

    test('fieldFor returns the expected SpecField per enum', () {
      expect(m.fieldFor(ScanField.brand), m.brand);
      expect(m.fieldFor(ScanField.colour), m.colour);
      expect(m.fieldFor(ScanField.tubing), m.tubing);
      expect(m.fieldFor(ScanField.powerSource), m.powerSource);
    });

    test('withField replaces the targeted field, leaves others intact', () {
      const v = SpecField(value: 'Oticon', confidence: 95);
      final r = m.withField(ScanField.brand, v);
      expect(r.brand, v);
      expect(r.model, m.model);
      // Each enum variant compiles
      for (final f in ScanField.values) {
        final r2 = m.withField(f, const SpecField(value: 'x', confidence: 50));
        expect(r2.fieldFor(f)?.value, 'x');
      }
    });
  });

  group('ScanResult Unknown-field handling', () {
    // Fill all 7 fields, leaving `tubing` flagged Unknown — the exact case
    // Delia raised: the scanner can't determine tubing, so without an Unknown
    // escape valve the completion gate would stall forever.
    ScanResult complete({String tubing = 'Slim'}) {
      var r = ScanResult.mock();
      const filled = SpecField(value: 'x', confidence: 80);
      for (final f in [
        ScanField.brand,
        ScanField.model,
        ScanField.type,
        ScanField.powerSource,
        ScanField.batterySize,
        ScanField.colour,
      ]) {
        r = r.withField(f, filled);
      }
      return r.withField(
        ScanField.tubing,
        SpecField(value: tubing, confidence: 0),
      );
    }

    test('an Unknown flag counts toward completion — no stall', () {
      final r = complete(tubing: kUnknownValue);
      expect(r.isComplete, isTrue,
          reason: 'Unknown must satisfy the gate so the volunteer can proceed');
    });

    test('unknownFieldCount counts only Unknown-flagged fields', () {
      expect(complete(tubing: kUnknownValue).unknownFieldCount, 1);
      expect(complete(tubing: 'Slim').unknownFieldCount, 0);
    });

    test('isFullyVerified distinguishes complete from confirmed', () {
      final flagged = complete(tubing: kUnknownValue);
      expect(flagged.isComplete, isTrue);
      expect(flagged.isFullyVerified, isFalse,
          reason: 'complete-but-unverified: still needs the audiologist');

      final confirmed = complete(tubing: 'Slim');
      expect(confirmed.isFullyVerified, isTrue);
    });
  });

  group('ScanResult JSON round-trip', () {
    test('mock survives toJson → fromJson', () {
      final json = ScanResult.mock().toJson();
      final r = ScanResult.fromJson(json);
      expect(r.scanId, 'mock-001');
      expect(r.brand.value, 'Phonak');
      expect(r.colour?.value, 'Champagne');
      expect(r.rawLabels, hasLength(4));
    });

    test('fromJson tolerates missing optionals', () {
      final r = ScanResult.fromJson({
        'scanId': 's',
        'imageUrl': 'i',
        'brand': {'value': 'B', 'confidence': 50},
        'model': {'value': 'M', 'confidence': 40},
        'type': {'value': 'T', 'confidence': 30},
        'year': {'value': 'Y', 'confidence': 20},
        'batterySize': {'value': '', 'confidence': 0},
        'domeType': {'value': '', 'confidence': 0},
        'waxFilter': {'value': '', 'confidence': 0},
        'receiver': {'value': '', 'confidence': 0},
      });
      expect(r.colour, isNull);
      expect(r.tubing, isNull);
      expect(r.powerSource, isNull);
      expect(r.rawLabels, isEmpty);
    });
  });

  group('ScanResult.copyWith', () {
    test('overrides only the named field', () {
      final m = ScanResult.mock();
      final r = m.copyWith(scanId: 'new-id');
      expect(r.scanId, 'new-id');
      expect(r.brand, m.brand);
    });
  });
}
