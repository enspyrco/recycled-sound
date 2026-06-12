import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/scanner/data/ocr_token_accumulator.dart';

void main() {
  group('OcrTokenAccumulator', () {
    test('retains tokens in order seen', () {
      final acc = OcrTokenAccumulator();
      acc.add('Oticon');
      acc.add('Nera2 Pro');
      acc.add('312');

      expect(acc.tokens, ['Oticon', 'Nera2 Pro', '312']);
    });

    test('trims whitespace and ignores tokens shorter than 2 chars', () {
      final acc = OcrTokenAccumulator();
      acc.add('  Phonak  ');
      acc.add('P'); // single char — regulatory mark noise
      acc.add(' '); // whitespace only
      acc.add('');

      expect(acc.tokens, ['Phonak']);
    });

    test('dedupes case-insensitively, keeping the most recent casing', () {
      final acc = OcrTokenAccumulator();
      acc.add('OTICON');
      acc.add('oticon');
      acc.add('Oticon');

      expect(acc.tokens, ['Oticon']);
    });

    test('re-seeing a token refreshes its recency', () {
      final acc = OcrTokenAccumulator(capacity: 2);
      acc.add('Oticon');
      acc.add('312');
      // Re-see the older token, then overflow — '312' is now stalest.
      acc.add('Oticon');
      acc.add('CE');

      expect(acc.tokens, ['Oticon', 'CE']);
    });

    test('evicts the stalest token beyond capacity', () {
      final acc = OcrTokenAccumulator(capacity: 3);
      acc.add('desk');
      acc.add('Oticon');
      acc.add('Nera2');
      acc.add('312');

      expect(acc.tokens, ['Oticon', 'Nera2', '312']);
    });

    test('tokens list is unmodifiable', () {
      final acc = OcrTokenAccumulator();
      acc.add('Oticon');

      expect(() => acc.tokens.add('hack'), throwsUnsupportedError);
    });
  });
}
