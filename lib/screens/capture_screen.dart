import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/llm_inference.dart';
import '../services/tts_service.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  // Services
  final LlmInference _llmInference = LlmInference.instance;
  late final TtsService _ttsService;

  // UI State
  bool _isLoading = false;
  String _errorMessage = '';
  final StringBuffer _captionBuffer = StringBuffer();
  StreamSubscription<String>? _captionSubscription;

  // Chunking state
  final List<String> _wordBuffer = [];
  final Queue<String> _speechQueue = Queue<String>();
  bool _isSpeaking = false;

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

  Future<void> _describeSurroundings() async {
    await _stopAll();
    setState(() => _isLoading = true);

    try {
      final imagePicker = ImagePicker();
      final XFile? imageFile = await imagePicker.pickImage(source: ImageSource.camera);

      if (imageFile == null) {
        setState(() => _isLoading = false);
        return;
      }

      final Uint8List imageBytes = await imageFile.readAsBytes();

      final captionStream = await _llmInference.generateCaptionStream(
        prompt: 'Describe my surroundings in detail for a visually impaired person.',
        image: imageBytes,
      );

      _captionSubscription = captionStream.listen(
        (partialResponse) {
          setState(() => _captionBuffer.write(partialResponse));
          final newWords = partialResponse.trim().split(' ').where((w) => w.isNotEmpty);
          _wordBuffer.addAll(newWords);
          _chunkAndQueueWords();
        },
        onDone: () {
          _chunkAndQueueWords(forceChunk: true);
          setState(() => _isLoading = false);
        },
        onError: (error) {
          setState(() {
            _errorMessage = 'An error occurred: $error';
            _isLoading = false;
          });
        },
      );
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to start process: $e';
        _isLoading = false;
      });
    }
  }

  void _chunkAndQueueWords({bool forceChunk = false}) {
    while (true) {
      int? breakIndex;

      for (int i = 0; i < _wordBuffer.length; i++) {
        String word = _wordBuffer[i].toLowerCase().trim();
        String lastChar = word.isNotEmpty ? word.substring(word.length - 1) : '';

        if ('.?!'.contains(lastChar)) {
          breakIndex = i;
          break;
        }

        if (i >= MIN_WEAK_BREAK_WORDS) {
          if (lastChar == ',' || _weakBreakWords.contains(word)) {
            breakIndex = i;
            break;
          }
        }
      }

      if (breakIndex == null && _wordBuffer.length > FAILSAFE_CHUNK_SIZE) {
        breakIndex = FAILSAFE_CHUNK_SIZE - 1;
      }

      if (breakIndex == null && forceChunk && _wordBuffer.isNotEmpty) {
        breakIndex = _wordBuffer.length - 1;
      }

      if (breakIndex != null) {
        final chunk = _wordBuffer.sublist(0, breakIndex + 1).join(' ');
        _speechQueue.add(chunk);
        _wordBuffer.removeRange(0, breakIndex + 1);
        _processSpeechQueue();
      } else {
        break;
      }
    }
  }

  Future<void> _processSpeechQueue() async {
    if (_isSpeaking || _speechQueue.isEmpty) return;
    _isSpeaking = true;
    final chunkToSpeak = _speechQueue.removeFirst();
    await _ttsService.speak(chunkToSpeak);
    _isSpeaking = false;
    _processSpeechQueue();
  }

  Future<void> _stopAll() async {
    await _captionSubscription?.cancel();
    _resetSpeech();
    setState(() {
      _captionBuffer.clear();
      _errorMessage = '';
      _isLoading = false;
    });
  }

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
      appBar: AppBar(title: const Text('Visual Assistant')),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            if (_isLoading)
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
