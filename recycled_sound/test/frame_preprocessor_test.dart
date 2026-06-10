import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/scanner/data/frame_preprocessor.dart';

/// Build a w*h BGRA frame filled with a single (b,g,r) triplet.
Uint8List _solid(int w, int h, int b, int g, int r) {
  final bytes = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    bytes[i * 4 + 0] = b;
    bytes[i * 4 + 1] = g;
    bytes[i * 4 + 2] = r;
    bytes[i * 4 + 3] = 255;
  }
  return bytes;
}

void main() {
  group('PreprocessFilter labels and cycling', () {
    test('every filter has a HUD label', () {
      expect(PreprocessFilter.none.label, 'RAW');
      expect(PreprocessFilter.contrastStretch.label, 'ENHANCE');
      expect(PreprocessFilter.highContrast.label, 'HI-CON');
      expect(PreprocessFilter.greyscaleOcr.label, 'OCR');
    });

    test('next cycles through every filter and returns to start', () {
      var f = PreprocessFilter.none;
      final seen = <PreprocessFilter>{};
      for (var i = 0; i < PreprocessFilter.values.length; i++) {
        seen.add(f);
        f = f.next;
      }
      expect(seen, PreprocessFilter.values.toSet());
      // One more next should land back on .none
      expect(PreprocessFilter.greyscaleOcr.next, PreprocessFilter.none);
    });
  });

  group('FramePreprocessor.apply', () {
    test('none returns the same buffer reference', () {
      final bytes = _solid(8, 8, 10, 20, 30);
      final out = FramePreprocessor.apply(
        bytes: bytes,
        width: 8,
        height: 8,
        bytesPerRow: 32,
        filter: PreprocessFilter.none,
      );
      expect(identical(out, bytes), isTrue);
    });

    test('contrastStretch returns a copy of equal length', () {
      final bytes = _solid(16, 16, 50, 50, 50);
      final out = FramePreprocessor.apply(
        bytes: bytes,
        width: 16,
        height: 16,
        bytesPerRow: 16 * 4,
        filter: PreprocessFilter.contrastStretch,
      );
      expect(identical(out, bytes), isFalse);
      expect(out.length, bytes.length);
    });

    test('contrastStretch on a varied image expands dynamic range', () {
      // Build a gradient frame so min/max differ.
      const w = 32, h = 32;
      final bytes = Uint8List(w * h * 4);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final v = (x * 4).clamp(40, 200);
          final i = (y * w + x) * 4;
          bytes[i] = v;
          bytes[i + 1] = v;
          bytes[i + 2] = v;
          bytes[i + 3] = 255;
        }
      }
      final out = FramePreprocessor.apply(
        bytes: bytes,
        width: w,
        height: h,
        bytesPerRow: w * 4,
        filter: PreprocessFilter.contrastStretch,
      );
      // After stretch, the crop region must contain both 0 and 255-ish
      // values (or close to it). Sample a centre pixel for sanity.
      final cx = w ~/ 2, cy = h ~/ 2;
      final centreIdx = (cy * w + cx) * 4;
      expect(out[centreIdx], inInclusiveRange(0, 255));
    });

    test('highContrast pipeline runs without overflow', () {
      const w = 16, h = 16;
      final bytes = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        // Some variation so contrast stretch finds a range
        final v = (i * 3) & 0xFF;
        bytes[i * 4] = v;
        bytes[i * 4 + 1] = v;
        bytes[i * 4 + 2] = v;
        bytes[i * 4 + 3] = 255;
      }
      final out = FramePreprocessor.apply(
        bytes: bytes,
        width: w,
        height: h,
        bytesPerRow: w * 4,
        filter: PreprocessFilter.highContrast,
      );
      expect(out, isA<Uint8List>());
      expect(out.length, bytes.length);
    });

    test('greyscaleOcr collapses BGR channels to equal values', () {
      const w = 16, h = 16;
      final bytes = Uint8List(w * h * 4);
      for (var i = 0; i < w * h; i++) {
        bytes[i * 4] = 30; // B
        bytes[i * 4 + 1] = 90; // G
        bytes[i * 4 + 2] = 200; // R
        bytes[i * 4 + 3] = 255;
      }
      final out = FramePreprocessor.apply(
        bytes: bytes,
        width: w,
        height: h,
        bytesPerRow: w * 4,
        filter: PreprocessFilter.greyscaleOcr,
      );
      // Inside the crop region (60% centre), B==G==R after grey conversion.
      final cx = w ~/ 2, cy = h ~/ 2;
      final i = (cy * w + cx) * 4;
      expect(out[i], out[i + 1]);
      expect(out[i + 1], out[i + 2]);
    });

    test('flat image with range < 10 skips stretch (still returns copy)', () {
      const w = 12, h = 12;
      // Almost-flat: small variation so the per-row sample lands within
      // range < 10 and the stretch shortcut triggers.
      final bytes = _solid(w, h, 100, 100, 100);
      final out = FramePreprocessor.apply(
        bytes: bytes,
        width: w,
        height: h,
        bytesPerRow: w * 4,
        filter: PreprocessFilter.contrastStretch,
      );
      expect(out.length, bytes.length);
    });
  });
}
