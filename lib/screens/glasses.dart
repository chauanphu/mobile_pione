import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

import 'package:flutter/material.dart';
import 'package:flutter_uvc_camera/flutter_uvc_camera.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/yolo_service.dart';
import '../services/tts_service.dart';
import '../widgets/bounding_box_painter.dart';

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
  
  // Periodic detection timer (every 5 seconds)
  Timer? _periodicDetectionTimer;
  
  // Cooldown timer (5 seconds after processing completes)
  Timer? _cooldownTimer;
  bool _inCooldown = false;
  
  // Current detections for bounding box visualization
  List<Map<String, dynamic>> _currentDetections = [];
  Size _currentImageSize = Size(
    YoloService.inputWidth.toDouble(),
    YoloService.inputHeight.toDouble(),
  );

  // UI state
  bool _isLoading = false;

  // Angle (degrees) to rotate captured image to match displayed orientation.
  // RotatedBox in the UI uses quarterTurns: 3 (270°). We rotate the input
  // image by the same amount so the model sees the same orientation as the UI.
  // Change this value if your camera hardware produces a different rotation.
  final int _inputCorrectionAngle = 270;

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
          _startPeriodicDetection();
        } else {
          _stopPeriodicDetection();
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
        // Heuristics to reflect detection state from messages
        if (msg.contains('No device detected') ||
            msg.contains('not UVC type') ||
            msg.contains('Permission denied')) {
          setState(() {
            _cameraError = msg;
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
      await _ttsService.speak('Model is ready.');
      _startPeriodicDetection();
    } catch (e) {
      if (mounted) {
        setState(() { _modelReady = false; });
      }
      await _ttsService.speak('Model failed to load.');
      debugPrint('Error initializing YOLO model: $e');
    }
  }

  // Auto-detection function removed

  void _startPeriodicDetection() {
    _stopPeriodicDetection();
    if (!_modelReady) return;
    
    // Start periodic detection every 5 seconds
    _periodicDetectionTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (isCameraOpen && _modelReady && !_isLoading) {
        _runPeriodicDetection();
      }
    });
  }

  void _stopPeriodicDetection() {
    _periodicDetectionTimer?.cancel();
    _periodicDetectionTimer = null;
  }

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() {
      _inCooldown = true;
    });
    _cooldownTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _inCooldown = false;
        });
      }
      _cooldownTimer = null;
    });
  }

  Future<void> _runPeriodicDetection() async {
    if (!_modelReady || !isCameraOpen || _inCooldown) return;
    
    setState(() => _isLoading = true);
    await _ttsService.speak("Capture.");
    try {
      final String? path = await cameraController.takePicture();
      if (path == null) return;
  final Uint8List rawImageBytes = await File(path).readAsBytes();

  // Rotate the input image bytes to match the UI orientation so the
  // model receives the same visual orientation the user sees.
  final Uint8List imageBytes = _rotateImageBytesIfNeeded(rawImageBytes, _inputCorrectionAngle);

  // Use YOLO for object detection
  final detections = await _yoloService.detectObjects(imageBytes);
      
      debugPrint('YOLO detections: ${detections.length} objects found');
      if (detections.isNotEmpty) {
        debugPrint('First detection: ${detections.first}');
      }
      
      // Update detections for bounding box visualization
      if (mounted) {
        setState(() {
          _currentDetections = detections;
          _currentImageSize = _deriveImageSize(detections) ?? _currentImageSize;
        });
      }
      
      // Generate description from detections
      final description = _yoloService.generateDescription(detections);
      
      // Speak the description and wait for it to complete
      await _ttsService.speak(description);
      
      // Start 5-second cooldown after processing and TTS complete
      _startCooldown();
    } catch (e) {
      debugPrint('Error during periodic detection: $e');
      await _ttsService.speak('An error occurred during detection.');
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Size? _deriveImageSize(List<Map<String, dynamic>> detections) {
    if (detections.isEmpty) return null;
    final width = (detections.first['imageWidth'] as num?)?.toDouble();
    final height = (detections.first['imageHeight'] as num?)?.toDouble();
    if (width == null || height == null || width <= 0 || height <= 0) {
      return null;
    }
    return Size(width, height);
  }

  /// Rotate input image bytes by [angleDegrees] if needed.
  /// Returns original bytes on failure or when angle is a multiple of 360.
  Uint8List _rotateImageBytesIfNeeded(Uint8List bytes, int angleDegrees) {
    final normalized = ((angleDegrees % 360) + 360) % 360;
    if (normalized == 0) return bytes;

    try {
      final img.Image? src = img.decodeImage(bytes);
      if (src == null) return bytes;

  final img.Image rotated = img.copyRotate(src, angle: normalized);
      final List<int> encoded = img.encodeJpg(rotated, quality: 90);
      return Uint8List.fromList(encoded);
    } catch (e) {
      debugPrint('Image rotation failed: $e');
      return bytes;
    }
  }

  @override
  void dispose() {
    _ttsService.dispose();
    _detectionTimer?.cancel(); // Stop auto-detection
    _stopPeriodicDetection();
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
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 320,
                    height: 320,
                    child: RotatedBox(
                      quarterTurns: 3, // 90° counter-clockwise
                      child: UVCCameraView(
                        cameraController: cameraController,
                        width: 640,
                        height: 640,
                      ),
                    ),
                  ),
                  // Bounding box overlay - must match the display size exactly
                  if (_currentDetections.isNotEmpty && isCameraOpen)
                    SizedBox(
                      width: 320,
                      height: 320,
                      child: CustomPaint(
                        painter: BoundingBoxPainter(
                          detections: _currentDetections,
                          imageSize: _currentImageSize,
                        ),
                      ),
                    ),
                ],
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
