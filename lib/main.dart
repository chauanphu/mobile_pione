// FILE: lib/main.dart
import 'dart:async';
import 'dart:collection'; // Required for Queue
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'llm_inference.dart';
import 'tts_service.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VLM Assistant',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.deepPurple,
          brightness: Brightness.dark, // High-contrast dark theme
        ),
        useMaterial3: true,
      ),
      home: const CaptionScreen(),
    );
  }
}

class CaptionScreen extends StatefulWidget {
  const CaptionScreen({super.key});

  @override
  State<CaptionScreen> createState() => _CaptionScreenState();
}

class _CaptionScreenState extends State<CaptionScreen> {
  // Services
  final LlmInference _llmInference = LlmInference.instance;
  late final TtsService _ttsService;

  // UI State
  bool _isLoading = false;
  String _errorMessage = '';
  final StringBuffer _captionBuffer = StringBuffer();
  StreamSubscription<String>? _captionSubscription;
  
// --- NEW STATE VARIABLES FOR CHUNKING ---
  final List<String> _wordBuffer = []; // Holds incoming words from the model
  final Queue<String> _speechQueue = Queue<String>(); // Holds sentence chunks to be spoken
  bool _isSpeaking = false; // Tracks if TTS is currently busy speaking a chunk

  // --- NEW CONSTANTS FOR HYBRID CHUNKING STRATEGY ---
  static const int MIN_WEAK_BREAK_WORDS = 5;
  static const int FAILSAFE_CHUNK_SIZE = 15;
  static const Set<String> _weakBreakWords = {
    'and', 'but', 'so', 'or', 'because', 'while',
  };

  @override
  void initState() {
    super.initState();
    _ttsService = TtsService();
  }

  @override
  void dispose() {
    _captionSubscription?.cancel();
    _ttsService.dispose();
    super.dispose();
  }

  /// Handles the entire process: take picture, get caption, and speak.
  Future<void> _describeSurroundings() async {
    // 1. Reset state before starting
    await _stopAll(); 
    setState(() {
      _isLoading = true;
    });

    try {
      // 2. Take a picture using the camera
      final imagePicker = ImagePicker();
      final XFile? imageFile = await imagePicker.pickImage(
        source: ImageSource.camera,
      );

      if (imageFile == null) {
        setState(() => _isLoading = false);
        return; // User canceled the camera
      }

      final Uint8List imageBytes = await imageFile.readAsBytes();

      // 3. Get the response stream from the model
      final captionStream = await _llmInference.generateCaptionStream(
        prompt: 'Describe my surroundings in detail for a visually impaired person.',
        image: imageBytes,
      );

      // 4. Listen to the stream and process data chunks
      _captionSubscription = captionStream.listen(
        (partialResponse) {
          // As each piece of the caption arrives...
          setState(() => _captionBuffer.write(partialResponse));
          // 2. Add new words to the buffer
          final newWords = partialResponse.trim().split(' ').where((w) => w.isNotEmpty);
          _wordBuffer.addAll(newWords);

          // 3. Process the buffer to create speech chunks
          _chunkAndQueueWords();
        },
        onDone: () {
          // When the model is finished
          _chunkAndQueueWords(forceChunk: true);
          setState(() => _isLoading = false);
        },
        onError: (error) {
          setState(() {
            _errorMessage = "An error occurred: $error";
            _isLoading = false;
          });
        },
      );
    } catch (e) {
      setState(() {
        _errorMessage = "Failed to start process: $e";
        _isLoading = false;
      });
    }
  }

  /// The new, more intelligent chunking method.
  void _chunkAndQueueWords({bool forceChunk = false}) {
    while (true) {
      int? breakIndex;

      // Scan the buffer to find the best possible break point
      for (int i = 0; i < _wordBuffer.length; i++) {
        String word = _wordBuffer[i].toLowerCase().trim();
        String lastChar = word.isNotEmpty ? word.substring(word.length - 1) : '';

        // Priority 1: Strong Breaks (sentence end: '.', '?', '!')
        if ('.?!'.contains(lastChar)) {
          breakIndex = i;
          break;
        }

        // Priority 2: Weak Breaks (conjunctions, commas) after a minimum word count
        if (i >= MIN_WEAK_BREAK_WORDS) {
          if (lastChar == ',' || _weakBreakWords.contains(word)) {
            breakIndex = i;
            break;
          }
        }
      }

      // Priority 3: Failsafe Break if no natural break is found
      if (breakIndex == null && _wordBuffer.length > FAILSAFE_CHUNK_SIZE) {
        breakIndex = FAILSAFE_CHUNK_SIZE - 1;
      }

      // Final flush when the stream is done
      if (breakIndex == null && forceChunk && _wordBuffer.isNotEmpty) {
        breakIndex = _wordBuffer.length - 1;
      }

      if (breakIndex != null) {
        final chunk = _wordBuffer.sublist(0, breakIndex + 1).join(' ');
        _speechQueue.add(chunk);
        _wordBuffer.removeRange(0, breakIndex + 1);
        _processSpeechQueue(); // Start speaking if not already busy
      } else {
        break; // No break found, wait for more words
      }
    }
  }

/// Speaks chunks from the queue sequentially.
  Future<void> _processSpeechQueue() async {
    if (_isSpeaking || _speechQueue.isEmpty) {
      return;
    }
    _isSpeaking = true;
    final chunkToSpeak = _speechQueue.removeFirst();

    await _ttsService.speak(chunkToSpeak);
    
    _isSpeaking = false;
    // Immediately check for the next chunk to create a continuous flow
    _processSpeechQueue();
  }

  /// Stops all ongoing processes: model stream and TTS.
  Future<void> _stopAll() async {
    await _captionSubscription?.cancel();
    _resetSpeech(); // Use the new reset helper
    setState(() {
      _captionBuffer.clear();
      _errorMessage = '';
      _isLoading = false;
    });
  }

  /// Clears all speech-related state variables and stops TTS.
  void _resetSpeech() {
    _ttsService.stop();
    _speechQueue.clear();
    _wordBuffer.clear();
    _isSpeaking = false;
  }

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(fontSize: 18);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Visual Assistant'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // --- Display Area for Caption ---
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(12.0),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade700),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    _isLoading && _captionBuffer.isEmpty
                        ? 'Analyzing surroundings...'
                        : _errorMessage.isNotEmpty
                            ? _errorMessage
                            : _captionBuffer.isNotEmpty
                                ? _captionBuffer.toString()
                                : 'Press the button below to take a picture and describe your surroundings.',
                    style: textStyle,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            
            // --- Action Buttons ---
            if (_isLoading)
              // Show a STOP button when processing
              ElevatedButton.icon(
                onPressed: _stopAll,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Stop'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 20.0),
                  backgroundColor: Colors.redAccent,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(fontSize: 18),
                ),
              )
            else
              // Show the primary CAPTION button
              ElevatedButton.icon(
                onPressed: _describeSurroundings,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Describe Surroundings'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 20.0),
                  textStyle: const TextStyle(fontSize: 18),
                ),
              ),
          ],
        ),
      ),
    );
  }
}