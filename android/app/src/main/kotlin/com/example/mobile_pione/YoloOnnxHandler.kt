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

class YoloOnnxHandler(private val context: Context) {
    private val loggerTag = "YoloOnnxHandler"
    private val env: OrtEnvironment = OrtEnvironment.getEnvironment()
    private var session: OrtSession? = null
    private var inputName: String? = null
    private val initialized = AtomicBoolean(false)
    private var inputWidth: Int = 640
    private var inputHeight: Int = 640
    private var classNames: Map<Int, String> = emptyMap()

    @Synchronized
    fun initialize(assetPath: String, metadataPath: String?, width: Int, height: Int) {
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
            classNames = metadataPath?.let { loadClassNames(it) } ?: emptyMap()
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
        shouldApplyNms: Boolean = false,
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
            val onnxValue = result?.get(0) ?: return emptyList()

            @Suppress("UNCHECKED_CAST")
            val rawOutput = onnxValue.value as? Array<Array<FloatArray>>
                ?: return emptyList()

            val batchOutput = rawOutput.firstOrNull() ?: return emptyList()
            if (batchOutput.isEmpty()) return emptyList()

            val predictions = convertRowsToPredictions(batchOutput)
            if (predictions.isEmpty()) return emptyList()

            val scaleX = originalWidth.toFloat() / inputWidth.toFloat()
            val scaleY = originalHeight.toFloat() / inputHeight.toFloat()

            val parsedDetections = buildDetections(
                predictions,
                confidenceThreshold,
                scaleX,
                scaleY,
                originalWidth,
                originalHeight,
            )

            val finalDetections = if (shouldApplyNms) {
                applyNms(parsedDetections, iouThreshold)
            } else {
                parsedDetections
            }

            val resultMaps = finalDetections.map { det ->
                val bboxMap = det.box.toMap()
                buildMap<String, Any> {
                    put("classId", det.classId)
                    put("className", det.className)
                    put("confidence", det.confidence.toDouble())
                    put("box", bboxMap)
                    put("bbox", bboxMap.toMutableMap())
                    put("imageWidth", originalWidth)
                    put("imageHeight", originalHeight)
                    det.maskCoefficients?.takeIf { it.isNotEmpty() }?.let { mask ->
                        put("mask", mask.map { value -> value.toDouble() })
                    }
                }
            }

            Log.d(loggerTag, "Parsed ${resultMaps.size} detections from ONNX output")
            return resultMaps
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
            classNames = emptyMap()
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

    private fun loadClassNames(metadataAssetPath: String): Map<Int, String> {
        val flutterLoader = FlutterInjector.instance().flutterLoader()
        val assetKey = flutterLoader.getLookupKeyForAsset(metadataAssetPath)

        return try {
            context.assets.open(assetKey).use { inputStream ->
                val jsonText = inputStream.bufferedReader().use { it.readText() }
                val json = JSONObject(jsonText)
                val namesJson = json.optJSONObject("names") ?: return emptyMap()
                val keys = namesJson.keys()
                buildMap {
                    while (keys.hasNext()) {
                        val key = keys.next()
                        val classId = key.toIntOrNull()
                        if (classId != null) {
                            put(classId, namesJson.optString(key))
                        }
                    }
                }
            }
        } catch (ioe: IOException) {
            Log.w(loggerTag, "Failed to load metadata $metadataAssetPath", ioe)
            emptyMap()
        }
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

    private fun convertRowsToPredictions(rows: Array<FloatArray>): Array<FloatArray> {
        if (rows.isEmpty()) return emptyArray()
        val columnCount = rows[0].size
        if (columnCount == 0) return emptyArray()

        val rowCount = rows.size
        val rowsRepresentPredictions = rowCount >= columnCount
        if (rowsRepresentPredictions) {
            return rows
        }

        val predictions = Array(columnCount) { FloatArray(rowCount) }
        for (rowIndex in 0 until rowCount) {
            val row = rows[rowIndex]
            val limit = min(columnCount, row.size)
            for (columnIndex in 0 until limit) {
                predictions[columnIndex][rowIndex] = row[columnIndex]
            }
        }
        return predictions
    }

    private fun buildDetections(
        predictions: Array<FloatArray>,
        confidenceThreshold: Float,
        scaleX: Float,
        scaleY: Float,
        originalWidth: Int,
        originalHeight: Int,
    ): List<Detection> {
        if (predictions.isEmpty()) return emptyList()

        val detections = ArrayList<Detection>()
        for (row in predictions) {
            if (row.size < 6) continue

            val confidence = row[4]
            if (confidence < confidenceThreshold) continue

            val classId = row[5].toInt().coerceAtLeast(0)
            val className = classNames[classId] ?: "unknown"

            val xCenter = row[0]
            val yCenter = row[1]
            val width = row[2]
            val height = row[3]

            val xMin = (xCenter - width / 2f) * scaleX
            val yMin = (yCenter - height / 2f) * scaleY
            val xMax = (xCenter + width / 2f) * scaleX
            val yMax = (yCenter + height / 2f) * scaleY

            val maxWidth = originalWidth.toFloat()
            val maxHeight = originalHeight.toFloat()
            val clampedXMin = xMin.coerceIn(0f, maxWidth)
            val clampedYMin = yMin.coerceIn(0f, maxHeight)
            val clampedXMax = xMax.coerceIn(0f, maxWidth)
            val clampedYMax = yMax.coerceIn(0f, maxHeight)

            val box = BoundingBox(
                x1 = clampedXMin,
                y1 = clampedYMin,
                x2 = max(clampedXMax, clampedXMin),
                y2 = max(clampedYMax, clampedYMin),
            )

            val maskCoefficients = if (row.size > 6) {
                row.copyOfRange(6, row.size)
            } else {
                null
            }

            detections.add(
                Detection(
                    classId = classId,
                    className = className,
                    confidence = confidence,
                    box = box,
                    maskCoefficients = maskCoefficients,
                ),
            )
        }
        return detections
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
        val className: String,
        val confidence: Float,
        val box: BoundingBox,
        val maskCoefficients: FloatArray? = null,
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

        fun toMap(): Map<String, Double> = mapOf(
            "x1" to x1.toDouble(),
            "y1" to y1.toDouble(),
            "x2" to x2.toDouble(),
            "y2" to y2.toDouble(),
            "width" to width().toDouble(),
            "height" to height().toDouble(),
        )
    }
}
