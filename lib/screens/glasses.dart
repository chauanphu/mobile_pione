import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_uvc_camera/flutter_uvc_camera.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/yolo_service.dart';
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
  bool _modelReady = false;

  // Services
  final YoloService _yoloService = YoloService.instance;
  late final TtsService _ttsService;

  // Auto-detection timer
  Timer? _detectionTimer;

  // UI state
  bool _isLoading = false;

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

    // Initialize YOLO model
    _initializeYoloModel();

    // Auto-detection removed; camera can be opened manually via button
  }

  Future<void> _initializeYoloModel() async {
    try {
      await _ttsService.speak('Loading the YOLO vision model. Please wait.');
      await _yoloService.initializeModel();
      if (mounted) {
        setState(() { _modelReady = true; });
      }
      await _ttsService.speak('Model is ready. Double tap to capture.');
    } catch (e) {
      if (mounted) {
        setState(() { _modelReady = false; });
      }
      await _ttsService.speak('Model failed to load. Error: $e');
    }
  }

  // Auto-detection function removed

  @override
  void dispose() {
    _ttsService.dispose();
    _detectionTimer?.cancel(); // Stop auto-detection
    try {
      cameraController.closeCamera();
    } catch (_) {}
    try {
      cameraController.dispose();
    } catch (_) {}
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
    if (!_modelReady) {
      await _ttsService.speak('Model is still loading. Please wait.');
      return;
    }
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
        "Image captured. Analyzing with YOLO model.",
      );

      // Use YOLO for object detection
      final detections = await _yoloService.detectObjects(imageBytes);
      
      // Generate description from detections
      final description = _yoloService.generateDescription(detections);
      
      // Speak the description
      await _ttsService.speak(description);
      
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      await _ttsService.speak('Failed to analyze image. Error: $e');
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _stopAll() async {
    await _ttsService.stop();
    if (_isLoading) {
      await _ttsService.speak("Stopped");
    }
    setState(() {
      _isLoading = false;
    });
  }
  // Local chunking code replaced by SpeechChunker

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
                child: RotatedBox(
                  quarterTurns: 3, // 90° counter-clockwise
                  child: UVCCameraView(
                    cameraController: cameraController,
                    width: 300,
                    height: 300,
                  ),
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
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: isCameraOpen ? null : _openCamera,
              child: const Text('Open Camera'),
            )
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
