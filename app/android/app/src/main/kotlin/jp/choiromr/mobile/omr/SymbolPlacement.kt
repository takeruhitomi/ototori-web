package jp.choiromr.mobile.omr

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** One recognised token of a staff: model strings plus the attention x in page pixels. */
data class PlacedToken(val rhythm: String, val pitch: String, val x: Double?)

/**
 * Position of a token on the page (1920-wide page pixels).
 * [confidence] 0..1 says how well the image confirms it; [snapped] is true
 * when x (and y for notes) was moved onto the barline / notehead found in the
 * image, false when it is only the decoder's attention estimate.
 * [lines] (top to bottom) are the staff line heights measured at [x]; given
 * for barlines and for the start of the staff.
 */
data class TokenPlace(val x: Double, val y: Double?, val confidence: Double, val snapped: Boolean,
                      val lines: List<Double>? = null) {
    fun toList(): List<Any?> = listOf(r1(x), y?.let { r1(it) }, Math.round(confidence * 100) / 100.0,
        snapped) + (lines?.map { r1(it) } ?: emptyList())
    private fun r1(v: Double) = Math.round(v * 10) / 10.0
}

/**
 * Snaps recognised tokens onto the page image.
 *
 * - Staff lines are measured at the start of the staff and at every barline
 *   (heights of the five lines there), so a tilted or slightly bent staff is
 *   followed bar by bar; between two barlines the lines are interpolated in
 *   a straight line.
 * - Barlines snap to the nearest full-height vertical line.
 * - A note's height comes from its pitch, the clef and the local lines; its
 *   x snaps to the notehead found at that height (filled or hollow).
 *
 * [mask] is 1 for ink. Pure Kotlin for JVM tests.
 */
object SymbolPlacement {
    private val BARLINES = setOf("barline", "doublebarline", "bolddoublebarline", "repeatStart", "repeatEnd", "repeatEndStart")

    fun place(mask: ByteArray, width: Int, height: Int, lines: List<Double>, left: Int, right: Int,
              tokens: List<PlacedToken>): List<TokenPlace?> {
        require(mask.size == width * height)
        if (lines.size != 5 || tokens.isEmpty()) return tokens.map { null }
        val model = LineModel(mask, width, height, lines, left, right)
        // 1. Staff lines at the start and at each barline (attention x first).
        // Measuring starts near the middle of the staff (where the detected
        // lines are) and walks outwards, so a tilt accumulates gradually.
        val start = left + model.sp
        val end = right - model.sp
        val bars = tokens.indices.filter { tokens[it].rhythm in BARLINES && tokens[it].x != null }
        model.measureAll(listOf(start, end) + bars.map { tokens[it].x!! })
        // 2. Barlines snap to the vertical line; re-measure the lines there.
        val out = arrayOfNulls<TokenPlace>(tokens.size)
        val snappedBars = mutableListOf<Double>()
        for (i in bars) {
            val x = tokens[i].x!!
            var (bx, conf) = snapBarline(mask, width, height, model.at(x), x, model.sp, left, right)
            // The decoder places the final barline well before the staff end;
            // the staff's right edge is where it must be.
            if (bx == null && i == bars.last()) {
                val (ex, econf) = snapBarline(mask, width, height, model.at(right.toDouble()), right - 1.0, model.sp, left, right)
                if (ex != null && abs(ex - right) <= 1.5 * model.sp) { bx = ex; conf = econf }
            }
            snappedBars.add(bx ?: x)
            out[i] = TokenPlace(bx ?: x, null, conf, bx != null)
        }
        model.reset()
        model.measureAll(listOf(start, end) + snappedBars)
        for (i in bars) { val p = out[i]!!; out[i] = p.copy(lines = model.at(p.x)) }
        // 3. Notes (pitch + clef -> height), rests, and the staff start.
        var bottomLine = diatonic("E4")!!
        var startGiven = false
        // Token order says which bar a note is in: search between its barlines.
        // It also says which chord comes first: a chord's heads lie right of
        // the previous chord's, so the search starts after the leftmost head
        // the previous chord snapped to (a repeated note cannot take its
        // neighbour's head).
        val barX = bars.associateWith { out[it]!!.x }
        var previous: Double? = null  // leftmost snapped head of the last chord in this bar
        var chordMin: Double? = null  // the same for the chord being placed
        for ((i, t) in tokens.withIndex()) {
            val before = bars.lastOrNull { it < i }?.let { barX.getValue(it) } ?: left.toDouble()
            val after = bars.firstOrNull { it > i }?.let { barX.getValue(it) } ?: right.toDouble()
            val timed = t.rhythm.startsWith("note_") || t.rhythm.startsWith("rest_")
            if (t.rhythm in BARLINES) { previous = null; chordMin = null }
            else if (timed && !(i > 0 && tokens[i - 1].rhythm == "chord")) {
                // A new chord (its members follow a "chord" token).
                if (chordMin != null) previous = chordMin
                chordMin = null
            }
            when {
                t.rhythm.startsWith("clef_") -> {
                    clefBottom(t.rhythm)?.let { bottomLine = it }
                    // The first clef stands for the start of the staff (its left edge).
                    if (!startGiven) { out[i] = TokenPlace(left.toDouble(), null, 1.0, true, model.at(start)); startGiven = true }
                }
                t.rhythm.startsWith("note_") && t.x != null -> {
                    val step = diatonic(t.pitch)?.let { it - bottomLine }
                    // snapNote keeps 0.4 space from `before`: heads at least 0.6 space apart.
                    val prev = previous
                    val from = if (prev != null && prev > before) max(before, prev + 0.2 * model.sp) else before
                    val placed = if (step == null) TokenPlace(t.x, null, 0.0, false)
                        else snapNote(mask, width, height, model, t.x, step, hollow(t.rhythm), t.rhythm.contains('G'), from, after)
                    out[i] = placed
                    if (placed.snapped && (chordMin == null || placed.x < chordMin!!)) chordMin = placed.x
                }
                t.rhythm.startsWith("rest_") && t.x != null -> out[i] = TokenPlace(t.x, null, 0.0, false)
            }
        }
        return out.toList()
    }

