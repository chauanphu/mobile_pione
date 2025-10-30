import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_uvc_camera/flutter_uvc_camera.dart';
import 'package:permission_handler/permission_handler.dart';

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
        // Consider camera detected when it successfully opens
        if (state == UVCCameraState.opened) {
          _cameraDetected = true;
          _cameraError = null;
        }
      });
    };

    // Surface Android plugin messages to the UI to help diagnosis
    try {
      // Not all versions expose msgCallback; guard with try
      // ignore: invalid_use_of_protected_member
      // ignore: invalid_use_of_visible_for_testing_member
      // The field name is based on plugin README; if absent, this no-ops
      // @ts-ignore dart
      // dynamic is used to avoid analyzer errors if property is missing
      (cameraController as dynamic).msgCallback = (String msg) async {
        debugPrint('[UVC msg] $msg');
        if (!mounted) return;
        setState(() => _cameraError = msg);
        // Heuristics to reflect detection state from messages
        if (msg.contains('No device detected') ||
            msg.contains('not UVC type') ||
            msg.contains('Permission denied')) {
          setState(() {
            _cameraDetected = false;
            isCameraOpen = false;
          });
        }
      };
    } catch (_) {
      // Safe ignore if plugin API changed
    }

    // Auto-detection removed; camera can be opened manually via button
  }

  // Auto-detection function removed

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
    // Ensure runtime permissions like CAMERA (even if not strictly required for UVC,
    // some OEMs/plugins still expect it); this won't grant USB device permission,
    // which is handled via UsbManager/intent.
    final hasPerms = await _ensureRuntimePermissions();
    if (!hasPerms) {
      return;
    }

    setState(() {
      _cameraError = null;
    });
    try {
      // Ensure platform side is initialized before opening
      await cameraController.initializeCamera();
      await cameraController.openUVCCamera();
      // Mark as detected on successful invocation; actual OPENED state will update isCameraOpen
      if (mounted) {
        setState(() {
          _cameraDetected = true;
        });
      }
      await _ttsService.speak("Opening camera...");
    } catch (e) {
      setState(() {
        _cameraError = 'Failed to open UVC camera: $e';
      });
      await _ttsService.speak('Failed to open camera: $e');
    }
  }

  Future<bool> _ensureRuntimePermissions() async {
    final toRequest = <Permission>[Permission.camera];

    final statuses = await toRequest.request();
    final camGranted = statuses[Permission.camera]?.isGranted ?? false;
    if (!camGranted) {
      await _ttsService.speak(
        "Camera permission is required to use the UVC camera.",
      );
      return false;
    }
    return true;
  }

  Future<void> _describeSurroundings() async {
    if (_isLoading || !isCameraOpen) {
      if (_cameraError != null) {
        await _ttsService.speak("Camera error: $_cameraError");
      } else if (_isLoading) {
        await _ttsService.speak("Already processing. Tap stop to cancel.");
      } else {
        await _ttsService.speak(
          "Camera not ready. Please open the camera first.",
        );
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
        prompt:
            'Describe the following scene to identify the objects or obstacles for visual impaired user.',
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

    // Always build the UVCCameraView so the platform view is initialized,
    // then overlay status UI when the camera isn't detected yet.
    return Column(
      children: [
        Expanded(
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 300,
                height: 300,
                child: UVCCameraView(
                  cameraController: cameraController,
                  width: 300,
                  height: 300,
                ),
              ),
              if (!_cameraDetected)
                Container(
                  color: Colors.black.withValues(alpha: 0.5),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.videocam_off, color: Colors.white, size: 64),
                        SizedBox(height: 16),
                        Text(
                          'Searching for UVC Camera...',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Please connect a UVC camera to your device.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70),
                        ),
                        SizedBox(height: 24),
                        CircularProgressIndicator(color: Colors.white),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            ElevatedButton(
              onPressed: isCameraOpen ? null : _openCamera,
              child: const Text('Open Camera'),
            ),
            ElevatedButton(
              onPressed: isCameraOpen
                  ? () => cameraController.closeCamera()
                  : null,
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
        title: Row(children: [const Text('UVC Visual Assistant')]),
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
              color: Colors.black.withValues(alpha: 0.5),
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
