import 'dart:typed_data';

/// Detects when the camera view has come to rest.
///
/// This is the cheap, always-on TRIGGER for the "motion-stop → segment →
/// identify" capture pipeline (Option D). The heavy work — segmentation, OCR,
/// visual match, colour — fires exactly once, when the hearing aid stops
/// moving, so it never competes with the live frame loop for budget. A
/// stationary frame is also sharp by construction, which sidesteps the
/// motion-blur risk that haunted the sweep-video approach.
///
/// Pure Dart, no camera/platform dependency: feed it the primary image plane of
/// each frame ([CameraImage.planes[0].bytes] — the luma plane on Android NV21,
/// the interleaved BGRA buffer on iOS) and it reports [isStill] once the
/// inter-frame change stays at/below [stillThreshold] for [stillFrames]
/// consecutive frames. Because it only diffs a strided down-sample, the cost is
/// a few thousand byte subtractions per frame regardless of resolution.
///
/// **Zero per-frame allocation.** This runs on the throughput-sacred camera hot
/// path, so it never allocates while streaming: two fixed sample buffers are
/// ping-ponged (this frame downsamples into one, diffs against the other), and
/// they're (re)allocated only on the first frame or a buffer-length change
/// (resolution/format switch). An earlier version allocated a fresh down-sample
/// every frame — ~32KB (1080p luma) to ~129KB (BGRA) of young-gen garbage per
/// frame competing with OCR — which the #108 cage match correctly rejected.
///
/// Format-agnostic by design: it never interprets the bytes as pixels, only as
/// a change signal. Motion perturbs the buffer whatever the channel layout, so
/// the same code works for NV21 luma and BGRA alike. If a sharper signal is
/// wanted later (e.g. gyro/IMU fusion), swap the source feeding [push] — the
/// trigger semantics ([isStill]/[reset]) stay put.
class StillnessDetector {
  StillnessDetector({
    this.stride = 64,
    this.stillThreshold = 6.0,
    this.stillFrames = 5,
  })  : assert(stride > 0),
        assert(stillThreshold >= 0),
        assert(stillFrames > 0);

  /// Sample every [stride]th byte of the plane. Larger = cheaper, coarser.
  final int stride;

  /// Mean absolute inter-frame difference at/below which a frame counts as
  /// "not moving" (0–255 byte scale).
  final double stillThreshold;

  /// Consecutive sub-threshold frames required before declaring stillness.
  final int stillFrames;

  // Two fixed sample buffers, ping-ponged frame to frame. [_writeToA] picks the
  // one the NEXT frame downsamples into; the other holds the previous frame's
  // samples to diff against. We snapshot into our own buffer (rather than alias
  // [bytes]) because camera plugins may recycle the frame buffer between
  // callbacks — aliasing would make every diff read as zero and falsely report
  // stillness.
  Uint8List? _bufA;
  Uint8List? _bufB;
  bool _writeToA = true;
  bool _hasPrev = false;
  int _stillStreak = 0;
  bool _isStill = false;

  /// Whether the view is currently judged to be at rest.
  bool get isStill => _isStill;

  /// The most recent mean-absolute-difference reading. [double.infinity] before
  /// the first comparable frame. Useful for tuning [stillThreshold] from logs.
  double get lastDelta => _lastDelta;
  double _lastDelta = double.infinity;

  /// Feed one frame's primary-plane bytes. Returns the current [isStill] state.
  ///
  /// The first call (and any call where the buffer length changes — a
  /// resolution or format switch) can't be diffed, so it resets the streak and
  /// returns false. An empty plane is treated the same way (and re-primes), so
  /// the mean-difference is never computed over zero samples.
  bool push(Uint8List bytes) {
    if (bytes.isEmpty) {
      // Not comparable; don't claim stillness, and force the next real frame to
      // re-prime rather than diff across the gap. (Guards the 0/0 = NaN hole.)
      _hasPrev = false;
      _stillStreak = 0;
      _isStill = false;
      _lastDelta = double.infinity;
      return false;
    }

    final count = ((bytes.length - 1) ~/ stride) + 1;
    if (_bufA == null || _bufA!.length != count) {
      // First frame, or a resolution/format switch: (re)allocate both buffers
      // once and start a fresh prime — no comparable previous frame yet.
      _bufA = Uint8List(count);
      _bufB = Uint8List(count);
      _writeToA = true;
      _hasPrev = false;
      _stillStreak = 0;
      _isStill = false;
      _lastDelta = double.infinity;
    }

    // Downsample into the current buffer (no allocation), diff against the prev.
    final cur = _writeToA ? _bufA! : _bufB!;
    final prev = _writeToA ? _bufB! : _bufA!;
    var j = 0;
    for (var i = 0; i < bytes.length; i += stride) {
      cur[j++] = bytes[i];
    }
    _writeToA = !_writeToA; // next frame writes into the other buffer

    if (!_hasPrev) {
      _hasPrev = true;
      _stillStreak = 0;
      _isStill = false;
      _lastDelta = double.infinity;
      return false;
    }

    var sum = 0;
    for (var i = 0; i < cur.length; i++) {
      final d = cur[i] - prev[i];
      sum += d < 0 ? -d : d;
    }
    final delta = sum / cur.length;
    _lastDelta = delta;

    if (delta <= stillThreshold) {
      _stillStreak++;
      if (_stillStreak >= stillFrames) _isStill = true;
    } else {
      _stillStreak = 0;
      _isStill = false;
    }
    return _isStill;
  }

  /// Clear all state. Call after a capture fires so the *next* time the object
  /// comes to rest is treated as a fresh trigger rather than re-firing on the
  /// same stationary device. Keeps the allocated buffers for reuse — only the
  /// "have a comparable previous frame" flag is dropped.
  void reset() {
    _hasPrev = false;
    _writeToA = true;
    _stillStreak = 0;
    _isStill = false;
    _lastDelta = double.infinity;
  }
}
