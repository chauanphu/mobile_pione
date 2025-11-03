import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Service to handle continuous voice command recognition
/// Listens for trigger phrases like "Hey Vision, describe in front of me"
class VoiceCommandService {
  final SpeechToText _speechToText = SpeechToText();
  bool _isListening = false;
  bool _isInitialized = false;
  
  // Callback when a command is recognized
  final void Function(String command)? onCommandRecognized;
  final VoidCallback? onListeningStarted;
  final VoidCallback? onListeningStopped;
  final void Function(String error)? onError;
  
  // Trigger phrases configuration
  final List<String> triggerPhrases = [
    'hey vision describe in front of me',
    'hey vision describe',
    'hey vision what do you see',
    'hey vision tell me what you see',
    'describe in front of me',
  ];
  
  // Debouncing to prevent multiple triggers
  Timer? _commandDebounceTimer;
  String _lastRecognizedCommand = '';
  static const Duration _debounceDuration = Duration(seconds: 3);

  VoiceCommandService({
    this.onCommandRecognized,
    this.onListeningStarted,
    this.onListeningStopped,
    this.onError,
  });

  /// Initialize the speech recognition service
  Future<bool> initialize() async {
    if (_isInitialized) return true;
    
    try {
      _isInitialized = await _speechToText.initialize(
        onError: (error) {
          debugPrint('Speech recognition error: ${error.errorMsg}');
          onError?.call(error.errorMsg);
        },
        onStatus: (status) {
          debugPrint('Speech recognition status: $status');
          if (status == 'notListening' && _isListening) {
            // Restart listening if it stopped unexpectedly
            _restartListening();
          }
        },
      );
      
      if (!_isInitialized) {
        onError?.call('Failed to initialize speech recognition');
      }
      
      return _isInitialized;
    } catch (e) {
      debugPrint('Error initializing speech recognition: $e');
      onError?.call('Speech recognition not available: $e');
      return false;
    }
  }

  /// Start continuous listening for voice commands
  Future<void> startListening() async {
    if (!_isInitialized) {
      final initialized = await initialize();
      if (!initialized) return;
    }

    if (_isListening) return;

    try {
      _isListening = true;
      onListeningStarted?.call();
      
      await _speechToText.listen(
        onResult: _onSpeechResult,
        listenMode: ListenMode.confirmation,
        pauseFor: const Duration(seconds: 15),
        partialResults: true,
        listenFor: const Duration(seconds: 30),
        cancelOnError: false,
      );
      
      debugPrint('Started listening for voice commands');
    } catch (e) {
      debugPrint('Error starting speech recognition: $e');
      _isListening = false;
      onError?.call('Failed to start listening: $e');
    }
  }

  /// Stop listening for voice commands
  Future<void> stopListening() async {
    if (!_isListening) return;
    
    try {
      await _speechToText.stop();
      _isListening = false;
      onListeningStopped?.call();
      debugPrint('Stopped listening for voice commands');
    } catch (e) {
      debugPrint('Error stopping speech recognition: $e');
    }
  }

  /// Toggle listening state
  Future<void> toggleListening() async {
    if (_isListening) {
      await stopListening();
    } else {
      await startListening();
    }
  }

  /// Restart listening after a pause
  Future<void> _restartListening() async {
    if (!_isListening) return;
    
    await Future.delayed(const Duration(milliseconds: 500));
    
    if (_isListening && !_speechToText.isListening) {
      try {
        await _speechToText.listen(
          onResult: _onSpeechResult,
          listenMode: ListenMode.confirmation,
          pauseFor: const Duration(seconds: 15),
          partialResults: true,
          listenFor: const Duration(seconds: 30),
          cancelOnError: false,
        );
        debugPrint('Restarted listening for voice commands');
      } catch (e) {
        debugPrint('Error restarting speech recognition: $e');
      }
    }
  }

  /// Process speech recognition results
  void _onSpeechResult(result) {
    if (!result.finalResult) {
      // Check partial results for immediate response
      _checkForTriggerPhrase(result.recognizedWords);
      return;
    }

    // Process final result
    final recognizedText = result.recognizedWords.toLowerCase().trim();
    debugPrint('Final recognized: $recognizedText');
    
    _checkForTriggerPhrase(recognizedText);
  }

  /// Check if the recognized text contains a trigger phrase
  void _checkForTriggerPhrase(String text) {
    final normalizedText = text.toLowerCase().trim();
    
    // Check if any trigger phrase matches
    for (final trigger in triggerPhrases) {
      if (normalizedText.contains(trigger)) {
        _handleCommandRecognized(trigger);
        return;
      }
    }
    
    // Also check for partial matches with key words
    if (_containsKeywords(normalizedText)) {
      _handleCommandRecognized('describe');
    }
  }

  /// Check if text contains key command keywords
  bool _containsKeywords(String text) {
    final keywords = ['vision', 'describe', 'see', 'front'];
    int matchCount = 0;
    
    for (final keyword in keywords) {
      if (text.contains(keyword)) {
        matchCount++;
      }
    }
    
    // Need at least 2 keywords to trigger
    return matchCount >= 2;
  }

  /// Handle when a command is recognized
  void _handleCommandRecognized(String command) {
    // Prevent duplicate triggers
    if (_lastRecognizedCommand == command) {
      if (_commandDebounceTimer != null && _commandDebounceTimer!.isActive) {
        debugPrint('Command debounced: $command');
        return;
      }
    }
    
    _lastRecognizedCommand = command;
    _commandDebounceTimer?.cancel();
    _commandDebounceTimer = Timer(_debounceDuration, () {
      _lastRecognizedCommand = '';
    });
    
    debugPrint('Voice command recognized: $command');
    onCommandRecognized?.call(command);
  }

  /// Check if currently listening
  bool get isListening => _isListening;
  
  /// Check if speech recognition is available
  bool get isAvailable => _isInitialized;

  /// Dispose of resources
  void dispose() {
    _commandDebounceTimer?.cancel();
    stopListening();
  }
}
