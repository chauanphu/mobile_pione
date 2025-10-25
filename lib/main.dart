import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:collection'; // 1. Import for Queue
import 'llm_inference.dart'; // Import your new wrapper class
import 'tts_service.dart'; // 1. Import the new TTS service

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
  static const int CHUNK_SIZE = 5; // The number of words in each chunk

  @override
  void dispose() {
    _responseSubscription?.cancel();
    _textController.dispose();
    _ttsService.dispose(); // 3. Dispose the TTS service to release resources
    super.dispose();
  }

  // 2. New method to stop everything and clear state
  void _resetSpeech() {
    _ttsService.stop();
    _speechQueue.clear();
    _wordBuffer.clear();
    _isSpeaking = false;
  }

  void _sendMessage() {
    if (_textController.text.isEmpty) return;
    _resetSpeech(); // Use our new reset method

    setState(() {
      _isLoading = true;
      _responseText = "";
    });

    // Cancel any previous stream subscription
    _responseSubscription?.cancel();

    // Start listening to the new stream
    _responseSubscription = _llmInference
        .generateResponseStream(_textController.text)
        .listen(
          (partialResponse) {
            // Append each partial result to our display text
            setState(() {
              _responseText += partialResponse;
            });
            final newWords = partialResponse
                .trim()
                .split(' ')
                .where((w) => w.isNotEmpty);
            _wordBuffer.addAll(newWords);
            _chunkAndQueueWords(); // Turn the buffer into speakable chunks
          },
          onDone: () {
            // When the stream is finished, mark as not loading
            setState(() {
              _isLoading = false;
            });
            // 4. After the stream is done, speak any remaining words in the buffer
            _chunkAndQueueWords(forceChunk: true);
            _textController.clear();
          },
          onError: (e) {
            // Handle any errors from the stream
            setState(() {
              _isLoading = false;
              _responseText = "Error: $e";
            });
          },
        );
  }

  // 5. New method to create chunks from the word buffer
  void _chunkAndQueueWords({bool forceChunk = false}) {
    // Process full chunks
    while (_wordBuffer.length >= CHUNK_SIZE) {
      final chunk = _wordBuffer.sublist(0, CHUNK_SIZE).join(' ');
      _speechQueue.add(chunk);
      _wordBuffer.removeRange(0, CHUNK_SIZE);
      _processSpeechQueue(); // Start speaking if not already
    }

    // If forced (at the end of a response), queue any remaining words
    if (forceChunk && _wordBuffer.isNotEmpty) {
      final remainingChunk = _wordBuffer.join(' ');
      _speechQueue.add(remainingChunk);
      _wordBuffer.clear();
      _processSpeechQueue(); // Start speaking if not already
    }
  }

  // 6. New method to process the queue and speak chunks sequentially
  Future<void> _processSpeechQueue() async {
    // If we're already speaking or the queue is empty, do nothing.
    if (_isSpeaking || _speechQueue.isEmpty) {
      return;
    }

    // Mark as busy
    _isSpeaking = true;

    // Get the next chunk from the queue
    final chunkToSpeak = _speechQueue.removeFirst();

    // Speak the chunk and wait for it to complete
    await _ttsService.speak(chunkToSpeak);

    // Mark as not busy
    _isSpeaking = false;

    // IMPORTANT: After finishing, immediately check if there's more to speak.
    // This creates the loop that drains the queue.
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
