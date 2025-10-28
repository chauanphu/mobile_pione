// FILE: lib/services/llm_inference.dart
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

  /// **[NEW]** Resets the session and generates a response from a prompt and image.
  ///
  /// This is the recommended method for image captioning, as it ensures
  /// each image is processed in a fresh, clean session.
  /// Returns a Future that completes with the response Stream.
  Future<Stream<String>> generateCaptionStream({
    required String prompt,
    required Uint8List image,
  }) async {
    try {
      // 1. Reset the session to clear any previous context.
      await resetSession();

      // 2. Start the response stream with the new prompt and image.
      return _generateResponseStream(prompt: prompt, image: image);
    } on PlatformException catch (e) {
      // If resetting fails, we throw an exception to be handled by the UI.
      throw Exception('Failed to reset session and generate caption: ${e.message}');
    }
  }

  /// **[MODIFIED]** Generates a response from the model as a stream of partial results.
  ///
  /// This private method now accepts an optional [image] as a Uint8List.
  /// The arguments map is constructed to match what the native Kotlin code expects.
  Stream<String> _generateResponseStream({
    required String prompt,
    Uint8List? image,
  }) {
    try {
      // Prepare the arguments map to send to the native side.
      final arguments = <String, dynamic>{
        'prompt': prompt,
        // The `if` condition adds the image only if it's not null.
        if (image != null) 'image': image,
      };

      // Start listening to the stream.
      return _eventChannel
          .receiveBroadcastStream(arguments)
          .map((dynamic event) => event.toString());
    } on PlatformException catch (e) {
      // Return a stream that immediately emits an error.
      return Stream.error('Failed to start response stream: ${e.message}');
    }
  }

  /// Resets the model's conversation history.
  Future<void> resetSession() async {
    try {
      await _methodChannel.invokeMethod('resetSession');
    } on PlatformException catch (e) {
      // Forwards the error to the caller.
      throw Exception('Failed to reset session: ${e.message}');
    }
  }

  /// Calculates the number of tokens in a given string.
  ///
  /// The [text] is the string to be measured.
  Future<int> sizeInTokens(String text) async {
    try {
      // **[FIXED]** Corrected method name and argument key to match native code.
      final int tokens = await _methodChannel.invokeMethod(
        'sizeInTokens',
        {'text': text},
      );
      return tokens;
    } on PlatformException catch (e) {
      print('Failed to get token size: ${e.message}');
      return 0; // Return a default value on error
    }
  }
}