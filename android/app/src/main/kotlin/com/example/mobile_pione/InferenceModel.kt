// FILE: InferenceModel.kt
package com.example.mobile_pione

import android.content.Context
import android.graphics.Bitmap
import android.util.Log
import com.google.common.util.concurrent.ListenableFuture
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.genai.llminference.*
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession.LlmInferenceSessionOptions
import com.google.mediapipe.tasks.genai.llminference.ProgressListener
import java.io.File

/**
 * A self-contained class for managing the MediaPipe LlmInference engine.
 */
class InferenceModel private constructor(context: Context) {
    private val TAG = "InferenceModel"

    private lateinit var llmInference: LlmInference
    private lateinit var promptTemplate: PromptTemplates
    private lateinit var llmInferenceSession: LlmInferenceSession

    init {
        val modelPath = modelPath(context)
        if (!File(modelPath).exists()) {
            throw IllegalArgumentException("Model not found at path: $modelPath")
        }
        
        try {
            val inferenceOptions = LlmInference.LlmInferenceOptions.builder()
                .setModelPath(modelPath)
                .setMaxTokens(MAX_TOKENS)
                .setMaxNumImages(5)
                .setPreferredBackend(LlmInference.Backend.GPU)
                .build()
            llmInference = LlmInference.createFromOptions(context, inferenceOptions)

            promptTemplate = PromptTemplates.builder()
                .setUserPrefix("")
                .setUserSuffix("")
                .setModelPrefix("Answer concisely in roughly 2-3 sentences using paragraph only. Strictly avoid using emoji.")
                .setModelSuffix("")
                .setSystemPrefix("You are a helpful visual impaired assistant.")
                .setSystemSuffix("")
                .build()

            createSession()
        } catch (e: Exception) {
            val errorMessage = "Failed to initialize the model: ${e.message}"
            Log.e(TAG, errorMessage, e)
            throw IllegalStateException(errorMessage)
        }
    }

    private fun createSession() {
        val sessionOptions = LlmInferenceSessionOptions.builder()
            .setTemperature(TEMPERATURE)
            .setTopK(TOP_K)
            .setTopP(TOP_P)
            .setGraphOptions(GraphOptions.builder().setEnableVisionModality(true).build())
            .setPromptTemplates(promptTemplate)
            .build()
        llmInferenceSession = LlmInferenceSession.createFromOptions(llmInference, sessionOptions)
    }

    /**
     * Generates a response from the model asynchronously based on a text prompt.
     */
    fun generateResponseAsync(prompt: String, progressListener: ProgressListener<String>): ListenableFuture<String> {
        llmInferenceSession.addQueryChunk(prompt)
        return llmInferenceSession.generateResponseAsync(progressListener)
    }

    /**
     * **[NEW]** Generates a response from the model asynchronously based on a text prompt and an image.
     */
    fun generateResponseWithImageAsync(prompt: String, bitmap: Bitmap, progressListener: ProgressListener<String>): ListenableFuture<String> {
        // Convert the input Bitmap object to an MPImage object
        val mpImage = BitmapImageBuilder(bitmap).build()
        
        // Add the prompt and image to the session
        llmInferenceSession.addQueryChunk(prompt)
        llmInferenceSession.addImage(mpImage)

        // Generate the response
        return llmInferenceSession.generateResponseAsync(progressListener)
    }


    fun resetSession() {
        llmInferenceSession.close()
        createSession()
    }

    fun sizeInTokens(text: String): Int {
        return llmInferenceSession.sizeInTokens(text)
    }

    fun close() {
        llmInferenceSession.close()
        llmInference.close()
    }

    companion object {
        private const val MODEL_NAME = "model.litertlm"
        private const val MAX_TOKENS = 512
        private const val TOP_K = 40
        private const val TOP_P = 1.0f
        private const val TEMPERATURE = 0.4f

        @Volatile
        private var instance: InferenceModel? = null

        fun getInstance(context: Context): InferenceModel {
            return instance ?: synchronized(this) {
                instance ?: InferenceModel(context).also { instance = it }
            }
        }

        private fun modelPath(context: Context): String {
            return File("/data/local/tmp/llm", MODEL_NAME).absolutePath
        }
    }
}