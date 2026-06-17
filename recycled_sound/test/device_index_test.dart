import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/scanner/data/device_catalog.dart';
import 'package:recycled_sound/features/scanner/data/device_index.dart';

void main() {
  // Loading the catalog requires the rootBundle, which needs the
  // TestWidgetsFlutterBinding initialised so AssetManifest.bin can be
  // resolved off the asset bundle.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DetectionState', () {
    test('empty constant has no locked fields', () {
      expect(DetectionState.empty.locked, isEmpty);
      expect(DetectionState.empty.candidateCount, 0);
      expect(DetectionState.empty.filledCount, 0);
      expect(DetectionState.empty.isLocked(DeviceField.brand), isFalse);
      expect(DetectionState.empty.valueOf(DeviceField.brand), isNull);
      expect(DetectionState.empty.fieldOf(DeviceField.brand), isNull);
    });
  });

  group('ContradictionRecord', () {
    test('toString includes field, kept and rejected info', () {
      final r = ContradictionRecord(
        field: DeviceField.brand,
        keptValue: 'Oticon',
        keptConfidence: 'HIGH',
        keptRank: 80,
        rejectedValue: 'Otc',
        rejectedConfidence: 'LOW',
        rejectedRank: 15,
        rejectedSource: DetectionSource.ocr,
        at: DateTime.utc(2026, 5, 19),
      );
      final s = r.toString();
      expect(s, contains('brand'));
      expect(s, contains('Oticon'));
      expect(s, contains('Otc'));
      expect(s, contains('ocr'));
    });
  });

  group('DeviceIndex (catalog-backed)', () {
    late DeviceCatalog catalog;
    late DeviceIndex index;

    setUpAll(() async {
      catalog = DeviceCatalog.instance;
      await catalog.loadFromAsset();
      index = DeviceIndex.instance;
      await index.load(catalog);
    });

    setUp(() {
      // Each test starts with a clean candidate set.
      index.reset();
    });

    test('loads with the catalog and exposes candidate count', () {
      expect(index.isLoaded, isTrue);
      expect(index.candidateCount, greaterThan(0));
    });

    test('narrow by brand reduces candidate set', () {
      final before = index.candidateCount;
      final state =
          index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      expect(state.isLocked(DeviceField.brand), isTrue);
      expect(state.valueOf(DeviceField.brand), 'Phonak');
      expect(index.candidateCount, lessThanOrEqualTo(before));
    });

    test('narrow by unknown brand enters open mode (lock kept)', () {
      index.reset();
      final state = index.narrow(DeviceField.brand, 'TotallyMadeUp');
      expect(state.isLocked(DeviceField.brand), isTrue);
      expect(state.valueOf(DeviceField.brand), 'TotallyMadeUp');
    });

    test('re-narrowing same value is a no-op', () {
      index.reset();
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      final first = index.state;
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      final second = index.state;
      expect(first.candidateCount, second.candidateCount);
    });

    test('override guard rejects weaker confidence', () {
      index.reset();
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      final beforeContradictions = index.contradictions.length;
      // LOW < HIGH so it should be rejected
      index.narrow(DeviceField.brand, 'Oticon',
          confidence: 'LOW', source: DetectionSource.ocr);
      expect(index.state.valueOf(DeviceField.brand), 'Phonak');
      expect(
          index.contradictions.length, greaterThan(beforeContradictions));
      expect(index.contradictionsByField['brand'], greaterThan(0));
    });

    test('two consistent contradictions re-open the locked field', () {
      // The contradiction-aware re-open (issue #733): a WRONG early lock
      // emits the SAME contradicting value repeatedly. The first equal/lower
      // -rank rejection is held (could be noise); the second is steady
      // evidence and must re-open the field so the correct value narrows in.
      index.reset();
      // Lock a wrong brand with a non-trivial confidence.
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      // First clean-but-lower-rank contradiction — rejected, lock stands.
      index.narrow(DeviceField.brand, 'Oticon',
          confidence: 'LOW', source: DetectionSource.ocr);
      expect(index.state.valueOf(DeviceField.brand), 'Phonak',
          reason: 'a single contradiction must not break the lock');
      // Second consistent contradiction — threshold reached, re-open + apply.
      index.narrow(DeviceField.brand, 'Oticon',
          confidence: 'LOW', source: DetectionSource.ocr);
      expect(index.state.valueOf(DeviceField.brand), 'Oticon',
          reason: 'the SAME contradicting value, twice, must re-open the '
              'field and narrow in (ratchet broken)');
    });

    test('oscillating contradictions never trip the re-open (anti-flap '
        'invariant is frame-rate invariant)', () {
      // This is the property the COUNT threshold actually guarantees, and
      // the regression that protects it from silent erosion: FLAPPING
      // oscillates between competing values, so no SINGLE value ever
      // accumulates _kReopenThreshold rejections — no matter how many frames
      // pass. The lock must therefore survive an arbitrarily long alternating
      // barrage. (Contrast with the test above, where one value repeats.)
      index.reset();
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');

      // 20 frames of two DIFFERENT weaker contradictions, alternating.
      // Each value is only ever seen on every other frame, so neither
      // reaches a count of 2 — the anti-flap shape, independent of frame rate.
      for (var i = 0; i < 10; i++) {
        index.narrow(DeviceField.brand, 'Oticon',
            confidence: 'LOW', source: DetectionSource.ocr);
        index.narrow(DeviceField.brand, 'Widex',
            confidence: 'LOW', source: DetectionSource.ocr);
      }

      expect(index.state.valueOf(DeviceField.brand), 'Phonak',
          reason: 'oscillating (flapping) contradictions must never break the '
              'lock, however many frames elapse — the count threshold keys on '
              'per-value consistency, not elapsed frames');
    });

    test('a different contradiction between repeats resets the consecutive '
        'run (#778)', () {
      // The consecutive-run semantics in close-up: Oticon, then Widex, then
      // Oticon again. Cumulative counting would re-open on the 2nd Oticon
      // (count reaches 2); consecutive counting must NOT, because Widex broke
      // Oticon's run. The lock holds — only an UNINTERRUPTED pair re-opens.
      index.reset();
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      index.narrow(DeviceField.brand, 'Oticon',
          confidence: 'LOW', source: DetectionSource.ocr); // Oticon run = 1
      index.narrow(DeviceField.brand, 'Widex',
          confidence: 'LOW', source: DetectionSource.ocr); // resets Oticon
      index.narrow(DeviceField.brand, 'Oticon',
          confidence: 'LOW', source: DetectionSource.ocr); // Oticon run = 1
      expect(index.state.valueOf(DeviceField.brand), 'Phonak',
          reason: 'an interrupted (non-consecutive) repeat must not re-open');
    });

    test('a frame that CORROBORATES the lock resets the contradiction run (#88)',
        () {
      // Carnot, #88 cage-match: the run must be broken by a re-read of the LOCK
      // too, not only by a different alternative. Phonak, Oticon(rej), Phonak
      // (corroborates), Oticon(rej): the middle Phonak re-affirms the lock, so
      // Oticon never accumulates two CONSECUTIVE frames — the lock must hold.
      // (Without the corroboration reset this re-opened on the 2nd Oticon.)
      index.reset();
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      index.narrow(DeviceField.brand, 'Oticon',
          confidence: 'LOW', source: DetectionSource.ocr); // Oticon run = 1
      index.narrow(DeviceField.brand, 'Phonak',
          confidence: 'HIGH'); // corroborates lock → resets Oticon's run
      index.narrow(DeviceField.brand, 'Oticon',
          confidence: 'LOW', source: DetectionSource.ocr); // Oticon run = 1
      expect(index.state.valueOf(DeviceField.brand), 'Phonak',
          reason: 'a corroborating read between contradictions breaks the run');
    });

    test('a successful relock clears the old lock\'s stale contradiction counts '
        '(#88)', () {
      // Carnot, #88: counts are per-LOCK. Phonak locked, one Oticon rejection
      // banked; then a STRONGER Widex relocks the field. That relock must clear
      // Oticon's stale count, so a single later Oticon contradiction against the
      // NEW Widex lock does NOT re-open it (it would, if the count carried over).
      index.reset();
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'MEDIUM');
      index.narrow(DeviceField.brand, 'Oticon',
          confidence: 'LOW', source: DetectionSource.ocr); // banked vs Phonak
      index.narrow(DeviceField.brand, 'Widex',
          confidence: 'HIGH'); // stronger → relock, must clear stale counts
      expect(index.state.valueOf(DeviceField.brand), 'Widex',
          reason: 'stronger evidence relocks the field');
      index.narrow(DeviceField.brand, 'Oticon',
          confidence: 'LOW', source: DetectionSource.ocr); // run = 1, not 2
      expect(index.state.valueOf(DeviceField.brand), 'Widex',
          reason: 'a stale count from the previous lock must not re-open the '
              'new one after a single contradiction');
    });

    test('manual override always wins regardless of rank', () {
      index.reset();
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      index.narrow(
        DeviceField.brand,
        'Widex',
        confidence: 'LOW',
        source: DetectionSource.manual,
      );
      expect(index.state.valueOf(DeviceField.brand), 'Widex');
    });

    test('batterySize narrow auto-locks derived power field', () {
      index.reset();
      // Pick a battery value likely to exist in the catalog.
      final possible = index.possibleValues(DeviceField.batterySize);
      if (possible.isEmpty) return;
      final v = possible.firstWhere(
        (e) => e.toLowerCase() == 'rechargeable',
        orElse: () => possible.first,
      );
      index.narrow(DeviceField.batterySize, v, confidence: 'HIGH');
      expect(index.state.isLocked(DeviceField.power), isTrue);
    });

    test('type narrow auto-locks derived tubing', () {
      index.reset();
      final types = index.possibleValues(DeviceField.type);
      if (types.isEmpty) return;
      // BTE → Standard tubing
      final hasBte = types.any((t) => t.toUpperCase().contains('BTE'));
      if (!hasBte) return;
      index.narrow(DeviceField.type, 'BTE', confidence: 'HIGH');
      expect(index.state.isLocked(DeviceField.tubing), isTrue);
      expect(index.state.valueOf(DeviceField.tubing), 'Standard');
    });

    test('possibleValues returns empty for already-locked fields', () {
      index.reset();
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      expect(index.possibleValues(DeviceField.brand), isEmpty);
    });

    test('colour palette is always available', () {
      index.reset();
      final palette = index.possibleValues(DeviceField.colour);
      expect(palette, contains('Beige'));
      expect(palette, contains('Black'));
    });

    test('brandDeviceCount returns >=0 even for unknown brands', () {
      expect(index.brandDeviceCount('NoSuchBrand'), 0);
      expect(index.brandDeviceCount('Phonak'), greaterThan(0));
    });

    test('matchedDevice null when many candidates remain', () {
      index.reset();
      expect(index.matchedDevice, isNull);
    });

    test('stateStream emits after narrow', () async {
      index.reset();
      final f = index.stateStream.first;
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      final s = await f.timeout(const Duration(seconds: 1));
      expect(s.valueOf(DeviceField.brand), 'Phonak');
    });

    test('reset clears contradictions and locked fields', () {
      index.reset();
      index.narrow(DeviceField.brand, 'Phonak', confidence: 'HIGH');
      index.narrow(DeviceField.brand, 'Oticon', confidence: 'LOW');
      expect(index.contradictions, isNotEmpty);
      index.reset();
      expect(index.contradictions, isEmpty);
      expect(index.state.locked, isEmpty);
    });
  });
}
