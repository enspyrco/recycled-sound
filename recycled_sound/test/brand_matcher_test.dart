import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/scanner/data/brand_matcher.dart';

/// Tests for BrandMatcher: fuzzy/exact/contains brand recognition + model
/// lookup. The matcher is pure logic — no I/O, no async — so we exercise
/// every public surface.
void main() {
  group('BrandMatcher.matchBrand', () {
    test('exact lowercase brand name', () {
      expect(BrandMatcher.matchBrand('oticon'), 'Oticon');
      expect(BrandMatcher.matchBrand('phonak'), 'Phonak');
      expect(BrandMatcher.matchBrand('widex'), 'Widex');
    });

    test('exact match is case-insensitive', () {
      expect(BrandMatcher.matchBrand('OTICON'), 'Oticon');
      expect(BrandMatcher.matchBrand('PhOnAk'), 'Phonak');
    });

    test('returns null for text below min length', () {
      expect(BrandMatcher.matchBrand('ok'), isNull);
      expect(BrandMatcher.matchBrand('abc'), isNull);
    });

    test('aliases resolve to canonical brand', () {
      expect(BrandMatcher.matchBrand('siemens'), 'Signia');
      expect(BrandMatcher.matchBrand('gn resound'), 'ReSound');
      expect(BrandMatcher.matchBrand('blamey & saunders'), 'Blamey Saunders');
    });

    test('substring match catches embedded brand', () {
      // "phonakaudeo" should match phonak via contains
      expect(BrandMatcher.matchBrand('phonakaudeo'), 'Phonak');
    });

    test('fuzzy match handles single-char OCR misreads', () {
      // "oricon" → "oticon" (1 substitution)
      expect(BrandMatcher.matchBrand('oricon'), 'Oticon');
      // "phonac" → "phonak" (1 substitution)
      expect(BrandMatcher.matchBrand('phonac'), 'Phonak');
    });

    test('fuzzy match rejects strings beyond distance 2', () {
      expect(BrandMatcher.matchBrand('xyzqwer'), isNull);
      expect(BrandMatcher.matchBrand('zzzzzzz'), isNull);
    });

    test('returns null for unknown text', () {
      expect(BrandMatcher.matchBrand('something-completely-different'),
          isNull);
    });
  });

  group('BrandMatcher.matchBrandDetailed', () {
    test('exact match has distance 0 and EXACT type', () {
      final r = BrandMatcher.matchBrandDetailed('oticon')!;
      expect(r.displayName, 'Oticon');
      expect(r.distance, 0);
      expect(r.matchType, 'EXACT');
      expect(r.confidenceLabel, 'EXACT');
    });

    test('substring match has CONTAINS type', () {
      final r = BrandMatcher.matchBrandDetailed('phonakaudeo')!;
      expect(r.matchType, 'CONTAINS');
      // CONTAINS shares the EXACT confidence label
      expect(r.confidenceLabel, 'EXACT');
    });

    test('fuzzy match has FUZZY type with distance', () {
      final r = BrandMatcher.matchBrandDetailed('oricon')!;
      expect(r.matchType, 'FUZZY');
      expect(r.distance, greaterThanOrEqualTo(1));
      expect(r.confidenceLabel, contains('FUZZY'));
    });

    test('unknown returns null', () {
      expect(BrandMatcher.matchBrandDetailed('xx'), isNull);
      expect(BrandMatcher.matchBrandDetailed('asdfasdfasdf'), isNull);
    });

    test('confidenceLabel default for unknown matchType', () {
      const r = BrandMatchResult(
          displayName: 'X', distance: 0, matchType: 'OTHER');
      expect(r.confidenceLabel, '');
    });
  });

  group('BrandMatcher.matchModelAnyBrand', () {
    test('exact pattern of length 4+ hits (e.g. "moxi" → Unitron)', () {
      // Function requires length >= 4 (see matchModelAnyBrand impl).
      final r = BrandMatcher.matchModelAnyBrand('moxi');
      expect(r, isNotNull);
      expect(r!.brand, 'Unitron');
    });

    test('substring catches "moxi2 kiss" as Unitron', () {
      final r = BrandMatcher.matchModelAnyBrand('moxi2 kiss');
      expect(r, isNotNull);
      expect(r!.brand, 'Unitron');
    });

    test('fuzzy 5+ char patterns catch "audeoo" as Phonak', () {
      final r = BrandMatcher.matchModelAnyBrand('audeoo');
      expect(r, isNotNull);
      expect(r!.brand, 'Phonak');
    });

    test('embedded pattern with garbled prefix: "otconActo"', () {
      final r = BrandMatcher.matchModelAnyBrand('otconActo');
      expect(r, isNotNull);
      expect(r!.brand, 'Oticon');
      // Model should be cleaned to extract from the pattern start
      expect(r.model.toLowerCase(), contains('acto'));
    });

    test('returns null below min/max length', () {
      expect(BrandMatcher.matchModelAnyBrand('ab'), isNull);
      expect(BrandMatcher.matchModelAnyBrand('x' * 40), isNull);
    });

    test('returns null for unrelated text', () {
      expect(BrandMatcher.matchModelAnyBrand('completelyrandomxyz'), isNull);
    });
  });

  group('BrandMatcher.matchModel', () {
    test('exact model in brand line', () {
      expect(BrandMatcher.matchModel('audeo', 'Phonak'), 'audeo');
      expect(BrandMatcher.matchModel('moxi', 'Unitron'), 'moxi');
    });

    test('strips brand prefix from text', () {
      expect(BrandMatcher.matchModel('Oticon Ino', 'Oticon'), 'Ino');
    });

    test('returns null when text equals brand', () {
      expect(BrandMatcher.matchModel('oticon', 'Oticon'), isNull);
    });

    test('returns null when brand has no patterns', () {
      expect(BrandMatcher.matchModel('foo', 'UnknownBrand'), isNull);
    });

    test('out-of-range length returns null', () {
      expect(BrandMatcher.matchModel('ab', 'Oticon'), isNull);
      expect(BrandMatcher.matchModel('x' * 40, 'Oticon'), isNull);
    });

    test('fuzzy match for 4+ char patterns', () {
      // "naidaz" is 1 char off "naida"
      final r = BrandMatcher.matchModel('naidaz', 'Phonak');
      expect(r, isNotNull);
    });

    test('returns null when only brand prefix is present', () {
      expect(BrandMatcher.matchModel('Oticon ', 'Oticon'), isNull);
    });

    test('returns null when no pattern matches', () {
      expect(BrandMatcher.matchModel('zzzqqqxxx', 'Phonak'), isNull);
    });
  });

  group('BrandMatcher static data', () {
    test('brands map contains expected canonical names', () {
      expect(BrandMatcher.brands['oticon'], 'Oticon');
      expect(BrandMatcher.brands['siemens'], 'Signia');
    });

    test('modelPatterns covers every primary brand', () {
      for (final key in ['oticon', 'phonak', 'signia', 'widex', 'resound']) {
        expect(BrandMatcher.modelPatterns[key], isNotNull);
        expect(BrandMatcher.modelPatterns[key]!, isNotEmpty);
      }
    });
  });
}