    /** Staff lines measured at several x, interpolated in straight lines between them. */
    private class LineModel(val mask: ByteArray, val width: Int, val height: Int, val base: List<Double>,
                            val left: Int, val right: Int) {
        val sp = (base[4] - base[0]) / 4
        private val points = sortedMapOf<Double, List<Double>>()

        fun reset() = points.clear()

        fun at(x: Double): List<Double> {
            if (points.isEmpty()) return base
            val lower = points.headMap(x + 1e-9).let { if (it.isEmpty()) null else it.lastKey() }
            val upper = points.tailMap(x).let { if (it.isEmpty()) null else it.firstKey() }
            if (lower == null) return points.getValue(upper!!)
            if (upper == null || upper == lower) return points.getValue(lower)
            val t = (x - lower) / (upper - lower)
            val a = points.getValue(lower); val b = points.getValue(upper)
            return a.indices.map { a[it] + t * (b[it] - a[it]) }
        }

        /** Measure at [xs], each guessed from the nearest measured point (tilt allowance grows with distance). */
        fun measureAll(xs: List<Double>) {
            val pending = xs.filter { it >= left && it <= right }.toMutableList()
            while (pending.isNotEmpty()) {
                val next = if (points.isEmpty()) pending.minBy { abs(it - (left + right) / 2.0) }
                    else pending.minBy { x -> points.keys.minOf { abs(it - x) } }
                pending.remove(next)
                measure(next)
            }
        }

        fun measure(x: Double) {
            val nearest = points.keys.minByOrNull { abs(it - x) }
            val guess = if (nearest == null) base else points.getValue(nearest)
            val range = if (nearest == null) 2.0 * sp else min(2.5 * sp, 0.4 * sp + 0.07 * abs(x - nearest))
            points[x] = fit(x, guess, range) ?: return
        }

        /** Best vertical shift of the five lines in a narrow window, then each line refined. */
        private fun fit(x: Double, guess: List<Double>, range: Double): List<Double>? {
            val half = (1.5 * sp).roundToInt().coerceAtLeast(3)
            val x0 = max(max(0, left), x.roundToInt() - half); val x1 = min(min(width, right), x.roundToInt() + half)
            if (x1 - x0 < 3) return null
            val yLo = max(0, (guess[0] - range - sp).toInt()); val yHi = min(height - 1, (guess[4] + range + sp).toInt() + 1)
            if (yHi <= yLo) return null
            val ink = DoubleArray(yHi - yLo + 1)
            for (y in yLo..yHi) {
                var c = 0
                for (xx in x0 until x1) if (mask[y * width + xx].toInt() != 0) c++
                ink[y - yLo] = c.toDouble() / (x1 - x0)
            }
            fun rowInk(y: Int) = if (y < yLo || y > yHi) 0.0 else ink[y - yLo]
            fun near(y: Double) = max(rowInk(y.roundToInt() - 1), max(rowInk(y.roundToInt()), rowInk(y.roundToInt() + 1)))
            var bestD = 0; var best = -1.0
            val r = range.roundToInt()
            for (d in -r..r) {
                val s = guess.sumOf { near(it + d) } - 0.002 * abs(d)
                if (s > best) { best = s; bestD = d }
            }
            if (best / 5 < 0.4) return null  // no staff lines here (text, a gap)
            return guess.map { g ->
                val c = g + bestD
                val lo = (c - 0.3 * sp).roundToInt(); val hi = (c + 0.3 * sp).roundToInt()
                val peak = (lo..hi).maxOf { rowInk(it) }
                var sw = 0.0; var sy = 0.0
                for (y in lo..hi) { val v = rowInk(y); if (v >= 0.6 * peak) { sw += v; sy += v * y } }
                if (sw > 0) sy / sw else c
            }
        }
    }

