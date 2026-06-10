import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/scanner/data/device_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DeviceCatalog catalog;

  setUpAll(() async {
    catalog = DeviceCatalog.instance;
    await catalog.loadFromAsset();
  });

  group('DeviceCatalog loading', () {
    test('reports loaded with non-zero counts', () {
      expect(catalog.isLoaded, isTrue);
      expect(catalog.deviceCount, greaterThan(0));
      expect(catalog.embeddingCount, greaterThan(0));
      expect(catalog.allDevices, isNotEmpty);
    });

    test('repeat load is a no-op', () async {
      final beforeCount = catalog.deviceCount;
      await catalog.loadFromAsset();
      expect(catalog.deviceCount, beforeCount);
    });
  });

  group('Lookups', () {
    test('deviceIdsForEmbedding returns ids for an in-range index', () {
      final ids = catalog.deviceIdsForEmbedding(0);
      expect(ids, isNotEmpty);
    });

    test('deviceIdsForEmbedding returns empty for out-of-range', () {
      expect(catalog.deviceIdsForEmbedding(-1), isEmpty);
      expect(
        catalog.deviceIdsForEmbedding(catalog.embeddingCount + 100),
        isEmpty,
      );
    });

    test('getDevice round-trips a known id', () {
      final id = catalog.deviceIdsForEmbedding(0).first;
      final d = catalog.getDevice(id);
      expect(d, isNotNull);
      expect(d!.id, id);
      expect(d.manufacturer, isNotEmpty);
    });

    test('getDevice unknown id returns null', () {
      expect(catalog.getDevice('not-a-real-id'), isNull);
    });

    test('findByBrand returns >0 ids for Phonak/Oticon', () {
      // At least one of the canonical brands should be in the catalog.
      final phonak = catalog.findByBrand('Phonak');
      final oticon = catalog.findByBrand('Oticon');
      expect(phonak.length + oticon.length, greaterThan(0));
    });

    test('findByBrand unknown brand returns empty', () {
      expect(catalog.findByBrand('TotallyMadeUpBrand'), isEmpty);
    });

    test('findByName exact key hits when manufacturer+model is known', () {
      // Grab a real device to ensure we hit the exact-key index.
      final any = catalog.allDevices.first;
      final hit = catalog.findByName(any.manufacturer, any.model);
      expect(hit, isNotNull);
    });

    test('findByName falls back to fuzzy search on near-miss', () {
      final any = catalog.allDevices
          .firstWhere((d) => d.name.split(' ').length > 1,
              orElse: () => catalog.allDevices.first);
      final firstWord = any.name.split(' ').first;
      // Same manufacturer, partial name → should still find a candidate.
      final hit = catalog.findByName(any.manufacturer, firstWord);
      expect(hit, isNotNull);
    });

    test('findByNameFuzzy returns null on empty text', () {
      expect(catalog.findByNameFuzzy('Phonak', ''), isNull);
    });

    test('findByNameFuzzy returns null when no words pass length filter', () {
      // All words too short (<3 chars) → empty searchWords → null.
      expect(catalog.findByNameFuzzy('Phonak', 'a b'), isNull);
    });
  });

  group('DeviceEntry.fromJson defaults', () {
    test('missing fields fall back to Unknown / empty / false', () {
      final entry =
          DeviceEntry.fromJson('id-x', const <String, dynamic>{});
      expect(entry.id, 'id-x');
      expect(entry.manufacturer, 'Unknown');
      expect(entry.model, 'Unknown');
      expect(entry.features, isEmpty);
      expect(entry.suitability, isEmpty);
      expect(entry.bluetooth, isFalse);
      expect(entry.waterResistant, isFalse);
      expect(entry.hspSubsidised, isFalse);
      expect(entry.recycledSoundBrand, isFalse);
    });

    test('explicit features list is captured', () {
      final entry = DeviceEntry.fromJson('id', {
        'manufacturer': 'Phonak',
        'model': 'Audeo P90',
        'features': ['Auracast', 'AI'],
        'suitability': ['mild', 'moderate'],
        'bluetooth': true,
      });
      expect(entry.features, ['Auracast', 'AI']);
      expect(entry.suitability, ['mild', 'moderate']);
      expect(entry.bluetooth, isTrue);
    });
  });
}
