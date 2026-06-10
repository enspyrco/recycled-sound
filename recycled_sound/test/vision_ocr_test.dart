import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:recycled_sound/features/scanner/data/vision_ocr.dart';

/// Mocks the iOS Vision OCR MethodChannel so the Dart wrapper can be
/// exercised without a host platform.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('recycled_sound/vision_ocr');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'recognizeText') {
        return [
          {
            'text': 'Oticon',
            'confidence': 0.93,
            'x': 0.1,
            'y': 0.2,
            'width': 0.3,
            'height': 0.05,
          },
          {
            'text': 'Nera2',
            'confidence': 0.81,
            'x': 0.15,
            'y': 0.28,
            'width': 0.25,
            'height': 0.04,
          },
          // Will be filtered out — not a Map.
          'noise',
        ];
      }
      if (call.method == 'setCustomWords') {
        return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('recognizeText parses block list with bbox conversion', () async {
    final blocks = await VisionOcr.recognizeText(
      bytes: Uint8List(0),
      width: 100,
      height: 100,
      bytesPerRow: 400,
      orientation: 90,
    );
    expect(blocks, hasLength(2));
    expect(blocks.first.text, 'Oticon');
    expect(blocks.first.confidence, closeTo(0.93, 1e-6));
    expect(blocks.first.boundingBox, isA<Rect>());
    expect(blocks.first.toString(), contains('Oticon'));
  });

  test('recognizeText returns empty list when plugin returns null', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
    final blocks = await VisionOcr.recognizeText(
      bytes: Uint8List(0),
      width: 1,
      height: 1,
      bytesPerRow: 4,
      orientation: 0,
    );
    expect(blocks, isEmpty);
  });

  test('VisionTextBlock fromMap defaults on missing fields', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return [
        <Object?, Object?>{}, // entirely empty
      ];
    });
    final blocks = await VisionOcr.recognizeText(
      bytes: Uint8List(0),
      width: 1,
      height: 1,
      bytesPerRow: 4,
      orientation: 0,
    );
    expect(blocks, hasLength(1));
    expect(blocks.first.text, '');
    expect(blocks.first.confidence, 0.0);
  });
}
