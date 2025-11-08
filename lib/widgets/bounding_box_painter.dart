import 'package:flutter/material.dart';

class BoundingBoxPainter extends CustomPainter {
  BoundingBoxPainter({
    required this.detections,
    required this.imageSize,
  });

  final List<Map<String, dynamic>> detections;
  final Size imageSize;

  @override
  void paint(Canvas canvas, Size size) {
    if (detections.isEmpty || imageSize.width <= 0 || imageSize.height <= 0) {
      return;
    }

    final Paint boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final TextPainter textPainter = TextPainter(
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.left,
    );

    final double scaleX = size.width / imageSize.width;
    final double scaleY = size.height / imageSize.height;

    for (final detection in detections) {
      final box = detection['box'] as Map<String, dynamic>?;
      if (box == null) continue;

      final double left = (box['x1'] as num?)?.toDouble() ?? 0.0;
      final double top = (box['y1'] as num?)?.toDouble() ?? 0.0;
      final double right = (box['x2'] as num?)?.toDouble() ?? left;
      final double bottom = (box['y2'] as num?)?.toDouble() ?? top;

      final Rect rect = Rect.fromLTRB(
        left * scaleX,
        top * scaleY,
        right * scaleX,
        bottom * scaleY,
      );

      final double confidence = (detection['confidence'] as num?)?.toDouble() ?? 0.0;
      boxPaint.color = _colorForConfidence(confidence);
      canvas.drawRect(rect, boxPaint);

      final String label = detection['className'] as String? ?? 'unknown';
      final int confidencePercent = (confidence * 100).round();
      final String labelText = '$label $confidencePercent%';

      textPainter.text = TextSpan(
        text: labelText,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          fontWeight: FontWeight.bold,
          backgroundColor: Colors.black87,
        ),
      );
      textPainter.layout();

      final double labelX = rect.left;
      final double labelY = (rect.top - textPainter.height - 2)
          .clamp(0.0, size.height - textPainter.height);

      textPainter.paint(canvas, Offset(labelX, labelY));
    }
  }

  Color _colorForConfidence(double confidence) {
    if (confidence >= 0.8) return Colors.green;
    if (confidence >= 0.6) return Colors.yellow;
    if (confidence >= 0.4) return Colors.orange;
    return Colors.red;
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) {
    return detections != oldDelegate.detections || imageSize != oldDelegate.imageSize;
  }
}
