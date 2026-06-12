import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/scanner/data/device_catalog.dart';
import 'package:recycled_sound/features/scanner/data/device_index.dart';
import 'package:recycled_sound/features/scanner/data/scan_replay_engine.dart';

/// Deterministic detection-latency regression suite.
///
/// Each fixture is a labelled OCR-token frame sequence modelled on a real
/// device from Seray's register, including the OCR noise the E2E run
/// documented ("oricon" for "oticon", "movi" for "moxi"). The asserted
/// frames-to-lock numbers are the regression baseline: if a matcher change
/// makes a device lock later (or stop locking), this suite fails with the
/// exact frame delta.
///
/// See `scan_replay_engine.dart` for why this is also the instrument that
/// settles the video-vs-stills modality question — both formats reduce to
/// the same `List<List<String>>` frame contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ScanReplayEngine engine;

  setUpAll(() async {
    // Drive the REAL matcher against the REAL catalog — same load path as
    // device_index_test.dart and the live scanner's initState.
    final catalog = DeviceCatalog.instance;
    await catalog.loadFromAsset();
    await DeviceIndex.instance.load(catalog);
    engine = ScanReplayEngine();
  });

  group('ScanReplayEngine — frames-to-lock baseline', () {
    test('A: Oticon Nera2 Pro, clean label in frame 1 → instant lock', () {
      final result = engine.run([
        ['Oticon', 'Nera2 Pro'],
      ]);

      expect(result.finalBrand, 'Oticon');
      expect(result.framesToBrandLock, 1);
      expect(result.modelLocked, isTrue);
      expect(result.framesToModelLock, 1);
      // Human-readable summary for benchmark logs.
      expect(result.toString(), contains('Oticon'));
    });

    test('B: "Phonek" OCR noise → fuzzy brand recovery, model next frame',
        () {
      // 1-char misread of "Phonak" that does NOT collide with any model
      // pattern, so it exercises clean fuzzy brand recovery.
      final result = engine.run([
        ['Phonek'],
        ['Audeo'],
      ]);

      expect(result.finalBrand, 'Phonak',
          reason: 'fuzzy match must recover the brand from a 1-char misread');
      expect(result.framesToBrandLock, 1);
      expect(result.modelLocked, isTrue);
      expect(result.framesToModelLock, 2);
    });

    test('B2: KNOWN PATHOLOGY — "oricon" collides with Signia "Orion", '
        'locks wrong brand and refuses to self-correct', () {
      // "oricon" is the documented ML Kit misread of "Oticon". It fuzzy-
      // matches Signia's model "Orion" (Levenshtein 1, 5+ chars), so the
      // reverse lookup locks brand=Signia FROM MODEL. When the clean
      // Oticon signal "nera" then arrives, the override guard rejects it
      // (equal confidence rank) — the elimination tree cannot back out of
      // its wrong early narrowing.
      //
      // This asserts the CURRENT (wrong) behaviour as the regression
      // baseline. When γ-backtracking lands (feedback_elimination_tree_
      // backtracking), this test SHOULD fail — that failure is the signal
      // to flip the expectation to 'Oticon' and is the proof the fix works.
      final result = engine.run([
        ['oricon'],
        ['nera'],
      ]);

      expect(result.finalBrand, 'Signia',
          reason: 'documents the wrong-brand lock; flip to Oticon when '
              'backtracking lands');
      expect(result.finalModel, 'oricon',
          reason: 'clean "nera" was rejected by the override guard');
    });

    test('C: Unitron Moxi with "movi" noise → model locks only after brand',
        () {
      // "movi" cannot match the model "moxi" via reverse lookup (model
      // fuzzy needs 5+ chars), but DOES match once the brand is known
      // (model-for-known-brand fuzzy allows 4+). So the model lock is
      // gated on the brand lock — a real ordering-induced latency.
      final result = engine.run([
        ['movi'], // nothing locks — brand unknown, reverse fuzzy too short
        ['Unitron'], // brand locks here
        ['movi'], // NOW matches model moxi (brand known)
      ]);

      expect(result.framesToBrandLock, 2);
      expect(result.modelLocked, isTrue);
      expect(result.framesToModelLock, 3,
          reason: 'noisy model token only resolves after the brand is known');
    });

    test('D: label enters frame late → lock latency is measured, not hidden',
        () {
      // The modality crux in miniature: the brand label only becomes
      // readable at frame 5. A stills set whose angles all miss the medial
      // face would never reach this frame; a video sweep would.
      final result = engine.run([
        ['CE'], // junk — regulatory marks, too short to match
        ['01'],
        ['SN'],
        ['R5'],
        ['Phonak Audeo'], // label finally readable
      ]);

      expect(result.finalBrand, 'Phonak');
      expect(result.framesToBrandLock, 5);
      expect(result.framesToModelLock, 5);
    });

    test('E: label never readable → no lock, reported honestly', () {
      final result = engine.run([
        ['CE'],
        ['01'],
        ['blurry'],
      ]);

      expect(result.brandLocked, isFalse);
      expect(result.framesToBrandLock, isNull);
      expect(result.framesToModelLock, isNull);
    });
  });

  group('ScanReplayEngine — modality comparison (one instrument, two '
      'formats)', () {
    // Same device, same total label exposure, two capture shapes. This is
    // the template the real video-vs-stills verdict will use once we have
    // extracted OCR from actual captures (Nick-gated). Here it demonstrates
    // the measurable difference the format makes.
    test('sparse stills can miss the label that a dense sweep catches', () {
      // STILLS: 3 discrete angles; only the 3rd happens to catch the label.
      final stills = engine.run([
        ['side angle, no text'],
        ['battery door'],
        ['Oticon', 'Ino'],
      ]);

      // VIDEO: a sweep that passes the medial face early and dwells on it.
      final video = engine.run([
        ['blur'],
        ['Oticon'],
        ['Oticon', 'Ino'],
        ['Ino'],
        ['Ino'],
      ]);

      // Both lock — but the sweep locks the brand sooner (fewer frames
      // until first readable label).
      expect(stills.brandLocked, isTrue);
      expect(video.brandLocked, isTrue);
      expect(video.framesToBrandLock! <= stills.framesToBrandLock!, isTrue,
          reason: 'the dense sweep should reach a readable label no later '
              'than the sparse stills set');
    });
  });
}
