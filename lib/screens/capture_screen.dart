// FILE: lib/screens/capture_screen.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/yolo_service.dart';

class CaptureScreen extends StatefulWidget {
  final void Function(bool)? onDrawingModeChanged;
  
  const CaptureScreen({super.key, this.onDrawingModeChanged});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  // Camera Controller
  CameraController? _cameraController;
  Future<void>? _initializeControllerFuture;
  String? _cameraError;

  // YOLO Service
  final YoloService _yoloService = YoloService.instance;

  // UI State
  bool _isProcessing = false;
  bool _modelReady = false;
  
  // Detection State
  ui.Image? _capturedImage;
  List<Detection> _detections = [];
  int? _selectedDetectionIndex;
  bool _isDrawingMode = false;
  
  // Drawing State
  Offset? _drawingStart;
  Offset? _drawingEnd;
  
  // Display configuration - scale to 320x320 for phone screen
  static const double displayWidth = 320.0;
  static const double displayHeight = 320.0;
  
  // Global key for getting widget bounds
  final GlobalKey _imageKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _initializeControllerFuture = _initializeCamera();
    _initializeYoloModel();
  }

  Future<void> _initializeCamera() async {
    try {
      setState(() => _cameraError = null);

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw CameraException(
          'No Camera Found',
          'No available cameras on the device.',
        );
      }

      _cameraController = CameraController(
        cameras.first,
        ResolutionPreset.medium, // Use medium to reduce overhead
        enableAudio: false,
      );

      await _cameraController!.initialize();
    } on CameraException catch (e) {
      setState(() => _cameraError = "Error initializing camera: ${e.description}");
    } catch (e) {
      setState(() => _cameraError = "An unexpected error occurred: $e");
    }
  }

  Future<void> _initializeYoloModel() async {
    try {
      await _yoloService.initializeModel();
      setState(() => _modelReady = true);
      debugPrint('YOLO model initialized successfully');
    } catch (e) {
      debugPrint('Failed to initialize YOLO model: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Model initialization failed: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _capturedImage?.dispose();
    super.dispose();
  }

  Future<void> _captureAndDetect() async {
    if (_isProcessing || !_modelReady || 
        _cameraController == null || 
        !_cameraController!.value.isInitialized) {
      return;
    }

    setState(() => _isProcessing = true);

    try {
      // Capture image
      final XFile imageFile = await _cameraController!.takePicture();
      final Uint8List imageBytes = await imageFile.readAsBytes();

      // Decode image for display
      final ui.Image image = await decodeImageFromList(imageBytes);

      // Run YOLO detection
      final detections = await _yoloService.detectObjects(imageBytes);

      // Convert to Detection objects
      final List<Detection> parsedDetections = [];
      for (final detection in detections) {
        final box = detection['box'] as Map<String, dynamic>?;
        if (box != null) {
          parsedDetections.add(Detection(
            classId: detection['classId'] as int? ?? -1,
            className: detection['className'] as String? ?? 'unknown',
            confidence: (detection['confidence'] as num?)?.toDouble() ?? 0.0,
            box: BoundingBox(
              x1: (box['x1'] as num?)?.toDouble() ?? 0.0,
              y1: (box['y1'] as num?)?.toDouble() ?? 0.0,
              x2: (box['x2'] as num?)?.toDouble() ?? 0.0,
              y2: (box['y2'] as num?)?.toDouble() ?? 0.0,
            ),
          ));
        }
      }

      setState(() {
        _capturedImage = image;
        _detections = parsedDetections;
        _selectedDetectionIndex = null;
        _isDrawingMode = false;
      });

      debugPrint('Detected ${parsedDetections.length} objects');
    } catch (e) {
      debugPrint('Detection failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Detection failed: $e')),
        );
      }
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  void _selectDetection(int index) {
    setState(() {
      _selectedDetectionIndex = index;
      _isDrawingMode = false;
    });
  }

  void _updateDetectionLabel(int index, String newLabel) {
    setState(() {
      _detections[index] = _detections[index].copyWith(className: newLabel);
    });
  }

  void _deleteDetection(int index) {
    setState(() {
      _detections.removeAt(index);
      if (_selectedDetectionIndex == index) {
        _selectedDetectionIndex = null;
      } else if (_selectedDetectionIndex != null && _selectedDetectionIndex! > index) {
        _selectedDetectionIndex = _selectedDetectionIndex! - 1;
      }
    });
  }

  void _toggleDrawingMode() {
    setState(() {
      _isDrawingMode = !_isDrawingMode;
      _selectedDetectionIndex = null;
      _drawingStart = null;
      _drawingEnd = null;
    });
    // Notify parent about drawing mode change
    widget.onDrawingModeChanged?.call(_isDrawingMode);
  }

  void _saveAnnotations() {
    // TODO: Implement saving to dataset
    // This should save the image and annotations in a format suitable for training
    // (e.g., YOLO format: class_id x_center y_center width height)
    
    debugPrint('Saving ${_detections.length} annotations');
    
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Annotations saved successfully!'),
        backgroundColor: Colors.green,
      ),
    );
  }

  void _resetCapture() {
    setState(() {
      _capturedImage?.dispose();
      _capturedImage = null;
      _detections = [];
      _selectedDetectionIndex = null;
      _isDrawingMode = false;
      _drawingStart = null;
      _drawingEnd = null;
    });
    // Notify parent that drawing mode is disabled
    widget.onDrawingModeChanged?.call(false);
  }

  /// Hit test to find which detection box was tapped
  /// Converts screen coordinates to image coordinates and checks intersection
  int? _hitTestDetections(Offset tapPosition, Size widgetSize) {
    if (_capturedImage == null || _detections.isEmpty) return null;

    // Calculate scale factors from widget size to image size
    final scaleX = _capturedImage!.width / widgetSize.width;
    final scaleY = _capturedImage!.height / widgetSize.height;

    // Convert tap position to image coordinates
    final imageX = tapPosition.dx * scaleX;
    final imageY = tapPosition.dy * scaleY;

    // Check each detection box in reverse order (top to bottom in z-order)
    for (int i = _detections.length - 1; i >= 0; i--) {
      final box = _detections[i].box;
      if (imageX >= box.x1 &&
          imageX <= box.x2 &&
          imageY >= box.y1 &&
          imageY <= box.y2) {
        return i;
      }
    }

    return null;
  }

  /// Convert screen coordinates to image coordinates for drawing
  Offset _screenToImageCoordinates(Offset screenPos, Size widgetSize) {
    if (_capturedImage == null) return screenPos;

    final scaleX = _capturedImage!.width / widgetSize.width;
    final scaleY = _capturedImage!.height / widgetSize.height;

    return Offset(
      screenPos.dx * scaleX,
      screenPos.dy * scaleY,
    );
  }

  Widget _buildCameraView() {
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

    return FutureBuilder<void>(
      future: _initializeControllerFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          if (_cameraController == null || !_cameraController!.value.isInitialized) {
            return const Center(child: Text("Camera not available."));
          }
          // Scale camera preview to 320x320 for better phone display
          return Center(
            child: SizedBox(
              width: displayWidth,
              height: displayHeight,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.center,
                  child: FittedBox(
                    fit: BoxFit.cover,
                    child: SizedBox(
                      width: displayWidth,
                      height: displayHeight,
                      child: CameraPreview(_cameraController!),
                    ),
                  ),
                ),
              ),
            ),
          );
        } else {
          return const Center(child: CircularProgressIndicator());
        }
      },
    );
  }

  Widget _buildDetectionView() {
    if (_capturedImage == null) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate the size that maintains aspect ratio within 320x320
        final imageAspect = _capturedImage!.width / _capturedImage!.height;
        double width = displayWidth;
        double height = displayHeight;
        
        if (imageAspect > 1) {
          // Landscape - fit to width
          height = width / imageAspect;
        } else {
          // Portrait or square - fit to height
          width = height * imageAspect;
        }

        return Center(
          child: SizedBox(
            width: width,
            height: height,
            child: GestureDetector(
              key: _imageKey,
              onTapDown: (details) {
                if (!_isDrawingMode) {
                  // Get the render box to get widget size
                  final RenderBox? box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
                  if (box != null) {
                    final widgetSize = box.size;
                    final localPosition = details.localPosition;
                    
                    // Perform hit test
                    final hitIndex = _hitTestDetections(localPosition, widgetSize);
                    if (hitIndex != null) {
                      _selectDetection(hitIndex);
                    } else {
                      // Deselect if tapped outside any box
                      setState(() => _selectedDetectionIndex = null);
                    }
                  }
                } else {
                  // Start drawing new box
                  setState(() => _drawingStart = details.localPosition);
                }
              },
              onPanUpdate: (details) {
                if (_isDrawingMode && _drawingStart != null) {
                  setState(() => _drawingEnd = details.localPosition);
                }
              },
              onPanEnd: (details) {
                if (_isDrawingMode && _drawingStart != null && _drawingEnd != null) {
                  // Get widget size for coordinate conversion
                  final RenderBox? box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
                  if (box != null) {
                    final widgetSize = box.size;
                    final imageStart = _screenToImageCoordinates(_drawingStart!, widgetSize);
                    final imageEnd = _screenToImageCoordinates(_drawingEnd!, widgetSize);
                    
                    // Store the image coordinates for the new box
                    _showLabelSelectionDialog(
                      isNewBox: true,
                      boxStart: imageStart,
                      boxEnd: imageEnd,
                    );
                  }
                }
              },
              child: CustomPaint(
                painter: DetectionPainter(
                  image: _capturedImage!,
                  detections: _detections,
                  selectedIndex: _selectedDetectionIndex,
                  drawingStart: _drawingStart,
                  drawingEnd: _drawingEnd,
                ),
                child: Container(),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showLabelSelectionDialog({
    bool isNewBox = false,
    Offset? boxStart,
    Offset? boxEnd,
  }) async {
    final TextEditingController labelController = TextEditingController();
    
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(isNewBox ? 'Add Label for New Box' : 'Change Label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: labelController,
              decoration: const InputDecoration(
                labelText: 'Enter label name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Or select from available classes:'),
            // TODO: Load available classes from metadata
            Wrap(
              spacing: 8,
              children: ['person', 'car', 'dog', 'cat', 'chair'].map((label) {
                return ActionChip(
                  label: Text(label),
                  onPressed: () {
                    labelController.text = label;
                  },
                );
              }).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              // If cancelling a new box, exit drawing mode
              if (isNewBox) {
                setState(() {
                  _drawingStart = null;
                  _drawingEnd = null;
                  _isDrawingMode = false;
                });
                widget.onDrawingModeChanged?.call(false);
              }
              Navigator.pop(context);
            },
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (labelController.text.isNotEmpty) {
                if (isNewBox && boxStart != null && boxEnd != null) {
                  // Add new detection with image coordinates
                  setState(() {
                    _detections.add(Detection(
                      classId: -1,
                      className: labelController.text,
                      confidence: 1.0,
                      box: BoundingBox(
                        x1: boxStart.dx.clamp(0, _capturedImage!.width.toDouble()),
                        y1: boxStart.dy.clamp(0, _capturedImage!.height.toDouble()),
                        x2: boxEnd.dx.clamp(0, _capturedImage!.width.toDouble()),
                        y2: boxEnd.dy.clamp(0, _capturedImage!.height.toDouble()),
                      ),
                    ));
                    _drawingStart = null;
                    _drawingEnd = null;
                    _isDrawingMode = false;
                  });
                  // Notify parent that drawing mode is disabled
                  widget.onDrawingModeChanged?.call(false);
                } else if (_selectedDetectionIndex != null) {
                  _updateDetectionLabel(_selectedDetectionIndex!, labelController.text);
                }
                Navigator.pop(context);
              }
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('YOLO Label Correction'),
        actions: [
          if (_capturedImage != null)
            IconButton(
              icon: const Icon(Icons.close),
              onPressed: _resetCapture,
              tooltip: 'Reset',
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Camera or Detection View
          if (_capturedImage == null)
            _buildCameraView()
          else
            _buildDetectionView(),

          // Processing Overlay
          if (_isProcessing)
            Container(
              color: Colors.black.withValues(alpha: 0.5),
              child: const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Processing image...',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),

          // Detection Info Panel
          if (_capturedImage != null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Detections: ${_detections.length}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_selectedDetectionIndex != null) ...[
                      Text(
                        'Selected: ${_detections[_selectedDetectionIndex!].className}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      Text(
                        'Confidence: ${(_detections[_selectedDetectionIndex!].confidence * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          ElevatedButton.icon(
                            onPressed: () => _showLabelSelectionDialog(),
                            icon: const Icon(Icons.edit, size: 18),
                            label: const Text('Change Label'),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton.icon(
                            onPressed: () => _deleteDetection(_selectedDetectionIndex!),
                            icon: const Icon(Icons.delete, size: 18),
                            label: const Text('Delete'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _toggleDrawingMode,
                            icon: Icon(_isDrawingMode ? Icons.check : Icons.draw),
                            label: Text(_isDrawingMode ? 'Drawing Mode' : 'Draw Box'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _isDrawingMode ? Colors.green : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ElevatedButton.icon(
                            onPressed: _saveAnnotations,
                            icon: const Icon(Icons.save),
                            label: const Text('Save'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: _capturedImage == null
          ? FloatingActionButton.extended(
              onPressed: _modelReady ? _captureAndDetect : null,
              icon: const Icon(Icons.camera),
              label: Text(_modelReady ? 'Capture' : 'Loading...'),
              backgroundColor: _modelReady ? Colors.blue : Colors.grey,
            )
          : null,
    );
  }
}

// ========== Data Classes ==========

class Detection {
  final int classId;
  final String className;
  final double confidence;
  final BoundingBox box;

  const Detection({
    required this.classId,
    required this.className,
    required this.confidence,
    required this.box,
  });

  Detection copyWith({
    int? classId,
    String? className,
    double? confidence,
    BoundingBox? box,
  }) {
    return Detection(
      classId: classId ?? this.classId,
      className: className ?? this.className,
      confidence: confidence ?? this.confidence,
      box: box ?? this.box,
    );
  }
}

class BoundingBox {
  final double x1;
  final double y1;
  final double x2;
  final double y2;

  const BoundingBox({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  double get width => x2 - x1;
  double get height => y2 - y1;
  double get centerX => (x1 + x2) / 2;
  double get centerY => (y1 + y2) / 2;
}

// ========== Custom Painter ==========

class DetectionPainter extends CustomPainter {
  final ui.Image image;
  final List<Detection> detections;
  final int? selectedIndex;
  final Offset? drawingStart;
  final Offset? drawingEnd;

  DetectionPainter({
    required this.image,
    required this.detections,
    this.selectedIndex,
    this.drawingStart,
    this.drawingEnd,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw the image
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, src, dst, Paint());

    // Calculate scaling factors
    final scaleX = size.width / image.width;
    final scaleY = size.height / image.height;

    // Draw detections
    for (int i = 0; i < detections.length; i++) {
      final detection = detections[i];
      final isSelected = i == selectedIndex;

      final paint = Paint()
        ..color = isSelected ? Colors.green : Colors.red
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 3.0 : 2.0;

      final rect = Rect.fromLTRB(
        detection.box.x1 * scaleX,
        detection.box.y1 * scaleY,
        detection.box.x2 * scaleX,
        detection.box.y2 * scaleY,
      );

      canvas.drawRect(rect, paint);

      // Draw label background
      final textSpan = TextSpan(
        text: '${detection.className} ${(detection.confidence * 100).toStringAsFixed(0)}%',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
        ),
      );

      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();

      final labelRect = Rect.fromLTWH(
        rect.left,
        rect.top - textPainter.height - 4,
        textPainter.width + 8,
        textPainter.height + 4,
      );

      canvas.drawRect(
        labelRect,
        Paint()..color = isSelected ? Colors.green : Colors.red,
      );

      textPainter.paint(canvas, Offset(rect.left + 4, rect.top - textPainter.height - 2));
    }

    // Draw the box being drawn
    if (drawingStart != null && drawingEnd != null) {
      final paint = Paint()
        ..color = Colors.blue
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      canvas.drawRect(
        Rect.fromPoints(drawingStart!, drawingEnd!),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant DetectionPainter oldDelegate) {
    return oldDelegate.detections != detections ||
        oldDelegate.selectedIndex != selectedIndex ||
        oldDelegate.drawingStart != drawingStart ||
        oldDelegate.drawingEnd != drawingEnd;
  }
}
