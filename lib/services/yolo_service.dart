import 'dart:typed_data';
import 'package:ultralytics_yolo/ultralytics_yolo.dart';

class YoloService {
  static final YoloService instance = YoloService._();
  YoloService._();

  YOLO? _yolo;
  bool _isInitialized = false;
  String? _error;

  bool get isInitialized => _isInitialized;
  String? get error => _error;

  /// Initialize YOLO model from assets
  Future<void> initializeModel() async {
    if (_isInitialized) return;

    try {
      _error = null;
      
      // Create YOLO instance with segmentation model
      _yolo = YOLO(
        modelPath: 'assets/model/yolo/yoloe-11m-seg.onnx',
        task: YOLOTask.segment,
        useGpu: true,
      );

      // Load the model
      await _yolo!.loadModel();
      
      _isInitialized = true;
    } catch (e) {
      _error = 'Failed to initialize YOLO model: $e';
      _isInitialized = false;
      rethrow;
    }
  }

  /// Detect objects in an image
  Future<List<YOLOResult>> detectObjects(Uint8List imageBytes) async {
    if (!_isInitialized || _yolo == null) {
      throw Exception('YOLO model not initialized. Call initializeModel() first.');
    }

    try {
      // Detect objects in the image
      final resultMap = await _yolo!.predict(imageBytes);
      
      // Parse the results
      final detectionResults = YOLODetectionResults.fromMap(resultMap);
      return detectionResults.detections;
    } catch (e) {
      _error = 'Object detection failed: $e';
      rethrow;
    }
  }

  /// Generate a description of detected objects for TTS
  String generateDescription(List<YOLOResult> detections) {
    if (detections.isEmpty) {
      return 'No objects detected in the scene.';
    }

    // Sort by confidence (highest first)
    final sortedDetections = List<YOLOResult>.from(detections);
    sortedDetections.sort((a, b) => b.confidence.compareTo(a.confidence));

    // Group objects by class name
    final Map<String, int> objectCounts = {};
    for (var detection in sortedDetections) {
      final label = detection.className;
      objectCounts[label] = (objectCounts[label] ?? 0) + 1;
    }

    // Generate description
    final StringBuffer description = StringBuffer();
    description.write('I detected ');

    final entries = objectCounts.entries.toList();
    for (int i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.value > 1) {
        description.write('${entry.value} ${entry.key}s');
      } else {
        description.write('${entry.value} ${entry.key}');
      }

      if (i < entries.length - 2) {
        description.write(', ');
      } else if (i == entries.length - 2) {
        description.write(' and ');
      }
    }

    description.write(' in the scene.');

    // Add confidence info for top detection
    final topDetection = sortedDetections.first;
    final confidencePercent = (topDetection.confidence * 100).toInt();
    description.write(' The most prominent object is ${topDetection.className} with $confidencePercent percent confidence.');

    return description.toString();
  }

  /// Close and release model resources
  Future<void> dispose() async {
    try {
      await _yolo?.dispose();
      _yolo = null;
      _isInitialized = false;
    } catch (e) {
      _error = 'Error disposing YOLO model: $e';
    }
  }
}
