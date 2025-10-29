// FILE: lib/screens/capture_screen.dart
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/llm_inference.dart';
import '../services/tts_service.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  // Camera Controller
  CameraController? _cameraController; // Make controller nullable
  Future<void>? _initializeControllerFuture; // Make future nullable

  // NEW: State variable to track initialization errors
  String? _cameraError;

  // Services
  final LlmInference _llmInference = LlmInference.instance;
  late final TtsService _ttsService;

  // UI State
  bool _isLoading = false;
  final StringBuffer _captionBuffer = StringBuffer();
  StreamSubscription<String>? _captionSubscription;

  // NEW: Debug Text State
  String _debugOutput = "Model output will appear here...";
  final ScrollController _debugScrollController = ScrollController();

  // Chunking state
  final List<String> _wordBuffer = [];
  final Queue<String> _speechQueue = Queue<String>();
  bool _isSpeaking = false;

  // Chunking constants (unchanged)
  static const int MIN_WEAK_BREAK_WORDS = 5;
  static const int FAILSAFE_CHUNK_SIZE = 15;
  static const Set<String> _weakBreakWords = {
    'and',
    'but',
    'so',
    'or',
    'because',
    'while',
  };

  @override
  void initState() {
    super.initState();
    _ttsService = TtsService();
    // MODIFIED: Call the robust initialization method
    _initializeControllerFuture = _initializeCamera();
  }

  // MODIFIED: Refactored camera initialization to be more robust
  Future<void> _initializeCamera() async {
    try {
      // Clear any previous errors
      setState(() {
        _cameraError = null;
      });

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException(
          'No Camera Found',
          'No available cameras on the device.',
        );
      }
      final firstCamera = cameras.first;

      _cameraController = CameraController(
        firstCamera,
        ResolutionPreset.high,
        enableAudio: false,
      );

      await _cameraController!.initialize();
    } on CameraException catch (e) {
      // If an error occurs, update the state to show an error message
      setState(() {
        _cameraError = "Error initializing camera: ${e.description}";
      });
    } catch (e) {
      // Handle other potential errors
      setState(() {
        _cameraError = "An unexpected error occurred: $e";
      });
    }
  }

  @override
  void dispose() {
    _captionSubscription?.cancel();
    _ttsService.dispose();
    _cameraController?.dispose(); // Safely dispose the controller
    super.dispose();
  }

  Future<void> _describeSurroundings() async {
    if (_isLoading ||
        _cameraController == null ||
        !_cameraController!.value.isInitialized) {
      // Announce if camera is not ready or already processing for accessibility
      if (_cameraError != null) {
        await _ttsService.speak("Camera error: $_cameraError");
      } else if (_isLoading) {
        await _ttsService.speak("Already processing. Tap stop to cancel.");
      } else if (_cameraController == null ||
          !_cameraController!.value.isInitialized) {
        await _ttsService.speak("Camera not ready. Please wait.");
      }
      return;
    }

    await _stopAll(); // Stop any previous operation
    setState(() {
      _isLoading = true;
      _debugOutput = "Processing..."; // Update debug output
    });
    await _ttsService.speak("Hold still. Capturing image.");

    try {
      final XFile imageFile = await _cameraController!.takePicture();
      final Uint8List imageBytes = await imageFile.readAsBytes();
      await _ttsService.speak(
        "Image captured. Analyzing. The process may take 10 to 15 seconds.",
      );
      final captionStream = await _llmInference.generateCaptionStream(
        prompt: 'Describe the following scene to identify the objects or obstacles for visual impaired user.',
        image: imageBytes,
      );

      _captionSubscription = captionStream.listen(
        (partialResponse) {
          _captionBuffer.write(partialResponse);
          // NEW: Update debug output in real-time
          setState(() {
            _debugOutput = _captionBuffer.toString();
          });
          // Scroll to the bottom of the debug text box
          _debugScrollController.jumpTo(
            _debugScrollController.position.maxScrollExtent,
          );

          final newWords = partialResponse
              .trim()
              .split(' ')
              .where((w) => w.isNotEmpty);
          _wordBuffer.addAll(newWords);
          _chunkAndQueueWords();
        },
        onDone: () async {
          _chunkAndQueueWords(forceChunk: true);
          setState(() {
            _isLoading = false;
          });
        },
        onError: (error) async {
          await _ttsService.speak('An error occurred during analysis.');
          setState(() {
            _isLoading = false;
            _debugOutput = "Error: $error"; // Update debug output with error
          });
        },
      );
    } catch (e) {
      await _ttsService.speak('Failed to capture image. Please try again.');
      await _llmInference.resetSession();
      setState(() {
        _isLoading = false;
        _debugOutput = "Capture failed: $e"; // Update debug output with error
      });
    }
  }

  Future<void> _stopAll() async {
    await _captionSubscription?.cancel();
    _resetSpeech();
    if (_isLoading) {
      await _ttsService.speak("Stopped");
    }
    setState(() {
      _captionBuffer.clear();
      _isLoading = false;
      _debugOutput = "Model output will appear here..."; // Reset debug output
    });
    await _llmInference.resetSession();
  }

  void _chunkAndQueueWords({bool forceChunk = false}) {
    while (true) {
      int? breakIndex;
      for (int i = 0; i < _wordBuffer.length; i++) {
        String word = _wordBuffer[i].toLowerCase().trim();
        String lastChar = word.isNotEmpty
            ? word.substring(word.length - 1)
            : '';
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
    if (_isSpeaking) return;
    // If the queue of things to say is empty...
    if (_speechQueue.isEmpty) {
      if (!_isLoading) {
        await _ttsService.speak("Done. You can now capture new image.");
        if (mounted) {
          // Check if the widget is still visible
          setState(() {
            _debugOutput = "Model output will appear here...";
          });
        }
      }
      return;
    }
    _isSpeaking = true;
    final chunkToSpeak = _speechQueue.removeFirst();
    await _ttsService.speak(chunkToSpeak);
    _isSpeaking = false;
    _processSpeechQueue();
  }

  void _resetSpeech() {
    _ttsService.stop();
    _speechQueue.clear();
    _wordBuffer.clear();
    _isSpeaking = false;
  }

  // MODIFIED: The main widget returned by the build method
  Widget _buildCameraView(BuildContext context) {
    // 1. If there's an error, display it.
    if (_cameraError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            _cameraError!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.red, fontSize: 18),
          ),
        ),
      );
    }

    // 2. Use the FutureBuilder to wait for initialization.
    return FutureBuilder<void>(
      future: _initializeControllerFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          // If the Future is complete, display the camera preview.
          if (_cameraController == null ||
              !_cameraController!.value.isInitialized) {
            // This case handles if the future completes but controller is still null
            return const Center(child: Text("Camera not available."));
          }
          return Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(_cameraController!),
              if (_isLoading)
                Container(
                  color: Colors.black.withValues(alpha: 0.5),
                  child: const Center(
                    child: CircularProgressIndicator(color: Colors.white),
                  ),
                ),
            ],
          );
        } else {
          // Otherwise, display a loading indicator.
          return const Center(child: CircularProgressIndicator());
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // This is needed for AutomaticKeepAliveClientMixin

    return Scaffold(
      appBar: AppBar(title: const Text('Visual Assistant')),
      body: Stack(
        // Use a single Stack for all layered elements.
        // fit: StackFit.expand ensures the Stack fills the body.
        fit: StackFit.expand,
        children: [
          // 1. Camera View is the base layer.
          _buildCameraView(context),

          // 2. A full-screen GestureDetector for the double-tap action.
          // It sits invisibly on top of the camera view.
          GestureDetector(
            onDoubleTap: _describeSurroundings,
            // Ensures it captures taps even in transparent areas.
            behavior: HitTestBehavior.opaque,
            // Provide an accessibility label for the tap area.
            child: Semantics(
              label:
                  "Camera View. Double-tap anywhere to describe surroundings.",
            ),
          ),

          // 3. The loading overlay, which appears only when processing.
          if (_isLoading)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),

          // 4. The debug output box, aligned to the bottom.
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              width: double.infinity,
              height: 100, // The height of the debug box.
              padding: const EdgeInsets.all(8.0),
              color: Colors.black.withOpacity(0.7),
              child: SingleChildScrollView(
                controller: _debugScrollController,
                child: Text(
                  _debugOutput,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ),
          ),

          // 5. The Stop Button, positioned right above the debug box.
          Positioned(
            right: 16.0, // 16 pixels from the right edge.
            // The button's bottom edge will be 116 pixels from the screen's bottom:
            // 100px (height of debug box) + 16px (for padding).
            bottom: 100.0 + 16.0,
            child: FloatingActionButton(
              heroTag: 'stopButton',
              onPressed: _isLoading ? _stopAll : null,
              backgroundColor: _isLoading ? Colors.red : Colors.grey,
              tooltip: 'Stop current process',
              child: const Icon(Icons.stop),
            ),
          ),
        ],
      ),
    );
  }
}
