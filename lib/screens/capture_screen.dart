// FILE: lib/screens/capture_screen.dart
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

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
  ui.Image? _capturedImage; // This will be the 640x640 image used for YOLO
  List<Detection> _detections = [];
  int? _selectedDetectionIndex;
  bool _isDrawingMode = false;
  
  // Drawing State
  Offset? _drawingStart;
  Offset? _drawingEnd;
  
  // Display configuration - 320x320 display (half of 640x640 input)
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
      // Capture image from camera
      final XFile imageFile = await _cameraController!.takePicture();
      final Uint8List rawImageBytes = await imageFile.readAsBytes();

      // Preprocess: center crop to 640x640 to match YOLO input
      final Uint8List processedBytes = _preprocessImageTo640x640(rawImageBytes);

      // Decode the 640x640 image for display
      final ui.Image image = await decodeImageFromList(processedBytes);

      // Verify it's 640x640
      debugPrint('Processed image size: ${image.width}x${image.height}');

      // Run YOLO detection on the 640x640 image
      final detections = await _yoloService.detectObjects(processedBytes);

      // Convert to Detection objects
      // Note: YOLO returns coordinates in the 640x640 space
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

  /// Preprocess camera image to 640x640 by center cropping
  /// This ensures YOLO receives exactly 640x640 input
  Uint8List _preprocessImageTo640x640(Uint8List imageBytes) {
    try {
      // Decode the image
      final img.Image? srcImage = img.decodeImage(imageBytes);
      if (srcImage == null) {
        throw Exception('Failed to decode image');
      }

      final int srcWidth = srcImage.width;
      final int srcHeight = srcImage.height;

      debugPrint('Original camera image: ${srcWidth}x$srcHeight');

      // Calculate center crop to get a square
      final int cropSize = srcWidth < srcHeight ? srcWidth : srcHeight;
      final int offsetX = (srcWidth - cropSize) ~/ 2;
      final int offsetY = (srcHeight - cropSize) ~/ 2;

      // Crop to square
      final img.Image cropped = img.copyCrop(
        srcImage,
        x: offsetX,
        y: offsetY,
        width: cropSize,
        height: cropSize,
      );

      // Resize to exactly 640x640
      final img.Image resized = img.copyResize(
        cropped,
        width: 640,
        height: 640,
        interpolation: img.Interpolation.linear,
      );

      // Encode back to bytes
      final List<int> encoded = img.encodeJpg(resized, quality: 95);
      debugPrint('Preprocessed to 640x640');

      return Uint8List.fromList(encoded);
    } catch (e) {
      debugPrint('Image preprocessing failed: $e, using original');
      return imageBytes;
    }
  }

  void _selectDetectionByIndex(int index) {
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

  Widget _buildDetectionList() {
    if (_detections.isEmpty) {
      return const SizedBox(
        height: 80,
        child: Center(
          child: Text(
            'No detections yet',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ),
      );
    }

    return SizedBox(
      height: 120,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: _detections.length,
        itemBuilder: (context, index) {
          final detection = _detections[index];
          final isSelected = index == _selectedDetectionIndex;

          return GestureDetector(
            onTap: () => _selectDetectionByIndex(index),
            child: Container(
              width: 140,
              margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? Colors.green.withValues(alpha: 0.3) : Colors.black.withValues(alpha: 0.5),
                border: Border.all(
                  color: isSelected ? Colors.green : Colors.white24,
                  width: isSelected ? 2.5 : 1,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Class icon
                  Icon(
                    Icons.category,
                    color: isSelected ? Colors.green : Colors.white70,
                    size: 28,
                  ),
                  const SizedBox(height: 4),
                  // Class name
                  Text(
                    detection.className,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.white70,
                      fontSize: 14,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  // Confidence
                  Text(
                    '${(detection.confidence * 100).toStringAsFixed(0)}%',
                    style: TextStyle(
                      color: isSelected ? Colors.greenAccent : Colors.white54,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
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

    // The captured image is guaranteed to be 640x640
    // Display it at 320x320 (exact half scale)
    // Bounding boxes are in 640x640 space and will be scaled by 0.5
    return Center(
      child: SizedBox(
        width: displayWidth,
        height: displayHeight,
        child: GestureDetector(
          key: _imageKey,
          onTapDown: (details) {
            if (_isDrawingMode) {
              // Start drawing new box in drawing mode
              setState(() => _drawingStart = details.localPosition);
            } else {
              // Check if tapping on a detection to select it
              final tapPos = details.localPosition;
              int? tappedIndex;
              
              // Scale tap coordinates to 640x640 space
              final scaledTapX = tapPos.dx * 2.0; // 320 -> 640
              final scaledTapY = tapPos.dy * 2.0;
              
              for (int i = 0; i < _detections.length; i++) {
                final box = _detections[i].box;
                if (scaledTapX >= box.x1 && scaledTapX <= box.x2 &&
                    scaledTapY >= box.y1 && scaledTapY <= box.y2) {
                  tappedIndex = i;
                  break;
                }
              }
              
              setState(() => _selectedDetectionIndex = tappedIndex);
            }
          },
          onPanUpdate: (details) {
            if (_isDrawingMode && _drawingStart != null) {
              setState(() => _drawingEnd = details.localPosition);
            }
          },
          onPanEnd: (details) {
            if (_isDrawingMode && _drawingStart != null && _drawingEnd != null) {
              // Convert display coordinates (320x320) to image coordinates (640x640)
              final imageStart = Offset(
                _drawingStart!.dx * 2.0,
                _drawingStart!.dy * 2.0,
              );
              final imageEnd = Offset(
                _drawingEnd!.dx * 2.0,
                _drawingEnd!.dy * 2.0,
              );
              
              // Store the image coordinates for the new box
              _showLabelSelectionDialog(
                isNewBox: true,
                boxStart: imageStart,
                boxEnd: imageEnd,
              );
            }
          },
          child: CustomPaint(
            painter: DetectionPainter(
              image: _capturedImage!,
              detections: _detections,
              selectedIndex: _selectedDetectionIndex,
              drawingStart: _drawingStart,
              drawingEnd: _drawingEnd,
              displaySize: const Size(displayWidth, displayHeight),
            ),
            child: Container(),
          ),
        ),
      ),
    );
  }

  Future<void> _showLabelSelectionDialog({
    bool isNewBox = false,
    Offset? boxStart,
    Offset? boxEnd,
  }) async {
    await showDialog(
      context: context,
      builder: (context) => _LabelSelectionDialog(
        isNewBox: isNewBox,
        availableLabels: _yoloService.getClassNamesList(),
        onConfirm: (selectedLabel) {
          if (selectedLabel.isNotEmpty) {
            if (isNewBox && boxStart != null && boxEnd != null) {
              // Add new detection with image coordinates
              setState(() {
                _detections.add(Detection(
                  classId: -1,
                  className: selectedLabel,
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
              widget.onDrawingModeChanged?.call(false);
            } else if (_selectedDetectionIndex != null) {
              _updateDetectionLabel(_selectedDetectionIndex!, selectedLabel);
            }
          }
          Navigator.pop(context);
        },
        onCancel: () {
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
                  color: Colors.black.withValues(alpha: 0.9),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Detections: ${_detections.length}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (_selectedDetectionIndex != null)
                          Text(
                            'Selected: ${_selectedDetectionIndex! + 1}',
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Detection list
                    _buildDetectionList(),
                    const SizedBox(height: 12),
                    // Action buttons for selected detection
                    if (_selectedDetectionIndex != null) ...[
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _showLabelSelectionDialog(),
                              icon: const Icon(Icons.edit, size: 18),
                              label: const Text('Change Label'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.blue,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () => _deleteDetection(_selectedDetectionIndex!),
                              icon: const Icon(Icons.delete, size: 18),
                              label: const Text('Delete'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.red,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                    // Draw and Save buttons
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
                              backgroundColor: Colors.orange,
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
  final Size displaySize;

  DetectionPainter({
    required this.image,
    required this.detections,
    required this.displaySize,
    this.selectedIndex,
    this.drawingStart,
    this.drawingEnd,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw the image scaled to fit the display size
    // Image is 640x640, display is 320x320 (scale = 0.5)
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, displaySize.width, displaySize.height);
    canvas.drawImageRect(image, src, dst, Paint());

    // Calculate scaling factors from image space (640x640) to display space (320x320)
    // This should be exactly 0.5 for both dimensions
    final scaleX = displaySize.width / image.width;
    final scaleY = displaySize.height / image.height;

    // Draw detections (coordinates are in 640x640 space, scale to 320x320)
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

// ========== Label Selection Dialog ==========

class _LabelSelectionDialog extends StatefulWidget {
  final bool isNewBox;
  final List<String> availableLabels;
  final Function(String) onConfirm;
  final VoidCallback onCancel;

  const _LabelSelectionDialog({
    required this.isNewBox,
    required this.availableLabels,
    required this.onConfirm,
    required this.onCancel,
  });

  @override
  State<_LabelSelectionDialog> createState() => _LabelSelectionDialogState();
}

class _LabelSelectionDialogState extends State<_LabelSelectionDialog> {
  late TextEditingController _searchController;
  late TextEditingController _customLabelController;
  List<String> _filteredLabels = [];
  bool _showCustomInput = false;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _customLabelController = TextEditingController();
    _filteredLabels = widget.availableLabels;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _customLabelController.dispose();
    super.dispose();
  }

  void _updateSearch(String query) {
    setState(() {
      if (query.isEmpty) {
        _filteredLabels = widget.availableLabels;
      } else {
        final lowerQuery = query.toLowerCase();
        _filteredLabels = widget.availableLabels
            .where((label) => label.toLowerCase().contains(lowerQuery))
            .toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isNewBox ? 'Add Label for New Box' : 'Change Label'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search field
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                labelText: 'Search labels',
                prefixIcon: const Icon(Icons.search),
                border: const OutlineInputBorder(),
                suffixIcon: _searchController.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchController.clear();
                          _updateSearch('');
                        },
                      )
                    : null,
              ),
              onChanged: _updateSearch,
            ),
            const SizedBox(height: 12),
            
            // Filtered labels list
            if (_filteredLabels.isNotEmpty)
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _filteredLabels.length,
                  itemBuilder: (context, index) {
                    final label = _filteredLabels[index];
                    return ListTile(
                      title: Text(label),
                      trailing: const Icon(Icons.check_circle_outline),
                      onTap: () {
                        widget.onConfirm(label);
                      },
                    );
                  },
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  _searchController.text.isEmpty
                      ? 'No labels available'
                      : 'No labels match "${_searchController.text}"',
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
              ),
            
            const SizedBox(height: 12),
            
            // Custom label input
            if (_showCustomInput)
              Column(
                children: [
                  TextField(
                    controller: _customLabelController,
                    decoration: InputDecoration(
                      labelText: 'Enter new label',
                      border: const OutlineInputBorder(),
                      suffixIcon: _customLabelController.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.check),
                              onPressed: () {
                                if (_customLabelController.text.isNotEmpty) {
                                  widget.onConfirm(_customLabelController.text);
                                }
                              },
                            )
                          : null,
                    ),
                    onChanged: (value) {
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            
            // Toggle custom input button
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _showCustomInput = !_showCustomInput;
                  if (!_showCustomInput) {
                    _customLabelController.clear();
                  }
                });
              },
              icon: Icon(_showCustomInput ? Icons.close : Icons.add),
              label: Text(_showCustomInput ? 'Cancel Custom' : 'Add New Label'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: widget.onCancel,
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}