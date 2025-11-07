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
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession

class YoloOnnxHandler(private val context: Context) {
    private val loggerTag = "YoloOnnxHandler"
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null
    private var inputName: String? = null
    private val initialized = AtomicBoolean(false)
    private var inputWidth: Int = 640
    private var inputHeight: Int = 640

    @Synchronized
    fun initialize(assetPath: String, width: Int, height: Int) {
        if (initialized.get()) return

        val modelFile = loadModelFromAssets(assetPath)
        val sessionOptions = OrtSession.SessionOptions().apply {
            setOptimizationLevel(OrtSession.SessionOptions.OptLevel.ALL_OPT)
            setIntraOpNumThreads(Runtime.getRuntime().availableProcessors())
            setInterOpNumThreads(Runtime.getRuntime().availableProcessors())
        }

        try {
            val createdSession = env.createSession(modelFile.absolutePath, sessionOptions)
            val firstInputName = createdSession.inputNames.iterator().next()

            session = createdSession
            inputName = firstInputName
            inputWidth = width
            inputHeight = height
            initialized.set(true)
            Log.i(loggerTag, "YOLO ONNX session initialized with input $firstInputName")
        } finally {
            sessionOptions.close()
        }
    }

    @Synchronized
    fun detectObjects(
        imageBytes: ByteArray?,
        confidenceThreshold: Float,
        iouThreshold: Float,
    ): List<Map<String, Any>> {
        if (!initialized.get() || session == null || inputName == null) {
            throw IllegalStateException("YOLO model not initialized")
        }
        if (imageBytes == null || imageBytes.isEmpty()) {
            throw IllegalArgumentException("Image bytes are empty")
        }

        val bitmapOptions = BitmapFactory.Options().apply {
            inPreferredConfig = Bitmap.Config.ARGB_8888
        }

        val bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size, bitmapOptions)
            ?: throw IllegalArgumentException("Failed to decode image bytes")
        val originalWidth = bitmap.width
        val originalHeight = bitmap.height

        var inputTensor: OnnxTensor? = null
        var result: OrtSession.Result? = null

