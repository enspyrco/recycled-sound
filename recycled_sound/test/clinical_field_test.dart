import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/core/clinical_field.dart';
import 'package:recycled_sound/features/devices/data/models/device.dart';

void main() {
  group('ClinicalField wire format', () {
    test('every field round-trips through its wire string', () {
      for (final f in ClinicalField.values) {
        expect(ClinicalField.fromWire(f.wire), f,
            reason: '${f.name} must parse back from its own wire string');
      }
    });

    test('wire strings are the exact legacy keys (backward-compat)', () {
      // These are the strings already persisted in Firestore docs. Changing
      // any of them silently orphans the "needs input" flag on existing
      // incoming/ and devices/ records — so this is a frozen contract.
      expect(ClinicalField.values.map((f) => f.wire).toList(), [
        'brand',
        'model',
        'type',
        'tubing',
        'powerSource',
        'batterySize',
        'colour',
      ]);
    });

    test('labels match the audiologist-facing vocabulary', () {
      expect(ClinicalField.brand.label, 'Make');
      expect(ClinicalField.type.label, 'Style');
      expect(ClinicalField.batterySize.label, 'Battery Size');
      expect(ClinicalField.powerSource.label, 'Power');
    });

    test('fromWire is tolerant — unknown/legacy/null → null, never throws', () {
      // 'make'/'style'/'battery' are the INVENTED keys PR #85 accidentally used
      // — they are NOT the wire vocabulary and must not resolve to a field.
      for (final bogus in ['make', 'style', 'battery', '', 'YEAR', null]) {
        expect(ClinicalField.fromWire(bogus), isNull,
            reason: '"$bogus" is not a real wire key');
      }
    });
  });

  group('ClinicalField.parseList (Firestore tolerance)', () {
    test('parses a clean list preserving order', () {
      expect(
        ClinicalField.parseList(['colour', 'tubing']),
        [ClinicalField.colour, ClinicalField.tubing],
      );
    });

    test('drops garbage/legacy entries instead of throwing', () {
      // A real-world degraded doc: a valid key, an invented key, a non-string,
      // and null all in one array. Parse degrades to what it understands.
      expect(
        ClinicalField.parseList(['tubing', 'make', 42, null, 'colour']),
        [ClinicalField.tubing, ClinicalField.colour],
      );
    });

    test('null / non-list / empty → empty list', () {
      expect(ClinicalField.parseList(null), isEmpty);
      expect(ClinicalField.parseList('tubing'), isEmpty); // not a List
      expect(ClinicalField.parseList(const []), isEmpty);
    });

    test('parseList ∘ toWireList is identity for real fields', () {
      const fields = [
        ClinicalField.brand,
        ClinicalField.powerSource,
        ClinicalField.colour,
      ];
      expect(ClinicalField.parseList(fields.toWireList()), fields);
    });
  });

  group('ClinicalField.partition (fail-closed at the trust boundary)', () {
    test('splits recognised fields from unknown keys, both retained', () {
      final p = ClinicalField.partition(['tubing', 'make', 'colour', 'year']);
      expect(p.known, [ClinicalField.tubing, ClinicalField.colour]);
      // Unknown keys are RETAINED (not dropped) so a downstream gate can block.
      expect(p.unknown, ['make', 'year']);
    });

    test('non-string entries are recorded as strings, never vanish', () {
      final p = ClinicalField.partition(['tubing', 42, null]);
      expect(p.known, [ClinicalField.tubing]);
      expect(p.unknown, ['42', 'null']);
    });

    test('null / non-list → empty buckets', () {
      final p = ClinicalField.partition(null);
      expect(p.known, isEmpty);
      expect(p.unknown, isEmpty);
    });
  });

  group('Device.reviewForPromotion (the trust-boundary gate)', () {
    const resolved = Device(id: 'd', brand: 'Phonak', model: 'P90');
    const flagged = Device(
      id: 'd',
      brand: 'Phonak',
      model: 'P90',
      needsInputFields: [ClinicalField.tubing, ClinicalField.colour],
    );

    test('no unresolved fields → Promotable carrying the device', () {
      final verdict = resolved.reviewForPromotion();
      expect(verdict, isA<Promotable>());
      expect((verdict as Promotable).device.id, 'd');
    });

    test('unresolved fields → NeedsResolution naming exactly those fields', () {
      final verdict = flagged.reviewForPromotion();
      expect(verdict, isA<NeedsResolution>());
      expect((verdict as NeedsResolution).unresolved,
          [ClinicalField.tubing, ClinicalField.colour]);
    });

    test('FAILS CLOSED on an unrecognised persisted blocker key', () {
      // The Carnot catch (PR #86): a device whose ONLY blocker is a key we
      // can't interpret must NOT be promotable. Dropping it would fail open.
      const garbage = Device(
        id: 'd',
        brand: 'Phonak',
        model: 'P90',
        unrecognisedNeedsInput: ['make'], // an invented/legacy key
      );
      final verdict = garbage.reviewForPromotion();
      expect(verdict, isA<NeedsResolution>());
      expect((verdict as NeedsResolution).unresolved, isEmpty);
      expect(verdict.unrecognised, ['make']);
    });

    test('a sealed switch must handle both arms (compile-time exhaustiveness)',
        () {
      // Documents the safety property: there is no third state, and a caller
      // cannot obtain a promotable device while fields remain unresolved. The
      // switch below would not compile if a new arm were added unhandled.
      String describe(PromotionVerdict v) => switch (v) {
            Promotable() => 'promote',
            NeedsResolution() => 'block',
          };
      expect(describe(resolved.reviewForPromotion()), 'promote');
      expect(describe(flagged.reviewForPromotion()), 'block');
    });
  });
}