    /** Nearest full-height vertical line to [x]: (x or null, confidence). */
    private fun snapBarline(mask: ByteArray, width: Int, height: Int, lines: List<Double>, x: Double, sp: Double,
                            left: Int, right: Int): Pair<Double?, Double> {
        val top = max(0, lines[0].roundToInt()); val bottom = min(height - 1, lines[4].roundToInt())
        if (bottom <= top) return null to 0.0
        val c0 = max(max(0, left - 1), (x - 2.5 * sp).toInt()); val c1 = min(min(width - 1, right + 1), (x + 3.5 * sp).toInt())
        val fill = DoubleArray(max(0, c1 - c0 + 1)) { k ->
            val c = c0 + k
            var n = 0
            for (y in top..bottom) {
                // Tolerate a pixel of skew: ink in this or a neighbouring column.
                if (mask[y * width + c].toInt() != 0 || (c > 0 && mask[y * width + c - 1].toInt() != 0) ||
                    (c + 1 < width && mask[y * width + c + 1].toInt() != 0)) n++
            }
            n.toDouble() / (bottom - top + 1)
        }
        val runs = mutableListOf<Pair<Int, Int>>()
        var k = 0
        while (k < fill.size) {
            if (fill[k] < 0.92) { k++; continue }
            val s = k
            while (k < fill.size && fill[k] >= 0.92) k++
            if (k - s <= 1.2 * sp + 2) runs.add(s to k - 1)
        }
        if (runs.isEmpty()) return null to 0.0
        val centers = runs.map { (s, e) -> c0 + (s + e) / 2.0 }
        val best = centers.minBy { abs(it - x) }
        val strong = runs[centers.indexOf(best)].let { (s, e) -> (s..e).maxOf { fill[it] } >= 0.97 }
        val conf = when {
            centers.count { abs(it - best) > 0.8 * sp } > 0 -> 0.6  // several lines within reach
            strong -> 1.0
            else -> 0.8
        }
        return best to conf
    }

    private fun hollow(rhythm: String): Boolean {
        val code = rhythm.removePrefix("note_").replace("G", "").trimEnd('.')
        return code == "1" || code == "2" || code == "0"
    }

