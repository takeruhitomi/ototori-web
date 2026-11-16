/*
 * Experimental Android port of the homr 0.7.0 segmentation protocol.
 * homr is Copyright (c) Christian Liebhardt and contributors, AGPL-3.0.
 * See apps/choir_mobile/third_party/homr/NOTICE.md and LICENSE.
 */
package jp.choiromr.mobile.omr

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.File
import java.nio.FloatBuffer
import java.security.MessageDigest

/** Pixel classes: background=0, stems/rests=1, notehead=2, clefs/keys=3,
 * staff=4, other symbols=5. This is not yet staff detection or recognition. */
data class SegmentationResult(val labels: ByteArray, val patches: Int, val inferenceMillis: Long)

/** Single-threaded, CPU segmentation. Input is an already preprocessed grayscale page. */
class PageSegmentation(modelFile: File, threads: Int = 2) : AutoCloseable {
    private val env = OrtEnvironment.getEnvironment()
    private val model: OrtSession

    init {
        require(threads in 1..16)
        require(modelFile.isFile) { "Segmentation model not found" }
        val digest = MessageDigest.getInstance("SHA-256")
        modelFile.inputStream().buffered().use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        require(actual == MODEL_HASH) { "Segmentation model hash mismatch" }
        OrtSession.SessionOptions().use { options ->
            options.setIntraOpNumThreads(threads)
            options.setInterOpNumThreads(1)
            model = env.createSession(modelFile.absolutePath, options)
        }
    }

    fun segment(gray: ByteArray, width: Int, height: Int,
                cancelled: () -> Boolean = { false }): SegmentationResult {
        require(width > 0 && height > 0 && width.toLong() * height <= 16_000_000L)
        require(gray.size == width * height)
        // Match homr's overlapping boundary patches and integer-class averaging.
        val sums = ShortArray(gray.size)
        val counts = ByteArray(gray.size)
        val started = System.nanoTime()
        var patches = 0
        for (row in 0 until maxOf(height, WINDOW) step WINDOW) {
            val y = minOf(row, height - WINDOW)
            for (column in 0 until maxOf(width, WINDOW) step WINDOW) {
                if (cancelled()) throw InterruptedException("Segmentation cancelled")
                val x = minOf(column, width - WINDOW)
                val x0 = maxOf(0, x); val y0 = maxOf(0, y)
                val x1 = minOf(width, x + WINDOW); val y1 = minOf(height, y + WINDOW)
                val patch = FloatArray(3 * WINDOW * WINDOW) { 255f }
                for (py in 0 until y1 - y0) {
                    for (px in 0 until x1 - x0) {
                        val value = (gray[(y0 + py) * width + x0 + px].toInt() and 255).toFloat()
                        val index = py * WINDOW + px
                        patch[index] = value; patch[WINDOW * WINDOW + index] = value
                        patch[2 * WINDOW * WINDOW + index] = value
                    }
                }
                OnnxTensor.createTensor(env, FloatBuffer.wrap(patch), longArrayOf(1, 3, 320, 320)).use { tensor ->
                    model.run(mapOf("input" to tensor)).use { output ->
                        val logits = (output.get("output").orElseThrow() as OnnxTensor).floatBuffer
                        require(logits.remaining() == 6 * WINDOW * WINDOW)
                        for (py in 0 until y1 - y0) {
                            for (px in 0 until x1 - x0) {
                                val index = py * WINDOW + px
                                var best = Float.NEGATIVE_INFINITY; var label = 0
                                for (c in 0 until 6) {
                                    val value = logits.get(c * WINDOW * WINDOW + index)
                                    if (value > best) { best = value; label = c }
                                }
                                val destination = (y0 + py) * width + x0 + px
                                sums[destination] = (sums[destination] + label).toShort()
                                counts[destination] = (counts[destination] + 1).toByte()
                            }
                        }
                    }
                }
                patches++
            }
        }
        val labels = ByteArray(gray.size) { i ->
            val count = counts[i].toInt() and 255
            if (count == 0) 0 else (sums[i].toInt() / count).toByte()
        }
        return SegmentationResult(labels, patches, (System.nanoTime() - started) / 1_000_000)
    }

    override fun close() = model.close()

    companion object {
        private const val WINDOW = 320
        private const val MODEL_HASH = "6ed36640db4ef5d223098b6d5efe4eda97c66b24a2c72faab8a018c749003a8d"
    }
}
