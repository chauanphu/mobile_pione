import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel, rootBundle;

class YoloService {
  static final YoloService instance = YoloService._();
  static const MethodChannel _channel = MethodChannel('com.example.mobile_pione/yolo');

  YoloService._();

  bool _isInitialized = false;
  String? _error;
  Map<String, String> _classNames = {};

  static const int inputWidth = 640;
  static const int inputHeight = 640;
  static const double confidenceThreshold = 0.25;
  static const double iouThreshold = 0.45;

  bool get isInitialized => _isInitialized;
  String? get error => _error;

  Future<void> initializeModel() async {
    if (_isInitialized) return;

    try {
      _error = null;

      await _loadClassNames();

      await _channel.invokeMethod<void>('initialize', {
        'assetPath': 'assets/model/yolo/yoloe-11m-seg-pf.onnx',
        'inputWidth': inputWidth,
        'inputHeight': inputHeight,
      });

      _isInitialized = true;
      debugPrint('YOLO model initialized via native channel');
    } catch (e) {
      _error = 'Failed to initialize YOLO model: $e';
      _isInitialized = false;
      rethrow;
    }
  }

  Future<void> _loadClassNames() async {
    try {
      final metadataJson = await rootBundle.loadString(
        'assets/model/yolo/yoloe-11m-seg-pf.metadata.json',
      );
      final metadata = json.decode(metadataJson) as Map<String, dynamic>;
      final names = metadata['names'] as Map<String, dynamic>;

      _classNames = names.map(
        (key, value) => MapEntry(key, value.toString()),
      );

      debugPrint('Loaded ${_classNames.length} class names');
    } catch (e) {
      debugPrint('Error loading class names: $e');
      _classNames = {};
    }
  }

  Future<List<Map<String, dynamic>>> detectObjects(Uint8List imageBytes) async {
    if (!_isInitialized) {
      throw Exception('YOLO model not initialized. Call initializeModel() first.');
    }

    try {
      final dynamic result = await _channel.invokeMethod(
        'detectObjects',
        {
          'image': imageBytes,
          'confidenceThreshold': confidenceThreshold,
          'iouThreshold': iouThreshold,
        },
      );

      if (result is! List) {
        return const [];
      }

      final List<Map<String, dynamic>> detections = [];
      for (final entry in result) {
        if (entry is! Map) continue;

        final rawMap = Map<String, dynamic>.from(
          entry.map((key, value) => MapEntry(key.toString(), value)),
        );

        final classId = (rawMap['classId'] as num?)?.toInt();
        final bboxRaw = rawMap['bbox'];
        final confidence = (rawMap['confidence'] as num?)?.toDouble() ?? 0.0;

        final Map<String, double> bbox = {};
        if (bboxRaw is Map) {
          for (final bboxEntry in bboxRaw.entries) {
            final value = bboxEntry.value;
            if (value is num) {
              bbox[bboxEntry.key.toString()] = value.toDouble();
            }
          }
        }

        detections.add({
          'classId': classId ?? -1,
          'className': _classNames[classId?.toString() ?? ''] ?? 'unknown',
          'confidence': confidence,
          'bbox': bbox,
        });
      }

      return detections;
    } catch (e) {
      _error = 'Object detection failed: $e';
      rethrow;
    }
  }

  String generateDescription(List<Map<String, dynamic>> detections) {
    if (detections.isEmpty) {
      return 'No objects detected in the scene.';
    }

    final sortedDetections = List<Map<String, dynamic>>.from(detections);
    sortedDetections.sort((a, b) {
      final confA = (a['confidence'] as num?)?.toDouble() ?? 0.0;
      final confB = (b['confidence'] as num?)?.toDouble() ?? 0.0;
      return confB.compareTo(confA);
    });

    final Map<String, int> objectCounts = {};
    for (final detection in sortedDetections) {
      final label = detection['className'] as String? ?? 'unknown';
      objectCounts[label] = (objectCounts[label] ?? 0) + 1;
    }

    final description = StringBuffer('I detected ');
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

    final topDetection = sortedDetections.first;
    final confidence = (topDetection['confidence'] as num?)?.toDouble() ?? 0.0;
    final confidencePercent = (confidence * 100).toInt();
    final className = topDetection['className'] as String? ?? 'unknown';
    description.write(' The most prominent object is $className with $confidencePercent percent confidence.');

    return description.toString();
  }

  Future<void> dispose() async {
    if (!_isInitialized) return;

    try {
      await _channel.invokeMethod<void>('dispose');
    } catch (e) {
      _error = 'Error disposing YOLO model: $e';
    } finally {
      _isInitialized = false;
    }
  }
}
