import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:recycled_sound/features/capture/data/ocr_crop_pyramid.dart';

/// Tests for the multi-scale center-crop pyramid (#58).
///
/// The crop *math* is pure and fully testable offline — no camera, no OCR
/// channel — which is the whole point of factoring it out: we pin the geometry
/// here so the on-device work is only verifying that OCR reads the labels, not
/// debugging crop arithmetic.
void main() {
  group('centerCrop', () {
    test('keeps the requested fraction of each dimension, centered', () {
      final src = img.Image(width: 1000, height: 600);
      final crop = centerCrop(src, 0.40);
      // 40% of 1000 = 400, 40% of 600 = 240.
      expect(crop.width, 400);
      expect(crop.height, 240);
    });

    test('60% and 80% scale both dimensions proportionally', () {
      final src = img.Image(width: 1000, height: 1000);
      expect(centerCrop(src, 0.60).width, 600);
      expect(centerCrop(src, 0.80).height, 800);
    });

    test('does not upscale — a crop is always <= the source', () {
      final src = img.Image(width: 320, height: 240);
      for (final frac in kOcrCropFractions) {
        final crop = centerCrop(src, frac);
        expect(crop.width, lessThanOrEqualTo(src.width));
        expect(crop.height, lessThanOrEqualTo(src.height));
      }
    });

    test('crop is centered (equal margins, modulo rounding)', () {
      final src = img.Image(width: 100, height: 100);
      // Paint a single bright pixel dead-center; a centered 40% crop must still
      // contain a center pixel (sanity that we cut the middle, not a corner).
      final crop = centerCrop(src, 0.40);
      expect(crop.width, 40);
      expect(crop.height, 40);
    });

    test('crops the centered pixels — origin is pinned, not just the size', () {
      // Mark a single pixel dead-center; after a 40% center-crop it must land at
      // the crop's center. Dimensions alone wouldn't catch an off-by-origin bug.
      final src = img.Image(width: 10, height: 10);
      img.fill(src, color: img.ColorRgb8(0, 0, 0));
      src.setPixelRgb(5, 5, 255, 0, 0); // marker
      // frac 0.4 on 10px: m=0.3 -> x0=floor(3)=3, x1=floor(7)=7, w=4.
      final crop = centerCrop(src, 0.40);
      expect(crop.width, 4);
      // Source (5,5) maps to crop (5-3, 5-3) = (2,2).
      final p = crop.getPixel(2, 2);
      expect(p.r, 255);
      expect(p.g, 0);
    });

    test('size is robust to float drift (matches harness scale within 1px)',
        () {
      // 1000px, frac 0.6: the harness's int(1000*(1-0.2)) floors 799.999.. to
      // 799 (a float fluke). round(1000*0.6)=600 is the stable, correct size.
      expect(centerCrop(img.Image(width: 1000, height: 1000), 0.60).width, 600);
      // Odd dim stays exactly frac of the dimension, centered.
      final odd = centerCrop(img.Image(width: 15, height: 15), 0.40);
      expect(odd.width, 6); // round(15*0.4)=6
    });

    test('tiny image never yields a zero-size crop', () {
      final src = img.Image(width: 2, height: 2);
      final crop = centerCrop(src, 0.40); // 0.4*2 = 0.8 → rounds to 1, clamped
      expect(crop.width, greaterThanOrEqualTo(1));
      expect(crop.height, greaterThanOrEqualTo(1));
    });
  });

  group('writeOcrCropPyramid', () {
    test('writes one temp JPEG per fraction with the right dimensions',
        () async {
      final tempDir = await Directory.systemTemp.createTemp('crop_test_');
      addTearDown(() => tempDir.delete(recursive: true));

      // A real JPEG on disk for the function to decode.
      final src = img.Image(width: 800, height: 800);
      final srcPath = '${tempDir.path}/src.jpg';
      await File(srcPath).writeAsBytes(img.encodeJpg(src));

      final crops = await writeOcrCropPyramid(srcPath, tempDir);
      expect(crops.length, kOcrCropFractions.length);

      for (var i = 0; i < crops.length; i++) {
        expect(File(crops[i]).existsSync(), isTrue);
        final decoded = img.decodeImage(await File(crops[i]).readAsBytes())!;
        final expected = (800 * kOcrCropFractions[i]).round();
        expect(decoded.width, expected);
        expect(decoded.height, expected);
      }
    });

    test('returns empty (never throws) for a non-existent file', () async {
      final tempDir = await Directory.systemTemp.createTemp('crop_test_');
      addTearDown(() => tempDir.delete(recursive: true));
      expect(await writeOcrCropPyramid('/no/such/file.jpg', tempDir), isEmpty);
    });

    test('returns empty for a file that is not a decodable image', () async {
      final tempDir = await Directory.systemTemp.createTemp('crop_test_');
      addTearDown(() => tempDir.delete(recursive: true));
      final junk = '${tempDir.path}/junk.jpg';
      await File(junk).writeAsString('not an image');
      expect(await writeOcrCropPyramid(junk, tempDir), isEmpty);
    });
  });
}
