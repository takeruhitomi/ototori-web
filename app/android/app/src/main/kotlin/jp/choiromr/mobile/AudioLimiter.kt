package jp.choiromr.mobile

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.tanh

/**
 * Keeps the summed voices inside the output range without clipping.
 *
 * Summing many notes (four parts plus piano chords) can exceed full scale;
 * cutting the wave tops off is heard as buzzing. Instead the level is turned
 * down smoothly. The output is delayed by a short look-ahead so the gain has
 * already come down when a peak arrives, and a peak follower holds each peak
 * for longer than one period of a low note before recovering slowly, so the
 * gain does not wobble with the waveform. A soft knee catches any remainder.
 */
class AudioLimiter(rate: Int, private val threshold: Double = 1.0, private val ceiling: Double = 1.25) {
    private val lookahead = maxOf(1, (rate * 0.002).toInt())
    private val delay = DoubleArray(lookahead)
    private var at = 0
    private val hold = (rate * 0.035).toInt()
    private val release = exp(-1.0 / (rate * 0.35))
    private val attack = exp(-3.0 / lookahead)
    private var peak = 0.0
    private var held = 0
    /** Current gain (1 = untouched). */
    var gain = 1.0
        private set

    /** Takes the next input sample and returns the output [lookahead] samples behind it. */
    fun process(value: Double): Double {
        val level = abs(value)
        if (level >= peak) { peak = level; held = hold }
        else if (held > 0) held--
        else peak = maxOf(level, peak * release)
        val target = if (peak > threshold) threshold / peak else 1.0
        gain = if (target < gain) target + (gain - target) * attack else target
        val out = delay[at]
        delay[at] = value
        at = (at + 1) % lookahead
        return softClip(out * gain)
    }

    private fun softClip(v: Double): Double {
        val a = abs(v)
        if (a <= threshold) return v
        val room = ceiling - threshold
        val shaped = threshold + room * tanh((a - threshold) / room)
        return if (v < 0) -shaped else shaped
    }
}
