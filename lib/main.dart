import 'package:flutter/material.dart';
import 'dart:async';
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

  @override
  void dispose() {
    _responseSubscription?.cancel();
    _textController.dispose();
    _ttsService.dispose(); // 3. Dispose the TTS service to release resources
    super.dispose();
  }

  void _sendMessage() {
    if (_textController.text.isEmpty) return;
    _ttsService.stop();

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
            _ttsService.speak(partialResponse);
          },
          onDone: () {
            // When the stream is finished, mark as not loading
            setState(() {
              _isLoading = false;
            });
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
