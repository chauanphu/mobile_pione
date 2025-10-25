import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:collection';
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
      title: 'LLM Inference Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final LlmInference _llmInference = LlmInference.instance;
  final TtsService _ttsService =
      TtsService(); // 2. Create an instance of the TTS service
  StreamSubscription<String>? _responseSubscription;
  String _responseText = "";
  bool _isLoading = false;

  // --- NEW STATE VARIABLES FOR CHUNKING ---
  final List<String> _wordBuffer = []; // Holds incoming words
  final Queue<String> _speechQueue = Queue<String>(); // Holds 3-4 word chunks
  bool _isSpeaking = false; // Tracks if TTS is currently busy with a chunk
  // --- NEW CONSTANTS FOR HYBRID STRATEGY ---
  // 1. Minimum words before we consider a weak break (like a comma)
  static const int MIN_WEAK_BREAK_WORDS = 5;
  // 2. The failsafe word limit to prevent long pauses
  static const int FAILSAFE_CHUNK_SIZE = 15;
  // 3. The set of conjunctions to identify as weak breaks
  static const Set<String> _weakBreakWords = {
    'and',
    'but',
    'so',
    'or',
    'because',
    'while',
  };

  @override
  void dispose() {
    _responseSubscription?.cancel();
    _textController.dispose();
    _ttsService.dispose();
    super.dispose();
  }

  void _resetSpeech() {
    _ttsService.stop();
    _speechQueue.clear();
    _wordBuffer.clear();
    _isSpeaking = false;
  }

  void _sendMessage() {
    if (_textController.text.isEmpty) return;
    _resetSpeech();

    setState(() {
      _isLoading = true;
      _responseText = "";
    });

    _responseSubscription?.cancel();

    _responseSubscription = _llmInference
        .generateResponseStream(_textController.text)
        .listen(
          (partialResponse) {
            setState(() {
              _responseText += partialResponse;
            });
            final newWords = partialResponse
                .trim()
                .split(' ')
                .where((w) => w.isNotEmpty);
            _wordBuffer.addAll(newWords);
            _chunkAndQueueWords(); // Process the buffer with our new logic
          },
          onDone: () {
            setState(() {
              _isLoading = false;
            });
            _chunkAndQueueWords(forceChunk: true); // Flush any remaining words
            _textController.clear();
          },
          onError: (e) {
            setState(() {
              _isLoading = false;
              _responseText = "Error: $e";
            });
            _resetSpeech();
          },
        );
  }

  // 4. --- REPLACED: This is the new, more intelligent chunking method ---
  void _chunkAndQueueWords({bool forceChunk = false}) {
    // This loop ensures we create as many chunks as possible from the current buffer
    while (true) {
      int? breakIndex;

      // Scan the buffer to find the best possible break point
      for (int i = 0; i < _wordBuffer.length; i++) {
        String word = _wordBuffer[i].toLowerCase();
        String lastChar = word.isNotEmpty
            ? word.substring(word.length - 1)
            : '';

        // --- Priority 1: Strong Breaks (sentence end) ---
        if (lastChar == '.' || lastChar == '?' || lastChar == '!') {
          breakIndex = i;
          break; // Found the best break, no need to look further
        }

        // --- Priority 2: Weak Breaks (conjunctions, commas) ---
        // We only consider weak breaks after a few words to avoid tiny, choppy chunks
        // if (i >= MIN_WEAK_BREAK_WORDS) {
        //   if (lastChar == ',' || _weakBreakWords.contains(word)) {
        //     breakIndex = i;
        //     break; // Found a decent break, stop searching for now
        //   }
        // }
      }

      // --- Priority 3: Failsafe Break ---
      // If no natural break is found and the buffer is getting long, force a break
      if (breakIndex == null && _wordBuffer.length > FAILSAFE_CHUNK_SIZE) {
        breakIndex = FAILSAFE_CHUNK_SIZE - 1;
      }

      // --- Final flush when the stream is done ---
      if (breakIndex == null && forceChunk && _wordBuffer.isNotEmpty) {
        breakIndex = _wordBuffer.length - 1;
      }

      // If we found any kind of break, create and queue the chunk
      if (breakIndex != null) {
        final chunk = _wordBuffer.sublist(0, breakIndex + 1).join(' ');
        _speechQueue.add(chunk);
        _wordBuffer.removeRange(0, breakIndex + 1);
        _processSpeechQueue(); // Start the speaking process if not already running
      } else {
        // If no break point was found, exit the loop and wait for more words
        break;
      }
    }
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MediaPipe LLM on Flutter'),
        actions: [
          // Add a button to reset the session
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await _llmInference.resetSession();
              _ttsService.stop(); // Stop speaking on reset
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('Session Reset!')));
              setState(() {
                _responseText = "";
              });
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _responseText,
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
              ),
            ),
            if (_isLoading) const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textController,
                    decoration: const InputDecoration(
                      hintText: 'Enter your prompt...',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _sendMessage,
                  style: IconButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
