import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

class LlmInference {
  // Use the same channel names as defined in MainActivity.kt
  static const MethodChannel _methodChannel =
      MethodChannel('com.example.mobile_pione/llm');
  static const EventChannel _eventChannel =
      EventChannel('com.example.mobile_pione/llm_progress');

  // A private constructor to prevent direct instantiation
  LlmInference._();

  // The single instance of the class
  static final LlmInference instance = LlmInference._();

  /// Resets the session and generates a response from a prompt and image.
  /// Returns a Future that completes with the response Stream.
  Future<Stream<String>> generateCaptionStream({
    required String prompt,
    required Uint8List image,
  }) async {
    try {
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
