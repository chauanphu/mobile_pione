package com.example.mobile_pione

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.Log
import io.flutter.FlutterInjector
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min
import org.json.JSONObject
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession

/**
 * Standard YOLO ONNX Handler for object detection using ONNX Runtime
 * 
 * Model Input:
 * - Shape: [1, 3, 640, 640] (batch, channels, height, width)
 * - Format: RGB, normalized [0, 1]
 * - Preprocessing: Letterbox with padding
 * 
 * Model Output:
 * - Shape: [1, NUM_OUTPUT_FEATURES, NUM_DETECTIONS]
 * - Format: [x_center, y_center, width, height, class_scores...]
 * - Requires transposition and NMS post-processing
 */
class YoloOnnxHandler(private val context: Context) {
    private val loggerTag = "YoloOnnxHandler"
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null
    private val initialized = AtomicBoolean(false)
    
    // Model configuration
    private var inputWidth: Int = 640
    private var inputHeight: Int = 640
    private var classNames: Map<Int, String> = emptyMap()
    private var numClasses: Int = 80
    private var numDetections: Int = 8400
    private val maxResults = 10
    
    // Standard YOLO format constants
    private companion object {
        const val CONFIDENCE_THRESHOLD_DEFAULT = 0.25f
        const val IOU_THRESHOLD_DEFAULT = 0.45f
    }

    @Synchronized
    fun initialize(assetPath: String, metadataPath: String?, width: Int, height: Int) {
        if (initialized.get()) {
            Log.i(loggerTag, "YOLO model already initialized")
            return
        }

        val modelFile = AssetLoader(context).loadModelFromAssets(assetPath)
        val metadata = metadataPath?.let { AssetLoader(context).loadMetadata(it) }
        
        val sessionOptions = createSessionOptions()

        try {
            session = env.createSession(modelFile.absolutePath, sessionOptions)
            inputWidth = width
            inputHeight = height
            
            // Load metadata
            metadata?.let {
                classNames = it.classNames
                numClasses = it.numClasses
            } ?: run {
                Log.w(loggerTag, "No metadata provided, using defaults")
            }
            
            initialized.set(true)
            Log.i(loggerTag, "YOLO ONNX session initialized successfully")
            Log.d(loggerTag, "Input size: ${inputWidth}x${inputHeight}, Classes: ${numClasses}, Detections: ${numDetections}")
        } finally {
            sessionOptions.close()
        }
    }