    private fun snapNote(mask: ByteArray, width: Int, height: Int, model: LineModel, attention: Double, step: Int,
                         hollow: Boolean, grace: Boolean, before: Double, after: Double): TokenPlace {
        val sp0 = model.sp
        // Keep the search inside the bar; an estimate outside it is moved in.
        val lo = before + 0.4 * sp0; val hi = after - 0.4 * sp0
        val x = if (hi <= lo) attention else attention.coerceIn(lo, hi)
        val lines = model.at(x)
        val sp = (lines[4] - lines[0]) / 4
        val y = lines[4] - step * sp / 2
        val scale = if (grace) 0.7 else 1.0
        val reach = if (x != attention) 4.0 else 2.0
        var from = (x - reach * sp).toInt(); var to = (x + reach * sp).toInt()
        if (hi > lo) { from = max(from, lo.toInt()); to = min(to, hi.toInt()) }
        from = max(0, from); to = min(width - 1, to)
        var bestX = x; var bestY = y; var peak = -1.0
        val profile = mutableListOf<Double>()
        val ys = mutableListOf<Double>()
        for (cx in from..to) {
            var colBest = -1.0; var colY = y
            for (dy in listOf(0.0, -0.15 * sp, 0.15 * sp)) {
                val s = headScore(mask, width, height, cx.toDouble(), y + dy, sp * scale, hollow)
                if (s > colBest) { colBest = s; colY = y + dy }
            }
            profile.add(colBest); ys.add(colY)
            if (colBest > peak) { peak = colBest; bestX = cx.toDouble(); bestY = colY }
        }
        if (peak < 0) return TokenPlace(x, y, 0.0, false)
        val (low, high) = if (hollow) 0.3 to 0.65 else 0.4 to 0.85
        // Of the heads in reach that would count as found, the one nearest the
        // decoder's x: with repeated notes the strongest is often the neighbour's.
        val enough = low + 0.5 * (high - low)
        var near = -1
        for (k in profile.indices) {
            val s = profile[k]
            if (s < enough || (k > 0 && profile[k - 1] > s) || (k + 1 < profile.size && profile[k + 1] >= s)) continue
            if (near < 0 || abs(from + k - x) < abs(from + near - x)) near = k
        }
        val chosen = if (near >= 0) profile[near] else peak
        if (near >= 0) { bestX = (from + near).toDouble(); bestY = ys[near] }
        var conf = ((chosen - low) / (high - low)).coerceIn(0.0, 1.0)
        // A beam or a long line at this height scores everywhere: not a head.
        val typical = profile.sorted()[profile.size / 2]
        if (typical > 0.7 * chosen) conf *= 0.5
        return if (conf >= 0.5) TokenPlace(bestX, bestY, conf, true) else TokenPlace(x, y, conf, false)
    }

    /**
     * Ink inside a notehead-sized ellipse (filled) or in its rim (hollow),
     * the weaker of the left and right halves: a head is inked on both
     * sides, while a stem, barline or accidental beside it fills only one.
     */
    private fun headScore(mask: ByteArray, width: Int, height: Int, cx: Double, cy: Double, sp: Double, hollow: Boolean): Double {
        val rx = 0.6 * sp; val ry = 0.48 * sp
        val ink = IntArray(4); val total = IntArray(4)  // [core left, core right, rim left, rim right]
        for (yy in (cy - ry).toInt()..(cy + ry).toInt() + 1) {
            if (yy < 0 || yy >= height) continue
            for (xx in (cx - rx).toInt()..(cx + rx).toInt() + 1) {
                if (xx < 0 || xx >= width) continue
                val dx = (xx - cx) / rx; val dy = (yy - cy) / ry
                if (dx * dx + dy * dy > 1.0) continue
                val core = (dx / 0.75) * (dx / 0.75) + (dy / 0.72) * (dy / 0.72) <= 1.0
                val k = (if (core) 0 else 2) + (if (dx < 0) 0 else 1)
                total[k]++
                if (mask[yy * width + xx].toInt() != 0) ink[k]++
            }
        }
        if (total.any { it == 0 }) return 0.0
        val f = DoubleArray(4) { ink[it].toDouble() / total[it] }
        return if (hollow) min(f[2], f[3]) else min(f[0], f[1])
    }

    private const val LETTERS = "CDEFGAB"

    /** Diatonic step number of "C5" etc. */
    fun diatonic(pitch: String): Int? {
        val m = Regex("^([A-G])(\\d)$").find(pitch) ?: return null
        return m.groupValues[2].toInt() * 7 + LETTERS.indexOf(m.groupValues[1][0])
    }

    /** Diatonic step of the bottom staff line for a clef token (clef_G2, clef_F4, clef_C3, ...). */
    fun clefBottom(rhythm: String): Int? {
        val m = Regex("^clef_([GFC])(\\d)").find(rhythm) ?: return null
        val line = m.groupValues[2].toInt()
        val clefPitch = when (m.groupValues[1]) { "G" -> diatonic("G4")!!; "F" -> diatonic("F3")!!; else -> diatonic("C4")!! }
        return clefPitch - 2 * (line - 1)
    }
}
