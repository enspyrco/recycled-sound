import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Multi-scale center-crop pyramid for off-hot-path still OCR.
///
/// ## Why a pyramid, not a single crop
///
/// OCR accuracy is **non-monotonic in crop scale** (#57 spike,
/// `technical_ocr_crop_pyramid.md`): a hard low-contrast / embossed brand label
/// that the recognizer misses at one scale frequently reads cleanly at another,
/// and there's a "dead band" where nothing reads. The fix that beat both a
/// single crop and a fine-grained sweep was a small pyramid of **well-separated**
/// native center-crops. We union the tokens across scales, so a label only has
/// to read at *one* scale to be found.
///
/// On the 8-device certification set (Apple Vision `.accurate`), full-frame OCR
/// read 6-7/8 brands; adding this crop pyramid recovered the genuinely-hard
/// Signia and ReSound labels → 8/8 device-level (#58).
///
/// ## Two load-bearing constraints from the spike
///
/// 1. **Native crops only — never upscale.** Upscaling a crop *hurts* OCR; we
///    crop pixels out of the source at native resolution and stop there.
/// 2. **Well-separated fractions** ({40,60,80}%) to straddle the dead band.
///    A fine sweep ({35,45,55,...}) wastes passes inside it without gain.
///
/// Center-crop assumes the device is roughly centered in frame — true under the
/// guided capture protocol ("center the label face"), which is the only path
/// that feeds this. For uncontrolled photos a learned segmenter would be needed,
/// but that path was dissolved (#57) in favour of controlled capture.

/// The crop fractions of the OCR pyramid: fraction of each dimension kept,
/// centered. {40,60,80}% — well-separated to straddle the non-monotonic OCR
/// dead band (#57). Excludes 1.0 (the full frame) because the caller OCRs the
/// original still in addition to these crops.
const List<double> kOcrCropFractions = [0.40, 0.60, 0.80];

/// Center-crop [src] to [frac] (0..1) of each dimension, keeping the middle.
///
/// Reproduces the certification harness's center-crop *scale*
/// (`data/certify_ocr_first.py:100`, `arr[int(h*m):int(h*(1-m))]` with
/// `m = (1-frac)/2`) to within ≤1px — close enough that the app path crops the
/// same content we certified 8/8 (`feedback_harness_matches_production_path`),
/// while staying robust to floating-point drift. (The harness floor-slices each
/// margin; `int(1000*(1-0.2))` lands at `799` because `0.8` isn't exact in IEEE.
/// We instead size by `round(dim*frac)` and center symmetrically, so the crop is
/// always exactly `frac` of the dimension and never off by a float-rounding
/// fluke.) No scaling — `frac` of the source's pixels at native resolution.
img.Image centerCrop(img.Image src, double frac) {
  // Guard against a zero-size crop on a tiny image; copyCrop would throw on a
  // width/height of 0.
  final w = (src.width * frac).round().clamp(1, src.width);
  final h = (src.height * frac).round().clamp(1, src.height);
  final x0 = ((src.width - w) / 2).round();
  final y0 = ((src.height - h) / 2).round();
  return img.copyCrop(src, x: x0, y: y0, width: w, height: h);
}

/// Decode the still at [path], write its center-crop pyramid as temp JPEGs into
/// [tempDir], and return the temp file paths (the caller is responsible for
/// deleting them — typically by removing [tempDir] recursively).
///
/// Best-effort and never throws: if the image can't be decoded the result is an
/// empty list, so the caller still has its full-frame OCR read and degrades
/// gracefully rather than breaking. A single crop that fails to encode is
/// skipped, not fatal.
Future<List<String>> writeOcrCropPyramid(
  String path,
  Directory tempDir, {
  List<double> fractions = kOcrCropFractions,
}) async {
  final Uint8List bytes;
  try {
    bytes = await File(path).readAsBytes();
  } catch (_) {
    return const [];
  }

  // Decode ONCE; cropping N times off the same decoded image avoids paying the
  // (expensive) JPEG decode per fraction.
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return const [];

  final base = path.split(Platform.pathSeparator).last;
  final out = <String>[];
  for (final frac in fractions) {
    try {
      final crop = centerCrop(decoded, frac);
      final pct = (frac * 100).round();
      final cropPath =
          '${tempDir.path}${Platform.pathSeparator}${base}_f$pct.jpg';
      await File(cropPath).writeAsBytes(img.encodeJpg(crop, quality: 92));
      out.add(cropPath);
    } catch (_) {
      // Skip this scale; the other crops + full frame still contribute.
    }
  }
  return out;
}
