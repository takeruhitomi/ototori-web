package jp.choiromr.mobile

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioLimiterTest {
    private val rate = 44100
    private val delay = (rate * 0.002).toInt()

    private fun chord(i: Int, voices: List<Double>, level: Double) =
        voices.sumOf { sin(2 * PI * it * i / rate) } * level

    @Test fun quietMusicPassesUnchangedOnlyDelayed() {
        val limiter = AudioLimiter(rate)
        val input = DoubleArray(rate) { sin(2 * PI * 220.0 * it / rate) * 0.8 }
        val out = DoubleArray(rate) { limiter.process(input[it]) }
        for (i in 0 until rate - delay) assertEquals(input[i], out[i + delay], 1e-12)
        assertEquals(1.0, limiter.gain, 0.0)
    }

    @Test fun loudChordStaysInRangeAndTheGainMovesSmoothly() {
        val limiter = AudioLimiter(rate)
        // Bass to soprano plus piano: about six times the single-voice level.
        val voices = listOf(98.0, 196.0, 246.9, 293.7, 392.0, 493.9, 587.3)
        val gains = DoubleArray(rate)
        val out = DoubleArray(rate) { val v = limiter.process(chord(it, voices, 0.9)); gains[it] = limiter.gain; v }
        assertTrue(out.all { abs(it) <= 1.25 })
        // Settled: at most a touch into the soft knee, far from the ceiling.
        val settled = out.copyOfRange(rate / 10, rate).maxOf { abs(it) }
        assertTrue("settled peak $settled", settled <= 1.03)
        // No sudden steps in the gain after the onset: a buzz would show as
        // the gain jumping within a waveform period.
        var step = 0.0
        for (i in rate / 10 + 1 until rate) step = maxOf(step, abs(gains[i] - gains[i - 1]))
        assertTrue("gain step $step", step < 0.003)
    }

    @Test fun levelRecoversAfterLoudPassage() {
        val limiter = AudioLimiter(rate)
        repeat(rate / 2) { limiter.process(chord(it, listOf(110.0, 220.0, 330.0, 440.0), 1.0)) }
        val quiet = DoubleArray(2 * rate) { limiter.process(sin(2 * PI * 440.0 * it / rate) * 0.5) }
        assertEquals(0.5, quiet.copyOfRange(rate * 3 / 2, 2 * rate).maxOf { abs(it) }, 0.01)
    }
}
