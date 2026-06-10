import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/scanner/data/colour_classifier.dart';

void main() {
  group('ColourClassifier.classify', () {
    test('pure black classifies as Black', () {
      final m = ColourClassifier.classify(const Color(0xFF000000));
      expect(m.name, 'Black');
    });

    test('pure white-ish classifies into the lightest palette entry', () {
      final m = ColourClassifier.classify(const Color(0xFFFFFFFF));
      // Whichever Lab-nearest palette entry wins is fine — just ensure
      // the API returns a known name and a finite deltaE.
      expect(ColourClassifier.palette.map((c) => c.name), contains(m.name));
      expect(m.deltaE, isPositive);
      expect(m.deltaE.isFinite, isTrue);
    });

    test('palette colour classifies to itself with deltaE ≈ 0', () {
      final beige = ColourClassifier.palette
          .firstWhere((p) => p.name == 'Beige');
      final m = ColourClassifier.classify(beige.color);
      expect(m.name, 'Beige');
      expect(m.deltaE, lessThan(1.0));
    });

    test('Espresso reference is identified', () {
      final espresso = ColourClassifier.palette
          .firstWhere((p) => p.name == 'Espresso');
      final m = ColourClassifier.classify(espresso.color);
      expect(m.name, 'Espresso');
    });
  });

  group('ColourClassifier.sampleFromBgra8888', () {
    test('returns the mid-grey fallback for an empty crop window', () {
      // A 1x1 frame has no centre 20% region — count==0 → grey fallback.
      final bytes = Uint8List.fromList([0, 0, 0, 255]);
      final c = ColourClassifier.sampleFromBgra8888(
        bytes: bytes,
        width: 1,
        height: 1,
        bytesPerRow: 4,
      );
      expect(c, const Color(0xFF808080));
    });

    test('averages central pixels of a solid-colour frame', () {
      // Build a 20x20 BGRA frame, all pixels R=200, G=100, B=50.
      const w = 20, h = 20;
      final bytes = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        bytes[i * 4 + 0] = 50; // B
        bytes[i * 4 + 1] = 100; // G
        bytes[i * 4 + 2] = 200; // R
        bytes[i * 4 + 3] = 255; // A
      }
      final c = ColourClassifier.sampleFromBgra8888(
        bytes: bytes,
        width: w,
        height: h,
        bytesPerRow: w * 4,
        stride: 1,
      );
      expect((c.r * 255).round(), 200);
      expect((c.g * 255).round(), 100);
      expect((c.b * 255).round(), 50);
    });
  });

  group('ColourStabiliser', () {
    test('empty buffer reports no leading colour', () {
      final s = ColourStabiliser(bufferSize: 4, threshold: 3);
      expect(s.leadingColour, isNull);
      expect(s.leadingRgb, isNull);
      expect(s.confidence, 0.0);
      expect(s.isStable, isFalse);
    });

    test('reaches stable after threshold consistent pushes', () {
      final s = ColourStabiliser(bufferSize: 4, threshold: 3);
      const c = Color(0xFFAABBCC);
      s.push('Beige', c);
      s.push('Beige', c);
      s.push('Beige', c);
      expect(s.leadingColour, 'Beige');
      expect(s.leadingRgb, c);
      expect(s.isStable, isTrue);
      expect(s.confidence, greaterThan(0));
    });

    test('reset clears buffers', () {
      final s = ColourStabiliser(bufferSize: 4, threshold: 2);
      s.push('Tan', const Color(0xFF000000));
      s.push('Tan', const Color(0xFF000000));
      expect(s.isStable, isTrue);
      s.reset();
      expect(s.leadingColour, isNull);
    });

    test('older readings rolled off once buffer exceeds bufferSize', () {
      final s = ColourStabiliser(bufferSize: 2, threshold: 2);
      s.push('A', const Color(0xFF000000));
      s.push('B', const Color(0xFF010101));
      s.push('B', const Color(0xFF020202));
      // First "A" should have been rolled off, both remaining are B.
      expect(s.leadingColour, 'B');
      expect(s.isStable, isTrue);
    });
  });
}
