import 'dart:async';
import 'package:flutter/services.dart';

class LlmInference {
  // Use the same channel names as defined in MainActivity.kt
  static const MethodChannel _methodChannel =
      MethodChannel('com.example.mobile_pione/llm');
  static const EventChannel _eventChannel =
      EventChannel('com.example.mobile_pione/llm_progress');
  static const EventChannel _statusChannel =
      EventChannel('com.example.mobile_pione/llm_status');

  // A private constructor to prevent direct instantiation
  LlmInference._();

  // The single instance of the class
  static final LlmInference instance = LlmInference._();

  // Cached readiness flag to avoid repeated platform calls
  bool _isReady = false;
  Stream<Map<String, dynamic>>? _statusBroadcast;

  /// Begin background model initialization (idempotent, returns immediately)
  Future<void> initializeModel() async {
    try {
      await _methodChannel.invokeMethod('initializeModel');
    } on PlatformException catch (e) {
      // Swallow here; status stream will carry errors
      // but expose as a debug exception if needed
      // ignore: avoid_print
      print('initializeModel error: ${e.message}');
    }
  }

  /// Close native model resources. After this, model will need re-initialization.
  Future<void> closeModel() async {
    try {
      await _methodChannel.invokeMethod('closeModel');
      _isReady = false;
    } on PlatformException catch (e) {
      // ignore: avoid_print
      print('closeModel error: ${e.message}');
    }
  }

  /// Returns true when the native model is loaded and ready.
  Future<bool> isModelReady() async {
    if (_isReady) return true;
    try {
      final bool ready = await _methodChannel.invokeMethod('isModelReady');
      _isReady = ready;
      return ready;
    } on PlatformException {
      return false;
    }
  }

  /// Returns the current model status string (UNINITIALIZED, INITIALIZING, READY, ERROR)
  Future<String> getModelStatus() async {
    try {
      final String status = await _methodChannel.invokeMethod('getModelStatus');
      return status;
    } on PlatformException catch (e) {
      return 'ERROR:${e.code}';
    }
  }

  /// Stream of status updates from native side as a Map {status, message}
  Stream<Map<String, dynamic>> modelStatusStream() {
    _statusBroadcast ??= _statusChannel
        .receiveBroadcastStream()
        .map((dynamic event) => Map<String, dynamic>.from(event as Map));
    return _statusBroadcast!;
  }

  /// Waits until the model reports READY or throws on timeout.
  Future<void> waitUntilReady({Duration timeout = const Duration(seconds: 45)}) async {
    if (await isModelReady()) return;
    final completer = Completer<void>();
    late StreamSubscription sub;
    sub = modelStatusStream().listen((event) {
      final status = (event['status'] as String?) ?? 'UNKNOWN';
      if (status == 'READY') {
        _isReady = true;
        if (!completer.isCompleted) completer.complete();
        sub.cancel();
      }
      if (status == 'ERROR') {
        if (!completer.isCompleted) {
          completer.completeError(Exception('Model init error: ${event['message'] ?? ''}'));
        }
        sub.cancel();
      }
    });
    // Also ensure initialization is ongoing
    await initializeModel();
    await completer.future.timeout(timeout, onTimeout: () {
      sub.cancel();
      throw TimeoutException('Timed out waiting for model to be ready');
    });
  }

  /// Resets the session and generates a response from a prompt and image.
  /// Returns a Future that completes with the response Stream.
  Future<Stream<String>> generateCaptionStream({
    required String prompt,
    required Uint8List image,
  }) async {
    try {
      // Ensure model is ready first to avoid UI jank and errors
      await waitUntilReady();
      await _methodChannel.invokeMethod('resetSession');
      return _generateResponseStream(prompt: prompt, image: image);
    } on PlatformException catch (e) {
      throw Exception('Failed to reset session and generate caption: ${e.message}');
    }
  }

  Stream<String> _generateResponseStream({
    required String prompt,
    Uint8List? image,
  }) {
    try {
      final arguments = <String, dynamic>{
        'prompt': prompt,
        if (image != null) 'image': image,
      };

      return _eventChannel
          .receiveBroadcastStream(arguments)
          .map((dynamic event) => event.toString());
    } on PlatformException catch (e) {
      return Stream.error('Failed to start response stream: ${e.message}');
    }
  }

  Future<void> resetSession() async {
    try {
      await _methodChannel.invokeMethod('resetSession');
    } on PlatformException catch (e) {
      throw Exception('Failed to reset session: ${e.message}');
    }
  }

  Future<int> sizeInTokens(String text) async {
    try {
      final int tokens = await _methodChannel.invokeMethod(
        'sizeInTokens',
        {'text': text},
      );
      return tokens;
    } on PlatformException {
      return 0;
    }
  }
}
