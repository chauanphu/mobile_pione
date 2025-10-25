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

  /// Generates a response from the model as a stream of partial results.
  ///
  /// The [prompt] is the text input to the model.
  /// Returns a [Stream] of [String]s, where each string is a partial
  /// response from the model.
  Stream<String> generateResponseStream(String prompt) {
    try {
      // The EventChannel's receiveBroadcastStream method takes arguments
      // that are passed to the onListen callback on the native side.
      return _eventChannel
          .receiveBroadcastStream(prompt)
          .map((dynamic event) => event.toString());
    } on PlatformException catch (e) {
      // Handle potential errors when setting up the stream
      print("Error starting stream: ${e.message}");
      // Return an empty stream or a stream with an error
      return Stream.error('Failed to start response stream: ${e.message}');
    }
  }

  /// Resets the model's conversation history.
  Future<void> resetSession() async {
    try {
      await _methodChannel.invokeMethod('resetSession');
    } on PlatformException catch (e) {
      // Handle potential errors
      print("Failed to reset session: '${e.message}'.");
    }
  }

  /// Estimates the number of remaining tokens the model can process.
  ///
  /// The [prompt] is the current text you plan to send.
  /// Returns an integer with the approximate number of tokens left.
  Future<int> estimateTokens(String prompt) async {
    try {
      final int tokens = await _methodChannel.invokeMethod(
        'estimateTokens',
        {'prompt': prompt},
      );
      return tokens;
    } on PlatformException catch (e) {
      print("Failed to estimate tokens: '${e.message}'.");
      return 0; // Return a default value on error
    }
  }
}