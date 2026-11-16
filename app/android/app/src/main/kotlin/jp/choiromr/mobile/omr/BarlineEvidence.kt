package jp.choiromr.mobile.omr

import kotlin.math.abs
import kotlin.math.roundToInt

/** Image evidence for retrying inference, never a source of invented measures. */
object BarlineEvidence {
    fun corroboratedEnds(gray: ByteArray, width: Int, height: Int, staff: StaffGeometry,
                         before: StaffGeometry?, after: StaffGeometry?): List<Int> {
        if (before == null || after == null) return emptyList()
        val spacing = staff.spacing
        if (before.lines.last() >= staff.lines.first() || after.lines.first() <= staff.lines.last() ||
            staff.lines.first() - before.lines.last() > 20 * spacing ||
            after.lines.first() - staff.lines.last() > 20 * spacing ||
            listOf(before, after).any {
                abs(it.left - staff.left) > 5 * spacing || abs(it.right - staff.right) > 5 * spacing
            }) return emptyList()
        val preceding = verticals(gray, width, height, before)
        val following = verticals(gray, width, height, after)
        val tolerance = maxOf(3.0, spacing * 0.6)
        val agreed = verticals(gray, width, height, staff).filter { x ->
            x > staff.left + 5 * spacing &&
                preceding.any { abs(it - x) <= tolerance } &&
                following.any { abs(it - x) <= tolerance }
        }
        // Collapse the two strokes of a double/final barline.
        val ends = mutableListOf<Int>()
        for (x in agreed) {
            if (ends.isNotEmpty() && x - ends.last() < 1.2 * spacing) ends[ends.lastIndex] = x
            else ends.add(x)
        }
        if (ends.size !in 2..32 || staff.right - ends.last() > 3 * spacing) return emptyList()
        return ends
    }

    private fun verticals(gray: ByteArray, width: Int, height: Int, staff: StaffGeometry): List<Int> {
        require(width.toLong() * height == gray.size.toLong())
        val top = (staff.lines.first() + staff.spacing * 0.65).roundToInt().coerceIn(0, height - 1)
        val bottom = (staff.lines.last() - staff.spacing * 0.65).roundToInt().coerceIn(top + 1, height)
        val peaks = mutableListOf<Int>()
        for (x in maxOf(1, staff.left) until minOf(width - 1, staff.right + 1)) {
            var dark = 0
            for (y in top until bottom) {
                val offset = y * width + x
                if ((-1..1).any { (gray[offset + it].toInt() and 255) < 130 }) dark++
            }
            if (dark.toDouble() / (bottom - top) >= 0.82) peaks.add(x)
        }
        val result = mutableListOf<Int>()
        var start = 0
        while (start < peaks.size) {
            var end = start
            while (end + 1 < peaks.size && peaks[end + 1] - peaks[end] <= 3) end++
            if (peaks[end] - peaks[start] <= maxOf(5.0, 1.5 * staff.spacing)) {
                result.add((peaks[start] + peaks[end]) / 2)
            }
            start = end + 1
        }
        return result
    }

    /** Count only populated measures, with the same lower-staff filter as Dart. */
    fun measureCount(symbols: List<NamedSymbol>): Int {
        var populated = false
        var count = 0
        for (symbol in symbols) {
            if (symbol.rhythm.endsWith("barline")) {
                if (populated) count++
                populated = false
            } else if (symbol.position != "lower" &&
                (symbol.rhythm.startsWith("note_") || symbol.rhythm.startsWith("rest_"))) {
                populated = true
            }
        }
        return count + if (populated) 1 else 0
    }
}
