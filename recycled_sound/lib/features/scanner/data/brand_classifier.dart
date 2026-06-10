// Excluded from coverage: TFLite Interpreter + native GPU/CoreML delegates; needs device
// coverage:ignore-file
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Result of on-device brand classification.
class BrandPrediction {
  const BrandPrediction({
    required this.brand,
    required this.confidence,
    required this.allProbabilities,
  });

  /// Predicted brand name, e.g. "Unitron".
  final String brand;

  /// Confidence 0.0–1.0 for the top prediction.
  final double confidence;

  /// Probabilities for all classes, sorted descending.
  final List<({String brand, double probability})> allProbabilities;

  /// Top-N predictions above a confidence threshold.
  List<({String brand, double probability})> topN(int n,
          {double minConfidence = 0.05}) =>
      allProbabilities
          .where((p) => p.probability >= minConfidence)
          .take(n)
          .toList();
}

/// On-device hearing aid brand classifier using EfficientNet-B0 (TFLite).
///
/// Runs on the Neural Engine (iOS A12+) or GPU (Android) via TFLite delegates.
/// Model is 4.7MB quantized, ~10ms inference on iPhone 14 Pro.
///
/// Usage:
/// ```dart
/// final classifier = BrandClassifier();
/// await classifier.load();
/// final prediction = await classifier.classifyFile(imagePath);
/// print('${prediction.brand} (${prediction.confidence})');
/// ```
class BrandClassifier {
  Interpreter? _interpreter;
  List<String> _classes = [];
  int _inputSize = 224;
  bool _loaded = false;

  /// Whether the model has been loaded successfully.
  bool get isLoaded => _loaded;

  /// Load the TFLite model and labels from assets.
  Future<void> load() async {
    if (_loaded) return;

    // Load labels
    final labelsJson =
        await rootBundle.loadString('assets/brand_classifier_labels.json');
    final labels = jsonDecode(labelsJson) as Map<String, dynamic>;
    _classes = List<String>.from(labels['classes'] as List);
    _inputSize = labels['input_size'] as int? ?? 224;

    // Load TFLite model via rootBundle → file → interpreter.
    // This avoids tflite_flutter's asset resolution quirks.
    final modelData =
        await rootBundle.load('assets/brand_classifier.tflite');

    final options = InterpreterOptions();

    // On iOS, TFLite automatically uses CoreML delegate (Neural Engine)
    // On Android, explicitly request GPU delegate
    if (Platform.isAndroid) {
      options.addDelegate(GpuDelegateV2());
    }

    _interpreter = Interpreter.fromBuffer(modelData.buffer.asUint8List(),
        options: options);
    _loaded = true;
  }

  /// Classify a hearing aid image from a file path.
  ///
  /// Returns brand prediction with confidence and all class probabilities.
  Future<BrandPrediction> classifyFile(String imagePath) async {
    if (!_loaded) await load();

    final bytes = await File(imagePath).readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) {
      throw Exception('Failed to decode image: $imagePath');
    }

    return _classify(image);
  }

  /// Classify from raw image bytes (e.g. from camera capture).
  Future<BrandPrediction> classifyBytes(Uint8List bytes) async {
    if (!_loaded) await load();

    final image = img.decodeImage(bytes);
    if (image == null) {
      throw Exception('Failed to decode image bytes');
    }

    return _classify(image);
  }

  BrandPrediction _classify(img.Image image) {
    // Resize to model input size
    final resized =
        img.copyResize(image, width: _inputSize, height: _inputSize);

    // Build input tensor [1, 224, 224, 3] as Float32
    // EfficientNet expects pixel values in [0, 255] (its own preprocessing
    // handles normalization internally)
    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (y) => List.generate(
          _inputSize,
          (x) {
            final pixel = resized.getPixel(x, y);
            return [pixel.r.toDouble(), pixel.g.toDouble(), pixel.b.toDouble()];
          },
        ),
      ),
    );

    // Output: [1, num_classes] probabilities
    final output = List.generate(1, (_) => List.filled(_classes.length, 0.0));

    _interpreter!.run(input, output);

    final probs = output[0];

    // Build sorted predictions
    final predictions = <({String brand, double probability})>[];
    for (var i = 0; i < _classes.length; i++) {
      predictions.add((brand: _classes[i], probability: probs[i]));
    }
    predictions.sort((a, b) => b.probability.compareTo(a.probability));

    return BrandPrediction(
      brand: predictions.first.brand,
      confidence: predictions.first.probability,
      allProbabilities: predictions,
    );
  }

  /// Release model resources.
  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _loaded = false;
  }
}
