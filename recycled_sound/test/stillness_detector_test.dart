import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/scanner/data/stillness_detector.dart';

/// A frame buffer filled with a single byte value — a uniform "image". Diffing
/// two such frames yields exactly |a - b|, so we can drive the detector with
/// precise, deterministic motion deltas.
Uint8List _frame(int value, {int length = 4096}) =>
    Uint8List(length)..fillRange(0, length, value);

void main() {
  group('StillnessDetector', () {
    test('first frame is never still (nothing to diff against)', () {
      final d = StillnessDetector(stillFrames: 3, stillThreshold: 6);
      expect(d.push(_frame(100)), isFalse);
      expect(d.isStill, isFalse);
      expect(d.lastDelta, double.infinity);
    });

    test('declares still only after stillFrames sub-threshold frames', () {
      final d = StillnessDetector(stillFrames: 3, stillThreshold: 6);
      d.push(_frame(100)); // frame 1: seeds prev, not still
      expect(d.push(_frame(100)), isFalse); // streak 1
      expect(d.push(_frame(100)), isFalse); // streak 2
      expect(d.push(_frame(100)), isTrue); // streak 3 -> still
      expect(d.isStill, isTrue);
      expect(d.lastDelta, 0);
    });

    test('motion above threshold resets the streak and clears stillness', () {
      final d = StillnessDetector(stillFrames: 2, stillThreshold: 6);
      d.push(_frame(100));
      d.push(_frame(100)); // streak 1
      expect(d.push(_frame(100)), isTrue); // streak 2 -> still
      // A big jump (delta 100) is motion: stillness drops immediately.
      expect(d.push(_frame(200)), isFalse);
      expect(d.isStill, isFalse);
      expect(d.lastDelta, 100);
    });

    test('small sub-threshold jitter still counts as stillness', () {
      final d = StillnessDetector(stillFrames: 2, stillThreshold: 6);
      d.push(_frame(100));
      d.push(_frame(103)); // delta 3 <= 6 -> streak 1
      expect(d.push(_frame(101)), isTrue); // delta 2 <= 6 -> streak 2 -> still
    });

    test('reset() forces a fresh trigger on the next rest', () {
      final d = StillnessDetector(stillFrames: 2, stillThreshold: 6);
      d.push(_frame(100));
      d.push(_frame(100));
      expect(d.push(_frame(100)), isTrue); // still
      d.reset();
      expect(d.isStill, isFalse);
      expect(d.lastDelta, double.infinity);
      // After reset the next frame is a "first frame" again: not still until
      // the streak rebuilds.
      expect(d.push(_frame(100)), isFalse);
      expect(d.push(_frame(100)), isFalse); // streak 1
      expect(d.push(_frame(100)), isTrue); // streak 2 -> still again
    });

    test('a buffer-length change (resolution/format switch) is not still', () {
      final d = StillnessDetector(stillFrames: 1, stillThreshold: 6);
      d.push(_frame(100, length: 4096));
      expect(d.push(_frame(100, length: 4096)), isTrue);
      // Resolution changes mid-stream: can't diff, must drop stillness.
      expect(d.push(_frame(100, length: 8192)), isFalse);
      expect(d.lastDelta, double.infinity);
    });

    test('sustained motion never reports still', () {
      final d = StillnessDetector(stillFrames: 3, stillThreshold: 6);
      var value = 0;
      var everStill = false;
      for (var i = 0; i < 20; i++) {
        // Oscillate by 40 each frame -> delta 40, always above threshold.
        value = value == 0 ? 40 : 0;
        if (d.push(_frame(value))) everStill = true;
      }
      expect(everStill, isFalse);
    });

    test('empty plane is not still and never yields a NaN delta', () {
      final d = StillnessDetector(stillFrames: 1, stillThreshold: 6);
      expect(d.push(Uint8List(0)), isFalse);
      expect(d.lastDelta, double.infinity);
      expect(d.lastDelta.isNaN, isFalse);
      // An empty frame between two real frames must not diff across the gap:
      // the frame after it re-primes rather than reporting a bogus stillness.
      d.push(_frame(100));
      expect(d.push(Uint8List(0)), isFalse);
      expect(d.push(_frame(100)), isFalse); // re-primed, no comparable prev
      expect(d.push(_frame(100)), isTrue); // now diffable -> still
    });

    test('downsampling does not break the diff (strided buffers)', () {
      // stride 64 over a 4096-byte buffer samples 64 bytes; uniform frames
      // keep the signal intact end-to-end.
      final d = StillnessDetector(stride: 64, stillFrames: 1, stillThreshold: 0);
      d.push(_frame(50));
      expect(d.push(_frame(50)), isTrue); // identical -> delta 0 -> still
      expect(d.push(_frame(60)), isFalse); // delta 10 > 0 -> moving
    });
  });
}
