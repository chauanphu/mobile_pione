package com.example.mobile_pione // <-- Make sure this matches your package name

import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import com.example.mobile_pione.InferenceModel
import com.google.mediapipe.tasks.genai.llminference.ProgressListener
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    // Define unique names for our channels.
    // These must match the strings on the Flutter (Dart) side.
    private val METHOD_CHANNEL_NAME = "com.example.mobile_pione/llm"
    private val EVENT_CHANNEL_NAME = "com.example.mobile_pione/llm_progress"

    // Lazily initialize the InferenceModel singleton
    private val inferenceModel: InferenceModel by lazy {
        InferenceModel.getInstance(applicationContext)
    }
    
    // A dedicated background thread for running model inference
    private val backgroundExecutor = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- Method Channel Setup (for single, non-streaming calls) ---
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
                // This is called when Flutter starts listening on the stream.
                // The prompt is passed as an argument.
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    val prompt = arguments as? String
                    if (prompt == null || events == null) {
                        events?.error("INVALID_ARGUMENT", "Prompt argument is missing for generateResponse.", null)
                        return
                    }

                    // Run the inference on a background thread
                    backgroundExecutor.execute {
                        try {
                            // Create a ProgressListener that sends data back to Flutter
                            val progressListener = ProgressListener<String> { partialResult, done ->
                                // Post the result back to the main thread to safely interact with the EventSink
                                runOnUiThread {
                                    events.success(partialResult) // Send partial result
                                    if (done) {
                                        events.endOfStream() // Signal that the stream is complete
                                    }
                                }
                            }
                            
                            // Start the generation. The future's result is the final complete string,
                            // but we are streaming the results via the listener. We call .get() here
                            // to block this background thread until generation is done and to catch exceptions.
                            inferenceModel.generateResponseAsync(prompt, progressListener).get()

                        } catch (e: Exception) {
                            runOnUiThread {
                                events.error("STREAM_ERROR", "Error during model inference", e.toString())
                            }
                        }
                    }
                }

                // This is called when Flutter cancels its subscription to the stream.
                override fun onCancel(arguments: Any?) {
                    // No specific cancellation logic is needed for this model,
                    // but you could add cleanup here if required.
                }
            }
        )
    }
}