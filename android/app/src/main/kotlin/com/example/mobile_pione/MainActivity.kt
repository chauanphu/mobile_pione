// FILE: MainActivity.kt
package com.example.mobile_pione

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Log
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.google.mediapipe.tasks.genai.llminference.ProgressListener
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val METHOD_CHANNEL_NAME = "com.example.mobile_pione/llm"
    private val EVENT_CHANNEL_NAME = "com.example.mobile_pione/llm_progress"
    private val STATUS_CHANNEL_NAME = "com.example.mobile_pione/llm_status"
    private val YOLO_CHANNEL_NAME = "com.example.mobile_pione/yolo"

    private val inferenceModel: InferenceModel by lazy {
        InferenceModel.getInstance(applicationContext)
    }

    private val yoloHandler: YoloOnnxHandler by lazy {
        YoloOnnxHandler(applicationContext)
    }
    
    private val backgroundExecutor = Executors.newSingleThreadExecutor()
    private val yoloExecutor = Executors.newSingleThreadExecutor()

    // Model initialization state
    private enum class ModelStatus { UNINITIALIZED, INITIALIZING, READY, ERROR }
    @Volatile private var modelStatus: ModelStatus = ModelStatus.UNINITIALIZED
    @Volatile private var modelInitError: String? = null
    private var statusEventSink: EventChannel.EventSink? = null

    private fun emitStatus(status: ModelStatus, message: String? = null) {
        modelStatus = status
        modelInitError = if (status == ModelStatus.ERROR) message else null
        runOnUiThread {
            statusEventSink?.success(mapOf(
                "status" to status.name,
                "message" to (message ?: "")
            ))
        }
    }

    private fun startModelInitializationIfNeeded() {
        if (modelStatus == ModelStatus.READY || modelStatus == ModelStatus.INITIALIZING) return
        emitStatus(ModelStatus.INITIALIZING, "Starting model initialization")
        backgroundExecutor.execute {
            try {
                // Accessing the lazy property triggers heavy initialization OFF the UI thread
                val model = inferenceModel
                emitStatus(ModelStatus.READY, "Model ready")
            } catch (e: Exception) {
                emitStatus(ModelStatus.ERROR, e.message ?: "Unknown error")
            }
        }
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- Method Channel remains the same ---
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL_NAME)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initializeModel" -> {
                    // Kick off background init and return immediately
                    startModelInitializationIfNeeded()
                    result.success("started")
                }
                "closeModel" -> {
                    // Close native model resources in background
                    backgroundExecutor.execute {
                        try {
                            inferenceModel.close()
                            // Mark as uninitialized after close
                            emitStatus(ModelStatus.UNINITIALIZED, "Model closed")
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("CLOSE_ERROR", "Failed to close model", e.toString())
                            }
                        }
                    }
                }
                "getModelStatus" -> {
                    result.success(modelStatus.name)
                }
                "isModelReady" -> {
                    result.success(modelStatus == ModelStatus.READY)
                }
                "resetSession" -> {
                    if (modelStatus != ModelStatus.READY) {
                        result.error("NOT_READY", "Model not ready. Current status: ${modelStatus.name}", modelInitError)
                    } else {
                        backgroundExecutor.execute {
                            try {
                                inferenceModel.resetSession()
                                runOnUiThread { result.success(true) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("RESET_ERROR", "Failed to reset session", e.toString())
                                }
                            }
                        }
                    }
                }
                "sizeInTokens" -> {
                    val text = call.argument<String>("text")
                    if (text == null) {
                        result.error("INVALID_ARGUMENT", "Text argument is missing for sizeInTokens.", null)
                        return@setMethodCallHandler
                    }
                    if (modelStatus != ModelStatus.READY) {
                        result.error("NOT_READY", "Model not ready. Current status: ${modelStatus.name}", modelInitError)
                    } else {
                        try {
                            val tokenCount = inferenceModel.sizeInTokens(text)
                            result.success(tokenCount)
                        } catch (e: Exception) {
                            result.error("TOKEN_ERROR", "Failed to get token count", e.toString())
                        }
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // --- Event Channel Setup (for streaming responses) ---
        val eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL_NAME)
        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    if (events == null) return

                    // **[MODIFIED]** Expect a Map with "prompt" and "image"
                    val argsMap = arguments as? Map<String, Any>
                    if (argsMap == null) {
                        events.error("INVALID_ARGUMENT", "Arguments must be a Map.", null)
                        return
                    }

                    if (modelStatus != ModelStatus.READY) {
                        events.error("NOT_READY", "Model not ready. Current status: ${modelStatus.name}", modelInitError)
                        return
                    }

                    val prompt = argsMap["prompt"] as? String
                    if (prompt == null) {
                        events.error("INVALID_ARGUMENT", "Prompt is missing.", null)
                        return
                    }
                    
                    // **[NEW]** Extract image data
                    val imageBytes = argsMap["image"] as? ByteArray

                    backgroundExecutor.execute {
                        try {
                            val progressListener = ProgressListener<String> { partialResult, done ->
                                runOnUiThread {
                                    events.success(partialResult)
                                    if (done) {
                                        events.endOfStream()
                                    }
                                }
                            }

                            if (imageBytes != null) {
                                // **[NEW]** Case 1: We have an image
                                val bitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
                                inferenceModel.generateResponseWithImageAsync(prompt, bitmap, progressListener).get()
                            } else {
                                // **[EXISTING]** Case 2: No image, text-only prompt
                                inferenceModel.generateResponseAsync(prompt, progressListener).get()
                            }

                        } catch (e: Exception) {
                            runOnUiThread {
                                events.error("STREAM_ERROR", "Error during model inference", e.toString())
                            }
                        }
                    }
                }

                override fun onCancel(arguments: Any?) {
                    // No changes needed here
                }
            }
        )

        // --- Status Channel Setup (for model initialization progress) ---
        val statusChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, STATUS_CHANNEL_NAME)
        statusChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    statusEventSink = events
                    // Emit current status immediately
                    emitStatus(modelStatus, modelInitError)
                }

                override fun onCancel(arguments: Any?) {
                    statusEventSink = null
                }
            }
        )

        val yoloChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, YOLO_CHANNEL_NAME)
        yoloChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> {
                    val assetPath = call.argument<String>("assetPath")
                    val metadataPath = call.argument<String>("metadataPath")
                    val width = call.argument<Int>("inputWidth") ?: 640
                    val height = call.argument<Int>("inputHeight") ?: 640
                    if (assetPath.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "assetPath is required", null)
                        return@setMethodCallHandler
                    }

                    yoloExecutor.execute {
                        try {
                            yoloHandler.initialize(assetPath, metadataPath, width, height)
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            Log.e("MainActivity", "Failed to initialize YOLO", e)
                            runOnUiThread {
                                result.error(
                                    "YOLO_INIT_ERROR",
                                    e.message ?: "Failed to initialize YOLO",
                                    e.toString(),
                                )
                            }
                        }
                    }
                }
                "detectObjects" -> {
                    val imageBytes = call.argument<ByteArray>("image")
                    val confidence = (call.argument<Double>("confidenceThreshold") ?: 0.25).toFloat()
                    val iou = (call.argument<Double>("iouThreshold") ?: 0.45).toFloat()
                    val applyNms = call.argument<Boolean>("applyNms") ?: false

                    yoloExecutor.execute {
                        try {
                            val detections = yoloHandler.detectObjects(imageBytes, confidence, iou, applyNms)
                            runOnUiThread { result.success(detections) }
                        } catch (e: Exception) {
                            Log.e("MainActivity", "YOLO detection error", e)
                            runOnUiThread {
                                result.error(
                                    "YOLO_DETECT_ERROR",
                                    e.message ?: "YOLO detection failed",
                                    e.toString(),
                                )
                            }
                        }
                    }
                }
                "dispose" -> {
                    yoloExecutor.execute {
                        try {
                            yoloHandler.close()
                            runOnUiThread { result.success(true) }
                        } catch (e: Exception) {
                            Log.e("MainActivity", "YOLO dispose error", e)
                            runOnUiThread {
                                result.error(
                                    "YOLO_DISPOSE_ERROR",
                                    e.message ?: "Failed to dispose YOLO",
                                    e.toString(),
                                )
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }

        // Proactively start model initialization in the background
        startModelInitializationIfNeeded()
    }
}