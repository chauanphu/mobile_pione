---
applyTo: '**'
---
I am implementing a Detection using YOLOE model on Android. I have made some recent edits to the files `YoloOnnxHandler.kt` and `MainActivity.kt`. The exported YOLOE model is in ONNX format and I am using ONNX Runtime for inference.

**Input:**
- The image is preprocessed to a fixed size of 640x640 pixels.
- The image is normalized by dividing pixel values by 255.0.
- The model expects input in the shape [1, 3, 640, 640] (batch size, channels, height, width).

**Output:**
- The model outputs a tensor of shape is ((1,300, 38), (1, 32, 160, 160)): 
  - The first tensor contains detection boxes with attributes (x_center, y_center, width, height, confidence, class_id).
  - The second tensor contains feature maps used for masking.
- The model should already include Non-Maximum Suppression (NMS) to filter overlapping boxes.

# Labelling correction
1. First the user captures an image using the device camera.
2. The captured image is then run through the YOLOE model to obtain detection results.
3. The detection results are parsed to extract bounding boxes, confidence scores, and class IDs.
4. Next, the user will either:
  - Manually correct the labels by selecting bounding boxes and assigning correct class labels from a predefined list.
  - And/Or confirm the automatically detected labels if they are accurate.
  - And/Or select the draw the bounding boxes manually on the image. Then choose the correct class labels for each box (using the metadata). If no label is found, the user can create a new label.
5. Finally, the corrected labels and bounding boxes are saved back to the dataset for future training and evaluation.