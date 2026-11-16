/*
 * Experimental Android port of the homr 0.7.0 transformer decoding protocol.
 * homr is Copyright (c) Christian Liebhardt and contributors, AGPL-3.0.
 * See apps/choir_mobile/third_party/homr/NOTICE.md and LICENSE.
 * This file does not include model weights or vocabulary assets.
 */
package jp.choiromr.mobile.omr

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OnnxTensorLike
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer
import java.nio.LongBuffer
import java.security.MessageDigest

/**
 * One model symbol in the model's six vocabularies. [x] is the canvas x the
 * decoder attended to (homr's symbol coordinates; approximate), NaN if unknown.
 */
data class StaffToken(val rhythm: Int, val pitch: Int, val lift: Int,
                      val position: Int, val articulation: Int, val slur: Int, val x: Float = Float.NaN)

data class DecodeResult(val tokens: List<StaffToken>, val reachedEos: Boolean,
                        val encoderMillis: Long, val decoderMillis: Long)

/**
 * CPU inference over a prepared 1280 x 256 grayscale staff canvas.
 * This does not detect staves, transform symbols into a score or infer PDF pages.
 * Instances are single-threaded and must be closed after use.
 */
class StaffDecoder(encoderFile: File, decoderFile: File, threads: Int = 2) : AutoCloseable {
    private val env = OrtEnvironment.getEnvironment()
    private val encoder: OrtSession
    private val decoder: OrtSession

    init {
        require(threads in 1..16)
        verify(encoderFile, ENCODER_HASH)
        verify(decoderFile, DECODER_HASH)
        OrtSession.SessionOptions().use { options ->
            options.setIntraOpNumThreads(threads)
            options.setInterOpNumThreads(1)
            encoder = env.createSession(encoderFile.absolutePath, options)
            try { decoder = env.createSession(decoderFile.absolutePath, options) }
            catch (e: Exception) { encoder.close(); throw e }
        }
    }

    fun decode(gray: ByteArray, maxSteps: Int = 608, cancelled: () -> Boolean = { false }): DecodeResult {
        require(gray.size == WIDTH * HEIGHT) { "The staff canvas must be 1280 x 256 grayscale bytes." }
        require(maxSteps in 1..608)
        val pixels = FloatBuffer.allocate(gray.size)
        for (b in gray) pixels.put((((b.toInt() and 255) / 255.0 - 0.7931) / 0.1738).toFloat())
        pixels.rewind()
        val started = System.nanoTime()
        OnnxTensor.createTensor(env, pixels, longArrayOf(1, 1, HEIGHT.toLong(), WIDTH.toLong())).use { input ->
            encoder.run(mapOf("input" to input)).use { encoded ->
                val encoderMs = (System.nanoTime() - started) / 1_000_000
                val context = encoded.get("output").orElseThrow() as OnnxTensor
                val firstVector = context.floatBuffer
                val reduced = FloatArray(512)
                firstVector.get(reduced)
                OnnxTensor.createTensor(env, FloatBuffer.wrap(reduced), longArrayOf(1, 1, 512)).use { reducedContext ->
                    return decodeTokens(context, reducedContext, maxSteps, encoderMs, cancelled)
                }
            }
        }
    }

    private fun decodeTokens(context: OnnxTensor, reduced: OnnxTensor, maxSteps: Int,
                             encoderMs: Long, cancelled: () -> Boolean): DecodeResult {
        val start = System.nanoTime()
        val tokens = mutableListOf<StaffToken>()
        val emptyCache = mutableListOf<OnnxTensor>()
        var previous: OrtSession.Result? = null
        var rhythm = 1L; var pitch = 0L; var lift = 0L; var articulation = 0L; var slur = 0L
        var eos = false
        try {
            repeat(32) {
                // ONNX Runtime accepts empty tensors for an initially empty KV cache.
                val empty = ByteBuffer.allocateDirect(0).order(ByteOrder.nativeOrder()).asFloatBuffer()
                emptyCache.add(OnnxTensor.createTensor(env, empty, longArrayOf(1, 8, 0, 64)))
            }
            for (step in 0 until maxSteps) {
                if (cancelled()) throw InterruptedException("Recognition cancelled")
                val scalarInputs = mutableListOf<OnnxTensor>()
                fun intTensor(value: Long): OnnxTensor = OnnxTensor.createTensor(env, LongBuffer.wrap(longArrayOf(value)), longArrayOf(1, 1)).also { scalarInputs.add(it) }
                val inputs = mutableMapOf<String, OnnxTensorLike>(
                    "rhythms" to intTensor(rhythm), "pitchs" to intTensor(pitch),
                    "lifts" to intTensor(lift), "articulations" to intTensor(articulation),
                    "slurs" to intTensor(slur), "context" to if (step == 0) context else reduced,
                )
                val cacheLength = OnnxTensor.createTensor(env, LongBuffer.wrap(longArrayOf(step.toLong())), longArrayOf(1))
                scalarInputs.add(cacheLength); inputs["cache_len"] = cacheLength
                for (i in 0 until 32) {
                    inputs["cache_in$i"] = if (previous == null) emptyCache[i]
                        else previous!!.get("cache_out$i").orElseThrow() as OnnxTensor
                }
                val current = try { decoder.run(inputs) } finally { scalarInputs.forEach { it.close() } }
                previous?.close()
                previous = current
                rhythm = argmax(current, "out_rhythms").toLong()
                pitch = argmax(current, "out_pitchs").toLong()
                lift = argmax(current, "out_lifts").toLong()
                val position = argmax(current, "out_positions")
                articulation = argmax(current, "out_articulations").toLong()
                slur = argmax(current, "out_slurs").toLong()
                if (rhythm == 2L) { eos = true; break }
                val attention = (current.get("attention").orElseThrow() as OnnxTensor).floatBuffer
                val x = if (attention.hasRemaining()) attention.get(0) else Float.NaN
                tokens.add(StaffToken(rhythm.toInt(), pitch.toInt(), lift.toInt(), position,
                                      articulation.toInt(), slur.toInt(), x))
            }
        } finally {
            previous?.close()
            emptyCache.forEach { it.close() }
        }
        return DecodeResult(tokens, eos, encoderMs, (System.nanoTime() - start) / 1_000_000)
    }

    override fun close() { decoder.close(); encoder.close() }

    companion object {
        const val WIDTH = 1280
        const val HEIGHT = 256
        private const val ENCODER_HASH = "4c16df852b3789f2676b0d49f0545dab0740e4005f7b472c5252add642f5d5eb"
        private const val DECODER_HASH = "3e10fd5ae52d0b86792721922fcd954c283a7ed365de7446425bdabe38f3e57d"

        private fun verify(file: File, expected: String) {
            require(file.isFile) { "Model not found: ${file.name}" }
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().buffered().use { input ->
                val buffer = ByteArray(1024 * 1024)
                while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            require(actual == expected) { "Model hash mismatch: ${file.name}" }
        }

        private fun argmax(result: OrtSession.Result, name: String): Int {
            val values = (result.get(name).orElseThrow() as OnnxTensor).floatBuffer
            require(values.hasRemaining()) { "Empty output $name" }
            var index = 0; var bestIndex = 0; var best = Float.NEGATIVE_INFINITY
            while (values.hasRemaining()) {
                val value = values.get()
                if (value > best) { best = value; bestIndex = index }
                index++
            }
            return bestIndex
        }
    }
}
