import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_uvc_camera/flutter_uvc_camera.dart';

import '../services/llm_inference.dart';
import '../services/tts_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  late UVCCameraController cameraController;
  bool isCameraOpen = false;
  String? _cameraError;
  bool _cameraDetected = false;
  bool _isAutoDetecting = false;

  // Services
  final LlmInference _llmInference = LlmInference.instance;
  late final TtsService _ttsService;
  
  // Auto-detection timer
  Timer? _detectionTimer;

  // UI / streaming state
  bool _isLoading = false;
  final StringBuffer _captionBuffer = StringBuffer();
  StreamSubscription<String>? _captionSubscription;

  // Debug output
  final ScrollController _debugScrollController = ScrollController();

  // Chunking state
  final List<String> _wordBuffer = [];
  final Queue<String> _speechQueue = Queue<String>();
  bool _isSpeaking = false;

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
    cameraController = UVCCameraController();
    _ttsService = TtsService();

    // Camera state callback
    cameraController.cameraStateCallback = (state) {
      setState(() {
        isCameraOpen = state == UVCCameraState.opened;
      });
    };

    // Start auto-detection immediately
    _startCameraAutoDetection();
  }

  /// Auto-detect UVC camera on USB connection with periodic polling
  Future<void> _startCameraAutoDetection() async {
    if (_isAutoDetecting) return;
    
    setState(() {
      _isAutoDetecting = true;
    });

    // Stop any existing timer
    _detectionTimer?.cancel();

    // Poll for camera every 2 seconds
    _detectionTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) async {
        try {
          // Attempt to get camera features to verify camera presence
          final features = await cameraController.getAllCameraFeatures();
          final cameraFound = features != null;

          if (cameraFound && !_cameraDetected) {
            // Camera just detected!
            setState(() {
              _cameraDetected = true;
              _cameraError = null;
            });
            await _ttsService.speak(
              "UVC camera detected and ready. You can now capture images.",
            );
            debugPrint("✓ UVC Camera auto-detected!");
          } else if (!cameraFound && _cameraDetected) {
            // Camera was disconnected
            setState(() {
              _cameraDetected = false;
              isCameraOpen = false;
            });
            await _ttsService.speak("UVC camera disconnected.");
            debugPrint("✗ UVC Camera disconnected!");
          }
        } catch (e) {
          // Silent fail - camera might not be ready yet
          if (_cameraDetected) {
            setState(() {
              _cameraDetected = false;
              isCameraOpen = false;
            });
          }
        }
      },
    );
  }

  @override
  void dispose() {
    _captionSubscription?.cancel();
    _ttsService.dispose();
    _detectionTimer?.cancel(); // Stop auto-detection
    try {
      cameraController.closeCamera();
    } catch (_) {}
    try {
      cameraController.dispose();
    } catch (_) {}
    _debugScrollController.dispose();
    super.dispose();
  }

  Future<void> _openCamera() async {
    if (!_cameraDetected) {
      await _ttsService.speak("No UVC camera detected. Please connect a camera.");
      setState(() {
        _cameraError = "Camera not detected. Please connect a UVC camera.";
      });
      return;
    }

    setState(() {
      _cameraError = null;
    });
    try {
      await cameraController.openUVCCamera();
      await _ttsService.speak("Camera opened successfully.");
    } catch (e) {
      setState(() {
        _cameraError = 'Failed to open UVC camera: $e';
      });
      await _ttsService.speak('Failed to open camera: $e');
    }
  }

  Future<void> _describeSurroundings() async {
    if (_isLoading || !isCameraOpen) {
      if (_cameraError != null) {
        await _ttsService.speak("Camera error: $_cameraError");
      } else if (_isLoading) {
        await _ttsService.speak("Already processing. Tap stop to cancel.");
      } else {
        await _ttsService.speak("Camera not ready. Please open the camera first.");
      }
      return;
    }

    await _stopAll();
    setState(() {
      _isLoading = true;
    });
    await _ttsService.speak("Hold still. Capturing image.");

    try {
      final String? path = await cameraController.takePicture();
      if (path == null) throw 'No picture path returned';
      final Uint8List imageBytes = await File(path).readAsBytes();

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
          });
        },
      );
    } catch (e) {
      await _ttsService.speak('Failed to capture image. Please try again.');
      await _llmInference.resetSession();
      setState(() {
        _isLoading = false;
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
    });
    await _llmInference.resetSession();
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
    if (_isSpeaking) return;
    if (_speechQueue.isEmpty) {
      if (!_isLoading) {
        await _ttsService.speak("Done. You can now capture new image.");
        if (mounted) {
          setState(() {
            // Processing complete
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

  Widget _buildCameraView(BuildContext context) {
    if (_cameraError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, color: Colors.red, size: 48),
              const SizedBox(height: 16),
              Text(
                _cameraError!,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red, fontSize: 18),
              ),
              const SizedBox(height: 24),
              if (!_cameraDetected)
                const Text(
                  'Please connect a UVC camera via USB.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.orange, fontSize: 14),
                ),
            ],
          ),
        ),
      );
    }

    if (!_cameraDetected) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.videocam_off, color: Colors.grey, size: 64),
            const SizedBox(height: 16),
            const Text(
              'Searching for UVC Camera...',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              'Please connect a UVC camera to your device.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            const CircularProgressIndicator(),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(
          child: UVCCameraView(
            cameraController: cameraController,
            width: 300,
            height: 300,
          ),
        ),
        SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton(
              onPressed: isCameraOpen ? null : _openCamera,
              child: const Text('Open Camera'),
            ),
            ElevatedButton(
              onPressed: isCameraOpen ? () => cameraController.closeCamera() : null,
              child: const Text('Close Camera'),
            ),
            ElevatedButton(
              onPressed: isCameraOpen ? _describeSurroundings : null,
              child: const Text('Capture & Describe'),
            ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('UVC Visual Assistant'),
            const SizedBox(width: 12),
            _cameraDetected
                ? const Chip(
                    label: Text('Camera Connected'),
                    backgroundColor: Colors.green,
                    labelStyle: TextStyle(color: Colors.white, fontSize: 12),
                  )
                : const Chip(
                    label: Text('Waiting for Camera...'),
                    backgroundColor: Colors.orange,
                    labelStyle: TextStyle(color: Colors.white, fontSize: 12),
                  ),
          ],
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildCameraView(context),

          // Transparent full screen gesture for double-tap
          if (isCameraOpen)
            GestureDetector(
              onDoubleTap: _describeSurroundings,
              behavior: HitTestBehavior.opaque,
              child: Semantics(
                label:
                    'Camera View. Double-tap anywhere to describe surroundings.',
              ),
            ),

          if (_isLoading)
            Container(
              color: Colors.black.withOpacity(0.5),
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),

          Positioned(
            right: 16.0,
            bottom: 100.0 + 16.0,
            child: FloatingActionButton(
              heroTag: 'uvcStopButton',
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