import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/capture/data/capture_ocr.dart';

/// Tests for [CaptureOcr] that don't depend on a live ML Kit platform channel.
///
/// The ML Kit text recognizer isn't registered in the unit-test harness, so
/// `processImage` throws — which is exactly the best-effort path the class
/// promises to swallow. We assert the contract that survives without the
/// channel: an empty input reads nothing, an unreadable input yields no match
/// (never throws), and the [CaptureId] value type behaves.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CaptureId', () {
    test('isEmpty only when both brand and model are blank', () {
      expect(const CaptureId(brand: '', model: '').isEmpty, isTrue);
      expect(const CaptureId(brand: 'Oticon', model: '').isEmpty, isFalse);
      expect(const CaptureId(brand: '', model: 'More 1').isEmpty, isFalse);
    });
  });

  group('CaptureOcr.identify', () {
    test('returns null for an empty path list (no recognizer opened)', () async {
      final ocr = CaptureOcr();
      addTearDown(ocr.dispose);
      expect(await ocr.identify(const []), isNull);
    });

    test('swallows an unreadable/decode-failing frame and returns null',
        () async {
      // No ML Kit channel in tests → processImage throws → best-effort skip →
      // no tokens → no match. The point is it must NOT propagate the throw.
      // (No dispose here: identify lazily opens the recognizer, and closing it
      // hits the same absent channel — harmless in production where the channel
      // exists, but it would throw in this harness.)
      final ocr = CaptureOcr();
      expect(await ocr.identify(const ['/no/such/file.jpg']), isNull);
    });

    test('dispose is safe to call (idempotent best-effort cleanup)', () {
      final ocr = CaptureOcr();
      // Never ran identify → recognizer was never created → dispose no-ops.
      expect(ocr.dispose, returnsNormally);
    });
  });
}