    private fun createSessionOptions(): OrtSession.SessionOptions {
        return OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            setIntraOpNumThreads(Runtime.getRuntime().availableProcessors())
            setInterOpNumThreads(Runtime.getRuntime().availableProcessors())
        }
    }

    @Synchronized
    fun detectObjects(
        imageBytes: ByteArray?,
        confidenceThreshold: Float,
        iouThreshold: Float,
        shouldApplyNms: Boolean = true,
    ): List<Map<String, Any>> {
        requireInitialized()
        require(imageBytes != null && imageBytes.isNotEmpty()) { "Image bytes are empty" }

        val bitmap = decodeBitmap(imageBytes)
        
        return try {
            val preprocessResult = preprocessImage(bitmap)
            val detections = runInference(
                preprocessResult, 
                bitmap.width, 
                bitmap.height,
                confidenceThreshold,
                iouThreshold
            )
            
            val finalDetections = detections
                .sortedByDescending { it.confidence }
                .take(maxResults)
            
            DetectionMapper.toMapList(finalDetections, bitmap.width, bitmap.height)
        } finally {
            bitmap.recycle()
        }
    }

    private fun requireInitialized() {
        if (!initialized.get() || session == null) {
            throw IllegalStateException("YOLO model not initialized. Call initialize() first.")
        }
    }

    private fun decodeBitmap(imageBytes: ByteArray): Bitmap {
        val options = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }
        return BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, options)
            ?: throw IllegalArgumentException("Failed to decode image bytes")
    }

    private fun preprocessImage(bitmap: Bitmap): PreprocessResult {
        val originalWidth = bitmap.width
        val originalHeight = bitmap.height

        // Calculate letterbox scaling
        val ratio = inputWidth.toFloat() / max(originalWidth, originalHeight)
        val newWidth = (originalWidth * ratio).toInt()
        val newHeight = (originalHeight * ratio).toInt()

        val resizedBitmap = Bitmap.createScaledBitmap(bitmap, newWidth, newHeight, true)

        // Create padded bitmap with gray background
        val paddedBitmap = Bitmap.createBitmap(inputWidth, inputHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(paddedBitmap)
        val paint = Paint().apply { color = Color.rgb(128, 128, 128) }
        canvas.drawRect(0f, 0f, inputWidth.toFloat(), inputHeight.toFloat(), paint)
        
        val padX = (inputWidth - newWidth) / 2f
        val padY = (inputHeight - newHeight) / 2f
        canvas.drawBitmap(resizedBitmap, padX, padY, null)

        // Convert to CHW format (Channel-First) and normalize
        val inputBuffer = FloatBuffer.allocate(3 * inputWidth * inputHeight)
        val pixels = IntArray(inputWidth * inputHeight)
        paddedBitmap.getPixels(pixels, 0, inputWidth, 0, 0, inputWidth, inputHeight)
        
        for (c in 0..2) {
            for (y in 0 until inputHeight) {
                for (x in 0 until inputWidth) {
                    val pixel = pixels[y * inputWidth + x]
                    val value = when (c) {
                        0 -> ((pixel shr 16) and 0xFF) / 255.0f  // Red
                        1 -> ((pixel shr 8) and 0xFF) / 255.0f   // Green
                        else -> (pixel and 0xFF) / 255.0f        // Blue
                    }
                    inputBuffer.put(value)
                }
            }
        }
        inputBuffer.rewind()

        if (resizedBitmap != bitmap) {
            resizedBitmap.recycle()
        }
        paddedBitmap.recycle()

        return PreprocessResult(inputBuffer, ratio, padX, padY)
    }

    private fun runInference(
        preprocessResult: PreprocessResult,
        originalWidth: Int,
        originalHeight: Int,
        confidenceThreshold: Float,
        iouThreshold: Float
    ): List<Detection> {
        var inputTensor: OnnxTensor? = null
        var result: OrtSession.Result? = null

        try {
            inputTensor = OnnxTensor.createTensor(
                env,
                preprocessResult.inputBuffer,
                longArrayOf(1, 3, inputHeight.toLong(), inputWidth.toLong())
            )

            val inputName = session!!.inputInfo.keys.first()
            val inputs = mapOf(inputName to inputTensor)
            result = session!!.run(inputs)

            // Standard YOLO output: [1, NUM_OUTPUT_FEATURES, NUM_DETECTIONS]
            val rawOutput = result[0]?.value as? Array<Array<FloatArray>>
                ?: throw IllegalStateException("Invalid output format from model")

            Log.d(loggerTag, "Model output received successfully")
            
            return postProcessDetection(
                rawOutput,
                originalWidth,
                originalHeight,
                preprocessResult.scaleFactor,
                preprocessResult.padX,
                preprocessResult.padY,
                confidenceThreshold,
                iouThreshold
            )
        } catch (e: Exception) {
            Log.e(loggerTag, "Inference failed", e)
            throw IllegalStateException("YOLO inference failed: ${e.message}", e)
        } finally {
            result?.close()
            inputTensor?.close()
        }
    }

    private fun postProcessDetection(
        rawOutput: Array<Array<FloatArray>>,
        originalWidth: Int,
        originalHeight: Int,
        scaleFactor: Float,
        padX: Float,
        padY: Float,
        confidenceThreshold: Float,
        iouThreshold: Float
    ): List<Detection> {
        try {
            val outputData = rawOutput[0]
            
            // Get dimensions - [NUM_OUTPUT_FEATURES, NUM_DETECTIONS]
            val numOutputFeatures = outputData.size
            numDetections = outputData[0].size
            
            Log.d(loggerTag, "Processing output: [$numOutputFeatures, $numDetections]")

            val boxes = ArrayList<RectF>()
            val confidences = ArrayList<Float>()
            val classIds = ArrayList<Int>()

            // Parse detections directly without full transposition to save memory
            // Access pattern: outputData[feature_index][detection_index]
            for (i in 0 until numDetections) {
                // Extract coordinates directly from transposed format
                val xCenter = outputData[0][i]
                val yCenter = outputData[1][i]
                val boxWidth = outputData[2][i]
                val boxHeight = outputData[3][i]
                
                // Find max class score across all classes
                var maxScore = 0.0f
                var classId = -1
                for (j in 0 until numClasses) {
                    val score = outputData[4 + j][i]
                    if (score > maxScore) {
                        maxScore = score
                        classId = j
                    }
                }
                
                // Only process detections above threshold
                if (maxScore > confidenceThreshold) {
                    // Convert from model space to original image space
                    var x1 = (xCenter - boxWidth / 2f - padX) / scaleFactor
                    var y1 = (yCenter - boxHeight / 2f - padY) / scaleFactor
                    var x2 = (xCenter + boxWidth / 2f - padX) / scaleFactor
                    var y2 = (yCenter + boxHeight / 2f - padY) / scaleFactor
                    
                    // Clamp to image boundaries
                    x1 = x1.coerceIn(0f, originalWidth.toFloat())
                    y1 = y1.coerceIn(0f, originalHeight.toFloat())
                    x2 = x2.coerceIn(0f, originalWidth.toFloat())
                    y2 = y2.coerceIn(0f, originalHeight.toFloat())
                    
                    // Only add valid boxes
                    if (x2 > x1 && y2 > y1) {
                        boxes.add(RectF(x1, y1, x2, y2))
                        confidences.add(maxScore)
                        classIds.add(classId)
                    }
                }
            }

            Log.d(loggerTag, "Found ${boxes.size} detections above threshold $confidenceThreshold")

            // Apply NMS
            val nmsIndices = performNMS(boxes, confidences, classIds, iouThreshold)
            val finalResults = ArrayList<Detection>()
            
            for (idx in nmsIndices) {
                val className = classNames[classIds[idx]] ?: "Class ${classIds[idx]}"
                finalResults.add(
                    Detection(
                        classIds[idx],
                        className,
                        confidences[idx],
                        BoundingBox(
                            boxes[idx].left,
                            boxes[idx].top,
                            boxes[idx].right,
                            boxes[idx].bottom
                        )
                    )
                )
            }

            Log.d(loggerTag, "After NMS: ${finalResults.size} detections")
            return finalResults
        } catch (e: Exception) {
            Log.e(loggerTag, "Error in detection postprocessing", e)
            return emptyList()
        }
    }

    private fun performNMS(
        boxes: List<RectF>,
        confidences: List<Float>,
        classIds: List<Int>,
        iouThreshold: Float
    ): List<Int> {
        val finalIndices = mutableListOf<Int>()
        val uniqueClasses = classIds.distinct()
        
        for (classId in uniqueClasses) {
            val classIndices = classIds.mapIndexedNotNull { index, id -> 
                if (id == classId) index else null 
            }
            
            if (classIndices.isEmpty()) continue
            
            val sortedIndices = classIndices.sortedByDescending { confidences[it] }
            val suppressed = BooleanArray(boxes.size)
            
            for (i in sortedIndices) {
                if (suppressed[i]) continue
                finalIndices.add(i)
                
                for (j in sortedIndices) {
                    if (i == j || suppressed[j]) continue
                    val iou = calculateIoU(boxes[i], boxes[j])
                    if (iou > iouThreshold) {
                        suppressed[j] = true
                    }
                }
            }
        }
        
        return finalIndices
    }

    private fun calculateIoU(box1: RectF, box2: RectF): Float {
        val x1 = max(box1.left, box2.left)
        val y1 = max(box1.top, box2.top)
        val x2 = min(box1.right, box2.right)
        val y2 = min(box1.bottom, box2.bottom)
        
        val inter = if (x2 > x1 && y2 > y1) (x2 - x1) * (y2 - y1) else 0f
        val union = box1.width() * box1.height() + box2.width() * box2.height() - inter
        
        return if (union > 0) inter / union else 0f
    }

    fun close() {
        initialized.set(false)
        try {
            session?.close()
        } catch (e: Exception) {
            Log.w(loggerTag, "Error closing ONNX session", e)
        } finally {
            session = null
            classNames = emptyMap()
            Log.i(loggerTag, "YOLO ONNX session closed")
        }
    }

    // ========== Helper Classes (Single Responsibility Principle) ==========

    /**
     * Metadata structure from JSON
     */
    private data class ModelMetadata(
        val classNames: Map<Int, String>,
        val numClasses: Int
    )

    /**
     * Handles loading assets from Flutter asset bundle
     */
    private class AssetLoader(private val context: Context) {
        private val loggerTag = "AssetLoader"

        fun loadModelFromAssets(assetPath: String): File {
            val flutterLoader = FlutterInjector.instance().flutterLoader()
            val assetKey = flutterLoader.getLookupKeyForAsset(assetPath)
            val modelsDir = File(context.filesDir, "onnx_models")
            
            if (!modelsDir.exists()) {
                modelsDir.mkdirs()
            }

            val targetFile = File(modelsDir, File(assetPath).name)
            
            // Check if cached file exists and verify asset still exists
            if (targetFile.exists() && targetFile.length() > 0) {
                try {
                    context.assets.open(assetKey).use { 
                        Log.d(loggerTag, "Using cached model: ${targetFile.absolutePath}")
                        return targetFile
                    }
                } catch (e: IOException) {
                    Log.w(loggerTag, "Asset no longer exists, clearing cache")
                    targetFile.delete()
                }
            }

            // Copy from assets to cache
            try {
                context.assets.open(assetKey).use { input ->
                    FileOutputStream(targetFile).use { output ->
                        input.copyTo(output)
                    }
                }
                Log.i(loggerTag, "Model copied from assets: ${targetFile.absolutePath}")
                return targetFile
            } catch (e: IOException) {
                targetFile.delete()
                throw IOException("Failed to copy ONNX model from assets: $assetPath", e)
            }
        }

        fun loadMetadata(metadataAssetPath: String): ModelMetadata? {
            val flutterLoader = FlutterInjector.instance().flutterLoader()
            val assetKey = flutterLoader.getLookupKeyForAsset(metadataAssetPath)

            return try {
                context.assets.open(assetKey).use { inputStream ->
                    val jsonText = inputStream.bufferedReader().use { it.readText() }
                    val json = JSONObject(jsonText)
                    val namesJson = json.optJSONObject("names") ?: return null
                    
                    val classNames = buildMap {
                        val keys = namesJson.keys()
                        while (keys.hasNext()) {
                            val key = keys.next()
                            val classId = key.toIntOrNull()
                            if (classId != null) {
                                put(classId, namesJson.optString(key))
                            }
                        }
                    }
                    
                    val numClasses = classNames.size
                    Log.i(loggerTag, "Loaded metadata: $numClasses classes")
                    
                    ModelMetadata(classNames, numClasses)
                }
            } catch (e: IOException) {
                Log.w(loggerTag, "Failed to load metadata: $metadataAssetPath", e)
                null
            }
        }
    }

    /**
     * Result from image preprocessing
     */
    private data class PreprocessResult(
        val inputBuffer: FloatBuffer,
        val scaleFactor: Float,
        val padX: Float,
        val padY: Float
    )

    /**
     * Maps Detection objects to Flutter-compatible Map format
     */
    private object DetectionMapper {
        fun toMapList(
            detections: List<Detection>,
            imageWidth: Int,
            imageHeight: Int
        ): List<Map<String, Any>> {
            return detections.map { detection ->
                mapOf(
                    "classId" to detection.classId,
                    "className" to detection.className,
                    "confidence" to detection.confidence.toDouble(),
                    "box" to detection.box.toMap(),
                    "bbox" to detection.box.toMap(),
                    "imageWidth" to imageWidth,
                    "imageHeight" to imageHeight
                )
            }
        }
    }

    // ========== Data Classes ==========

    /**
     * Represents a single object detection
     */
    private data class Detection(
        val classId: Int,
        val className: String,
        val confidence: Float,
        val box: BoundingBox
    )

    /**
     * Represents a bounding box in image coordinates
     */
    private data class BoundingBox(
        val x1: Float,
        val y1: Float,
        val x2: Float,
        val y2: Float
    ) {
        fun width(): Float = (x2 - x1).coerceAtLeast(0f)
        fun height(): Float = (y2 - y1).coerceAtLeast(0f)
        fun area(): Float = width() * height()

        fun toMap(): Map<String, Double> = mapOf(
            "x1" to x1.toDouble(),
            "y1" to y1.toDouble(),
            "x2" to x2.toDouble(),
            "y2" to y2.toDouble(),
            "width" to width().toDouble(),
            "height" to height().toDouble()
        )
    }
}