        try {
            val floatBuffer = preprocessBitmap(bitmap)
            inputTensor = OnnxTensor.createTensor(
                env,
                floatBuffer,
                longArrayOf(1, 3, inputHeight.toLong(), inputWidth.toLong()),
            )

            val inputs = mapOf(inputName!! to inputTensor)
            result = session!!.run(inputs)
            val onnxValue = result?.get(0)
                ?: return emptyList()

            @Suppress("UNCHECKED_CAST")
            val rawOutput = onnxValue.value as? Array<Array<FloatArray>>
                ?: return emptyList()

            val detections = parseDetections(
                rawOutput,
                confidenceThreshold,
                iouThreshold,
                originalWidth,
                originalHeight,
            )

            Log.d(loggerTag, "Parsed ${detections.size} detections from ONNX output")
            return detections
        } finally {
            result?.close()
            inputTensor?.close()
            bitmap.recycle()
        }
    }

    fun close() {
        initialized.set(false)
        try {
            session?.close()
        } catch (e: Exception) {
            Log.w(loggerTag, "Error closing session", e)
        } finally {
            session = null
            inputName = null
        }
    }

    private fun loadModelFromAssets(assetPath: String): File {
        val flutterLoader = FlutterInjector.instance().flutterLoader()
        val assetKey = flutterLoader.getLookupKeyForAsset(assetPath)
        val modelsDir = File(context.filesDir, "onnx_models")
        if (!modelsDir.exists()) {
            modelsDir.mkdirs()
        }

        val targetFile = File(modelsDir, File(assetPath).name)
        if (targetFile.exists() && targetFile.length() > 0) {
            return targetFile
        }

        try {
            context.assets.open(assetKey).use { input ->
                FileOutputStream(targetFile).use { output ->
                    input.copyTo(output)
                }
            }
        } catch (e: IOException) {
            targetFile.delete()
            throw IOException("Failed to copy ONNX model from assets", e)
        }

        return targetFile
    }

    private fun preprocessBitmap(source: Bitmap): FloatBuffer {
        val resized = if (source.width != inputWidth || source.height != inputHeight) {
            Bitmap.createScaledBitmap(source, inputWidth, inputHeight, true)
        } else {
            source
        }

        val pixelCount = inputWidth * inputHeight
        val pixels = IntArray(pixelCount)
        resized.getPixels(pixels, 0, inputWidth, 0, 0, inputWidth, inputHeight)

        val floatBuffer = ByteBuffer.allocateDirect(4 * 3 * pixelCount)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()

        val norm = 1f / 255f
        for (channel in 0 until 3) {
            for (pixel in pixels) {
                val value = when (channel) {
                    0 -> ((pixel shr 16) and 0xFF) * norm
                    1 -> ((pixel shr 8) and 0xFF) * norm
                    else -> (pixel and 0xFF) * norm
                }
                floatBuffer.put(value)
            }
        }
        floatBuffer.rewind()

        if (resized != source) {
            resized.recycle()
        }

        return floatBuffer
    }

    private fun parseDetections(
        output: Array<Array<FloatArray>>,
        confidenceThreshold: Float,
        iouThreshold: Float,
        originalWidth: Int,
        originalHeight: Int,
    ): List<Map<String, Any>> {
        if (output.isEmpty()) return emptyList()
        val features = output[0]
        if (features.isEmpty()) return emptyList()

        val numFeatures = features.size
        if (numFeatures < 5) return emptyList()

        val numBoxes = features[0].size
        val numClasses = numFeatures - 4
        val detections = ArrayList<Detection>(numBoxes)

        for (boxIdx in 0 until numBoxes) {
            val xCenter = features[0][boxIdx]
            val yCenter = features[1][boxIdx]
            val width = features[2][boxIdx]
            val height = features[3][boxIdx]

            var bestScore = Float.NEGATIVE_INFINITY
            var bestClassId = -1
            for (c in 0 until numClasses) {
                val clsScore = features[4 + c][boxIdx]
                if (clsScore > bestScore) {
                    bestScore = clsScore
                    bestClassId = c
                }
            }

            if (bestClassId < 0 || bestScore < confidenceThreshold) {
                continue
            }

            val xCenterPx = xCenter * originalWidth
            val yCenterPx = yCenter * originalHeight
            val widthPx = width * originalWidth
            val heightPx = height * originalHeight

            val x1 = (xCenterPx - widthPx / 2f).coerceIn(0f, originalWidth.toFloat())
            val y1 = (yCenterPx - heightPx / 2f).coerceIn(0f, originalHeight.toFloat())
            val x2 = (xCenterPx + widthPx / 2f).coerceIn(0f, originalWidth.toFloat())
            val y2 = (yCenterPx + heightPx / 2f).coerceIn(0f, originalHeight.toFloat())

            detections.add(
                Detection(
                    classId = bestClassId,
                    confidence = bestScore,
                    box = BoundingBox(x1, y1, x2, y2),
                ),
            )
        }

        if (detections.isEmpty()) {
            return emptyList()
        }

        val filtered = applyNms(detections, iouThreshold)
        return filtered.map { det ->
            mapOf(
                "classId" to det.classId,
                "confidence" to det.confidence.toDouble(),
                "bbox" to mapOf(
                    "x1" to det.box.x1.toDouble(),
                    "y1" to det.box.y1.toDouble(),
                    "x2" to det.box.x2.toDouble(),
                    "y2" to det.box.y2.toDouble(),
                    "width" to det.box.width().toDouble(),
                    "height" to det.box.height().toDouble(),
                ),
            )
        }
    }

    private fun applyNms(detections: List<Detection>, iouThreshold: Float): List<Detection> {
        if (detections.isEmpty()) return emptyList()

        val sorted = detections.sortedByDescending { it.confidence }
        val suppressed = BooleanArray(sorted.size)
        val result = ArrayList<Detection>()

        for (i in sorted.indices) {
            if (suppressed[i]) continue

            val detA = sorted[i]
            result.add(detA)

            for (j in i + 1 until sorted.size) {
                if (suppressed[j]) continue

                val detB = sorted[j]
                val overlap = iou(detA.box, detB.box)
                if (overlap > iouThreshold) {
                    suppressed[j] = true
                }
            }
        }

        return result
    }

    private fun iou(a: BoundingBox, b: BoundingBox): Float {
        val x1 = max(a.x1, b.x1)
        val y1 = max(a.y1, b.y1)
        val x2 = min(a.x2, b.x2)
        val y2 = min(a.y2, b.y2)

        if (x2 <= x1 || y2 <= y1) {
            return 0f
        }

        val intersection = (x2 - x1) * (y2 - y1)
        val union = a.area() + b.area() - intersection
        return if (union <= 0f) 0f else intersection / union
    }

    private data class Detection(
        val classId: Int,
        val confidence: Float,
        val box: BoundingBox,
    )

    private data class BoundingBox(
        val x1: Float,
        val y1: Float,
        val x2: Float,
        val y2: Float,
    ) {
        fun width(): Float = (x2 - x1).coerceAtLeast(0f)
        fun height(): Float = (y2 - y1).coerceAtLeast(0f)
        fun area(): Float = width() * height()
    }
}
