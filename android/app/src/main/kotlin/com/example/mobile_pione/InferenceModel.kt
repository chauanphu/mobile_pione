package com.example.mobile_pione
import android.content.Context
import android.util.Log
import com.google.common.util.concurrent.ListenableFuture
import com.google.mediapipe.tasks.genai.llminference.*
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession
import com.google.mediapipe.tasks.genai.llminference.LlmInferenceSession.LlmInferenceSessionOptions
import com.google.mediapipe.tasks.genai.llminference.ProgressListener
import java.io.File

/**
 * A self-contained class for managing the MediaPipe LlmInference engine.
 *
 * This class is designed to be used as a singleton through a platform channel,
 * removing any dependencies on a native Android UI.
 */
class InferenceModel private constructor(context: Context) {
    private val TAG = "InferenceModel"

    private lateinit var llmInference: LlmInference
    private lateinit var promptTemplate: PromptTemplates
    private lateinit var llmInferenceSession: LlmInferenceSession

    // The init block is called when an instance of the class is created.
    // It sets up the inference engine and the session.
    init {
        // First, check if the model file exists.
        val modelPath = modelPath(context)
        if (!File(modelPath).exists()) {
            throw IllegalArgumentException("Model not found at path: $modelPath")
        }
        
        try {
            // 1. Create the LlmInference engine
            val inferenceOptions = LlmInference.LlmInferenceOptions.builder()
                .setModelPath(modelPath)
                .setMaxTokens(MAX_TOKENS)
                .setMaxNumImages(5)
                // .setPreferredBackend(LlmInference.Backend.CPU)
                .build()
            llmInference = LlmInference.createFromOptions(context, inferenceOptions)

            promptTemplate = PromptTemplates.builder()
                .setUserPrefix("")
                .setUserSuffix("")
                .setModelPrefix("Answer concisely in roughly 2-3 sentences using paragraph only. Stricly avoid using emoji.")
                .setModelSuffix("")
                .setSystemPrefix("You are a helpful visual impaired assistant.")
                .setSystemSuffix("")
                .build()

            // 2. Create the LlmInferenceSession
            createSession()
        } catch (e: Exception) {
            val errorMessage = "Failed to initialize the model: ${e.message}"
            Log.e(TAG, errorMessage, e)
            throw IllegalStateException(errorMessage)
        }
    }

    /**
     * Creates a new inference session.
     * This is also used by resetSession() to clear the conversation history.
     */
    private fun createSession() {
        val sessionOptions = LlmInferenceSessionOptions.builder()
            .setTemperature(TEMPERATURE)
            .setTopK(TOP_K)
            .setTopP(TOP_P)
            .setGraphOptions(GraphOptions.builder().setEnableVisionModality(true).build())
            .setPromptTemplates(promptTemplate)
            .build()

        llmInferenceSession =
            LlmInferenceSession.createFromOptions(llmInference, sessionOptions)
    }

    /**
     * Generates a response from the model asynchronously.
     *
     * @param prompt The user's input to the model.
     * @param progressListener A listener to receive partial responses as they are generated.
     * @return A ListenableFuture that will eventually contain the full, final response.
     */
    fun generateResponseAsync(prompt: String, progressListener: ProgressListener<String>): ListenableFuture<String> {
        // Add the user's prompt to the session's context
        llmInferenceSession.addQueryChunk(prompt)
        // Generate the response
        return llmInferenceSession.generateResponseAsync(progressListener)
    }

    /**
     * Resets the session, clearing all previous conversation history.
     */
    fun resetSession() {
        // Close the old session
        llmInferenceSession.close()
        // Create a new, empty session
        createSession()
    }

    /**
     * A stateless utility to calculate the number of tokens in a given string.
     *
     * @param text The text to be measured.
     * @return The number of tokens in the text.
     */
    fun sizeInTokens(text: String): Int {
        // This method is useful for managing context window size on the client-side.
        return llmInferenceSession.sizeInTokens(text)
    }

    /**
     * Closes the LlmInference engine and releases resources.
     * Should be called when the model is no longer needed.
     */
    fun close() {
        llmInferenceSession.close()
        llmInference.close()
    }

    companion object {
        // --- Model Configuration ---
        // TODO: Replace this with the name of your model file.
        // This model should be placed in the `android/app/src/main/assets` folder of your Flutter project.
        private const val MODEL_NAME = "model.litertlm"

        // Model parameters
        private const val MAX_TOKENS = 512
        private const val TOP_K = 40
        private const val TOP_P = 1.0f
        private const val TEMPERATURE = 0.4f

        // The singleton instance of the InferenceModel
        @Volatile
        private var instance: InferenceModel? = null

        /**
         * Returns the singleton instance of the InferenceModel.
         *
         * @param context The application context.
         * @return The singleton instance.
         */
        fun getInstance(context: Context): InferenceModel {
            return instance ?: synchronized(this) {
                instance ?: InferenceModel(context).also { instance = it }
            }
        }

        /**
         * Returns the absolute path to the model file.
         * It assumes the model is in the app's internal files directory.
         */
        private fun modelPath(context: Context): String {
            
            return File("/data/local/tmp/llm", MODEL_NAME).absolutePath
        }
    }
}