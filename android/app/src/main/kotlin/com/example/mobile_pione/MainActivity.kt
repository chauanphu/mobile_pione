// FILE: MainActivity.kt
package com.example.mobile_pione

import android.graphics.Bitmap
import android.graphics.BitmapFactory
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

    private val inferenceModel: InferenceModel by lazy {
        InferenceModel.getInstance(applicationContext)
    }
    
    private val backgroundExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- Method Channel remains the same ---
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL_NAME)
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "resetSession" -> {
                    try {
                        inferenceModel.resetSession()
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("RESET_ERROR", "Failed to reset session", e.toString())
                    }
                }
                "sizeInTokens" -> {
                    val text = call.argument<String>("text")
                    if (text == null) {
                        result.error("INVALID_ARGUMENT", "Text argument is missing for sizeInTokens.", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val tokenCount = inferenceModel.sizeInTokens(text)
                        result.success(tokenCount)
                    } catch (e: Exception) {
                        result.error("TOKEN_ERROR", "Failed to get token count", e.toString())
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
    }
}