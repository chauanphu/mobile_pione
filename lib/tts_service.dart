import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _flutterTts = FlutterTts();
  // We'll manage the speaking state in the UI now
  // so we know when a specific chunk is done.

  TtsService() {
    // Ensure that the 'speak' method's Future completes only when speech is done.
    _flutterTts.awaitSpeakCompletion(true);
  }

  /// Speaks the provided text chunk.
  /// The Future completes when the speech is finished.
  Future<void> speak(String text) async {
    if (text.isNotEmpty) {
      await _flutterTts.speak(text);
    }
  }

  /// Stops the current speech immediately.
  Future<void> stop() async {
    await _flutterTts.stop();
  }

  /// Disposes of the TTS engine resources.
  void dispose() {
    _flutterTts.stop();
  }
}