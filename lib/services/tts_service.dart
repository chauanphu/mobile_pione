import 'package:flutter_tts/flutter_tts.dart';

class TtsService {
  final FlutterTts _flutterTts = FlutterTts();

  TtsService() {
    // Ensure that the 'speak' method's Future completes only when speech is done.
    _flutterTts.awaitSpeakCompletion(true);
  }

  /// Speaks the provided text chunk. Completes when speech is finished.
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
