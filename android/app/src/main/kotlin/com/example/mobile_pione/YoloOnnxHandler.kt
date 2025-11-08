package com.example.mobile_pione

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import io.flutter.FlutterInjector
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max
import kotlin.math.min
import org.json.JSONObject
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession

/**
 * YOLOE ONNX Handler for object detection using ONNX Runtime
 * 
 * Model Input:
 * - Shape: [1, 3, 640, 640] (batch, channels, height, width)
 * - Format: RGB, normalized [0, 1]
 * - Input name: "images"
 * 
 * Model Output:
 * - Output 0: [1, 300, 38] - Detection boxes (x_center, y_center, width, height, confidence, class_id, ...mask_coefficients)
 * - Output 1: [1, 32, 160, 160] - Feature maps for masking
 * 
 * Note: Model includes NMS, so post-processing NMS is optional
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
    private val maxResults = 10
    
    // YOLOE format constants
    private companion object {
        const val INPUT_NAME = "images"
        const val BOX_X_CENTER_INDEX = 0
        const val BOX_Y_CENTER_INDEX = 1
        const val BOX_WIDTH_INDEX = 2
        const val BOX_HEIGHT_INDEX = 3
        const val CONFIDENCE_INDEX = 4
        const val CLASS_ID_INDEX = 5
        const val MIN_BOX_ATTRIBUTES = 6
    }

    @Synchronized
    fun initialize(assetPath: String, metadataPath: String?, width: Int, height: Int) {
        if (initialized.get()) {
            Log.i(loggerTag, "YOLO model already initialized")
            return
        }

        val modelFile = AssetLoader(context).loadModelFromAssets(assetPath)
        val sessionOptions = createSessionOptions()

        try {
            session = env.createSession(modelFile.absolutePath, sessionOptions)
            inputWidth = width
            inputHeight = height
            classNames = metadataPath?.let { AssetLoader(context).loadClassNames(it) } ?: emptyMap()
            initialized.set(true)
            Log.i(loggerTag, "YOLO ONNX session initialized successfully")
            Log.d(loggerTag, "Input size: ${inputWidth}x${inputHeight}, Classes: ${classNames.size}")
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
        shouldApplyNms: Boolean = false,
    ): List<Map<String, Any>> {
        requireInitialized()
        require(imageBytes != null && imageBytes.isNotEmpty()) { "Image bytes are empty" }

        val bitmap = decodeBitmap(imageBytes)
        val imageInfo = ImageInfo(bitmap.width, bitmap.height, inputWidth, inputHeight)
        
        return try {
            val preprocessedImage = ImagePreprocessor.preprocess(bitmap, inputWidth, inputHeight)
            val inferenceResult = runInference(preprocessedImage)
            val detections = processInferenceOutput(inferenceResult, confidenceThreshold, imageInfo)
            
            val finalDetections = if (shouldApplyNms) {
                NmsProcessor.applyNms(detections, iouThreshold)
            } else {
                detections
            }.sortedByDescending { it.confidence }
                .take(maxResults)
            
            DetectionMapper.toMapList(finalDetections, imageInfo.originalWidth, imageInfo.originalHeight)
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

    private fun runInference(preprocessedImage: FloatBuffer): InferenceOutput {
        var inputTensor: OnnxTensor? = null
        var result: OrtSession.Result? = null

        try {
            inputTensor = OnnxTensor.createTensor(
                env,
                preprocessedImage,
                longArrayOf(1, 3, inputHeight.toLong(), inputWidth.toLong())
            )

            val inputs = mapOf(INPUT_NAME to inputTensor)
            result = session!!.run(inputs)

            // YOLOE outputs: [0] = detections (1, 300, 38), [1] = prototypes (1, 32, 160, 160)
            val detectionsOutput = result[0]?.value as? Array<*>
                ?: throw IllegalStateException("Invalid output format from model")

            Log.d(loggerTag, "Model output received successfully")
            return parseModelOutput(detectionsOutput)
        } catch (e: Exception) {
            Log.e(loggerTag, "Inference failed", e)
            throw IllegalStateException("YOLO inference failed: ${e.message}", e)
        } finally {
            result?.close()
            inputTensor?.close()
        }
    }

    private fun parseModelOutput(output: Array<*>): InferenceOutput {
        // Expected shape: [1, 300, 38] where first dimension is batch
        if (output.isEmpty()) {
            return InferenceOutput(emptyArray())
        }

        @Suppress("UNCHECKED_CAST")
        val batchOutput = output[0] as? Array<FloatArray>
            ?: throw IllegalStateException("Unexpected output format")

        Log.d(loggerTag, "Detection output shape: [${output.size}, ${batchOutput.size}, ${batchOutput.firstOrNull()?.size ?: 0}]")
        
        return InferenceOutput(batchOutput)
    }

    private fun processInferenceOutput(
        inferenceOutput: InferenceOutput,
        confidenceThreshold: Float,
        imageInfo: ImageInfo
    ): List<Detection> {
        val detections = mutableListOf<Detection>()
        
        for (prediction in inferenceOutput.detections) {
            if (prediction.size < MIN_BOX_ATTRIBUTES) {
                continue
            }

            val confidence = prediction[CONFIDENCE_INDEX]
            if (confidence < confidenceThreshold) {
                continue
            }

            val detection = createDetection(prediction, confidence, imageInfo)
            detection?.let { detections.add(it) }
        }

        Log.d(loggerTag, "Parsed ${detections.size} detections above threshold $confidenceThreshold")
        return detections
    }

    private fun createDetection(
        prediction: FloatArray,
        confidence: Float,
        imageInfo: ImageInfo
    ): Detection? {
        val xCenter = prediction[BOX_X_CENTER_INDEX]
        val yCenter = prediction[BOX_Y_CENTER_INDEX]
        val width = prediction[BOX_WIDTH_INDEX]
        val height = prediction[BOX_HEIGHT_INDEX]
        val classId = prediction[CLASS_ID_INDEX].toInt()

        if (width <= 0f || height <= 0f) {
            return null
        }

        val className = classNames[classId] ?: "Class $classId"
        val box = BoundingBox.fromCenterFormat(
            xCenter, yCenter, width, height,
            imageInfo.scaleX, imageInfo.scaleY,
            imageInfo.originalWidth, imageInfo.originalHeight
        )

        return box?.let {
            Detection(classId, className, confidence, it)
        }
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

        fun loadClassNames(metadataAssetPath: String): Map<Int, String> {
            val flutterLoader = FlutterInjector.instance().flutterLoader()
            val assetKey = flutterLoader.getLookupKeyForAsset(metadataAssetPath)

            return try {
                context.assets.open(assetKey).use { inputStream ->
                    val jsonText = inputStream.bufferedReader().use { it.readText() }
                    val json = JSONObject(jsonText)
                    val namesJson = json.optJSONObject("names") ?: return emptyMap()
                    
                    buildMap {
                        val keys = namesJson.keys()
                        while (keys.hasNext()) {
                            val key = keys.next()
                            val classId = key.toIntOrNull()
                            if (classId != null) {
                                put(classId, namesJson.optString(key))
                            }
                        }
                    }
                }
            } catch (e: IOException) {
                Log.w(loggerTag, "Failed to load metadata: $metadataAssetPath", e)
                emptyMap()
            }
        }
    }

    /**
     * Handles image preprocessing for YOLO model
     */
    private object ImagePreprocessor {
        fun preprocess(source: Bitmap, targetWidth: Int, targetHeight: Int): FloatBuffer {
            val resized = resizeBitmap(source, targetWidth, targetHeight)
            val floatBuffer = convertToFloatBuffer(resized, targetWidth, targetHeight)
            
            if (resized != source) {
                resized.recycle()
            }
            
            return floatBuffer
        }

        private fun resizeBitmap(bitmap: Bitmap, width: Int, height: Int): Bitmap {
            return if (bitmap.width != width || bitmap.height != height) {
                Bitmap.createScaledBitmap(bitmap, width, height, true)
            } else {
                bitmap
            }
        }

        private fun convertToFloatBuffer(bitmap: Bitmap, width: Int, height: Int): FloatBuffer {
            val pixelCount = width * height
            val pixels = IntArray(pixelCount)
            bitmap.getPixels(pixels, 0, width, 0, 0, width, height)

            val floatBuffer = ByteBuffer.allocateDirect(4 * 3 * pixelCount)
                .order(ByteOrder.nativeOrder())
                .asFloatBuffer()

            // Convert to CHW format (Channels, Height, Width) and normalize [0, 1]
            val norm = 1f / 255f
            for (channel in 0 until 3) {
                for (pixel in pixels) {
                    val value = when (channel) {
                        0 -> ((pixel shr 16) and 0xFF) * norm  // Red
                        1 -> ((pixel shr 8) and 0xFF) * norm   // Green
                        else -> (pixel and 0xFF) * norm        // Blue
                    }
                    floatBuffer.put(value)
                }
            }
            floatBuffer.rewind()
            return floatBuffer
        }
    }

    /**
     * Applies Non-Maximum Suppression to filter overlapping detections
     */
    private object NmsProcessor {
        fun applyNms(detections: List<Detection>, iouThreshold: Float): List<Detection> {
            if (detections.isEmpty()) return emptyList()

            val sorted = detections.sortedByDescending { it.confidence }
            val suppressed = BooleanArray(sorted.size)
            val result = mutableListOf<Detection>()

            for (i in sorted.indices) {
                if (suppressed[i]) continue

                val detectionA = sorted[i]
                result.add(detectionA)

                for (j in i + 1 until sorted.size) {
                    if (suppressed[j]) continue

                    val detectionB = sorted[j]
                    if (calculateIou(detectionA.box, detectionB.box) > iouThreshold) {
                        suppressed[j] = true
                    }
                }
            }

            return result
        }

        private fun calculateIou(a: BoundingBox, b: BoundingBox): Float {
            val x1 = max(a.x1, b.x1)
            val y1 = max(a.y1, b.y1)
            val x2 = min(a.x2, b.x2)
            val y2 = min(a.y2, b.y2)

            if (x2 <= x1 || y2 <= y1) return 0f

            val intersection = (x2 - x1) * (y2 - y1)
            val union = a.area() + b.area() - intersection
            
            return if (union <= 0f) 0f else intersection / union
        }
    }

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
     * Holds information about image dimensions and scaling factors
     */
    private data class ImageInfo(
        val originalWidth: Int,
        val originalHeight: Int,
        val inputWidth: Int,
        val inputHeight: Int
    ) {
        val scaleX: Float = originalWidth.toFloat() / inputWidth.toFloat()
        val scaleY: Float = originalHeight.toFloat() / inputHeight.toFloat()
    }

    /**
     * Wrapper for ONNX model inference output
     */
    private data class InferenceOutput(
        val detections: Array<FloatArray>
    ) {
        override fun equals(other: Any?): Boolean {
            if (this === other) return true
            if (javaClass != other?.javaClass) return false
            other as InferenceOutput
            return detections.contentDeepEquals(other.detections)
        }

        override fun hashCode(): Int {
            return detections.contentDeepHashCode()
        }
    }

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

        companion object {
            /**
             * Creates a BoundingBox from center format (x_center, y_center, width, height)
             * and scales it to original image dimensions
             */
            fun fromCenterFormat(
                xCenter: Float,
                yCenter: Float,
                width: Float,
                height: Float,
                scaleX: Float,
                scaleY: Float,
                maxWidth: Int,
                maxHeight: Int
            ): BoundingBox? {
                if (width <= 0f || height <= 0f) return null

                val x1 = (xCenter - width / 2f) * scaleX
                val y1 = (yCenter - height / 2f) * scaleY
                val x2 = (xCenter + width / 2f) * scaleX
                val y2 = (yCenter + height / 2f) * scaleY

                // Clamp to image boundaries
                val clampedX1 = x1.coerceIn(0f, maxWidth.toFloat())
                val clampedY1 = y1.coerceIn(0f, maxHeight.toFloat())
                val clampedX2 = x2.coerceIn(0f, maxWidth.toFloat())
                val clampedY2 = y2.coerceIn(0f, maxHeight.toFloat())

                // Validate box dimensions
                if (clampedX2 <= clampedX1 || clampedY2 <= clampedY1) {
                    return null
                }

                return BoundingBox(clampedX1, clampedY1, clampedX2, clampedY2)
            }
        }
    }
}
