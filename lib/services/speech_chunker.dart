import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'tts_service.dart';

/// A reusable helper that incrementally chunks streamed text
/// into speakable phrases and feeds them to TtsService.
///
/// Usage:
///   final chunker = SpeechChunker(tts,
///     onChunkQueued: (chunk) { /* optional UI updates */ },
///     onAllDone: () { /* optional */ },
///   );
///   chunker.addPartial(partialText);
///   ...
///   await chunker.finalize();
class SpeechChunker {
  final TtsService _tts;
  final void Function(String chunk)? onChunkQueued;
  final VoidCallback? onAllDone;

  // Internal state
  final List<String> _wordBuffer = [];
  final Queue<String> _speechQueue = Queue<String>();
  bool _isSpeaking = false;

  // Tunables
  static const int minWeakBreakWords = 5;
  static const int failSafeChunkSize = 15;
  static const Set<String> _weakBreakWords = {
    'and', 'but', 'so', 'or', 'because', 'while',
  };

  SpeechChunker(
    this._tts, {
    this.onChunkQueued,
    this.onAllDone,
  });

  void reset() {
    _tts.stop();
    _speechQueue.clear();
    _wordBuffer.clear();
    _isSpeaking = false;
  }

  Future<void> stop() async {
    _tts.stop();
    _speechQueue.clear();
    _isSpeaking = false;
  }

  void addPartial(String partial) {
    final words = partial.trim().split(' ').where((w) => w.isNotEmpty);
    _wordBuffer.addAll(words);
    _maybeChunkAndQueue(forceChunk: false);
  }

  Future<void> finalize() async {
    _maybeChunkAndQueue(forceChunk: true);
    // Wait until queue drains
    while (_isSpeaking || _speechQueue.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  void _maybeChunkAndQueue({required bool forceChunk}) {
    while (true) {
      int? breakIndex;
      for (int i = 0; i < _wordBuffer.length; i++) {
        String word = _wordBuffer[i].toLowerCase().trim();
        String lastChar = word.isNotEmpty ? word.substring(word.length - 1) : '';
        if ('.?!'.contains(lastChar)) {
          breakIndex = i;
          break;
        }
        if (i >= minWeakBreakWords) {
          if (lastChar == ',' || _weakBreakWords.contains(word)) {
            breakIndex = i;
            break;
          }
        }
      }
      if (breakIndex == null && _wordBuffer.length > failSafeChunkSize) {
        breakIndex = failSafeChunkSize - 1;
      }
      if (breakIndex == null && forceChunk && _wordBuffer.isNotEmpty) {
        breakIndex = _wordBuffer.length - 1;
      }
      if (breakIndex != null) {
        final chunk = _wordBuffer.sublist(0, breakIndex + 1).join(' ');
        _speechQueue.add(chunk);
        onChunkQueued?.call(chunk);
        _wordBuffer.removeRange(0, breakIndex + 1);
        _processSpeechQueue();
      } else {
        break;
      }
    }
  }

  Future<void> _processSpeechQueue() async {
    if (_isSpeaking) return;
    if (_speechQueue.isEmpty) {
      onAllDone?.call();
      return;
    }
    _isSpeaking = true;
    final chunkToSpeak = _speechQueue.removeFirst();
    await _tts.speak(chunkToSpeak);
    _isSpeaking = false;
    _processSpeechQueue();
  }
}
