package jp.choiromr.mobile.omr

import kotlin.math.abs
import kotlin.math.roundToInt

data class StaffGeometry(val left: Int, val right: Int, val lines: List<Double>,
                         val spacing: Double, val stripSupport: Int, val inferredLine: Boolean,
                         val profile: List<Pair<Double, Double>> = emptyList()) {
    /**
     * [profile]: (x, vertical offset of the five lines from [lines]) measured
     * along the staff, sorted by x. A tilted or bent staff has a sloped or
     * curved profile; empty means straight at [lines].
     */
    fun offsetAt(x: Double): Double {
        if (profile.isEmpty()) return 0.0
        if (x <= profile.first().first) return profile.first().second
        if (x >= profile.last().first) return profile.last().second
        val i = profile.indexOfLast { it.first <= x }
        val (x0, o0) = profile[i]; val (x1, o1) = profile[i + 1]
        return o0 + (o1 - o0) * (x - x0) / (x1 - x0)
    }

    fun linesAt(x: Double): List<Double> = offsetAt(x).let { o -> lines.map { it + o } }

    /** Overall dy/dx of the staff (least squares over [profile]); 0 when straight. */
    val slope: Double get() {
        if (!bent || profile.size < 2) return 0.0
        val mx = profile.sumOf { it.first } / profile.size; val my = profile.sumOf { it.second } / profile.size
        val sxx = profile.sumOf { (it.first - mx) * (it.first - mx) }
        return if (sxx == 0.0) 0.0 else profile.sumOf { (it.first - mx) * (it.second - my) } / sxx
    }

    /**
     * True when the lines move by half a space or more along the staff
     * (about 0.25 degrees over a full-width staff). Below that the staff is
     * treated exactly as before straightening existed.
     */
    val bent: Boolean get() = profile.isNotEmpty() &&
        profile.maxOf { it.second } - profile.minOf { it.second } >= 0.5 * spacing
}

/**
 * Estimate five-line staves from the segmentation model's staff class.
 * This first implementation is intended for straight or mildly curved scans;
 * it does not yet correct perspective or identify system / piano grouping.
 */
object StaffGeometryDetector {
    /** Recover a clipped left edge only when two nearby staves agree. */
    fun restoreLeft(staff: StaffGeometry, neighbours: List<StaffGeometry>): StaffGeometry {
        val nearby = neighbours.filter {
            val gap = maxOf(it.lines.first() - staff.lines.last(), staff.lines.first() - it.lines.last())
            gap in 0.0..(25 * staff.spacing) && abs(it.right - staff.right) <= 5 * staff.spacing
        }
        for (a in nearby.indices) for (b in a + 1 until nearby.size) {
            val first = nearby[a]
            val second = nearby[b]
            if (abs(first.left - second.left) <= 5 * staff.spacing &&
                abs(first.right - second.right) <= 5 * staff.spacing &&
                staff.left - maxOf(first.left, second.left) > 8 * staff.spacing) {
                return staff.copy(left = minOf(first.left, second.left))
            }
        }
        return staff
    }
    private const val STRIPS = 16
    private data class Peak(val y: Double, val weight: Int)
    private data class Candidate(val strip: Int, val lines: List<Double>)

    fun detect(labels: ByteArray, width: Int, height: Int): List<StaffGeometry> {
        require(width > 0 && height > 0 && width.toLong() * height == labels.size.toLong())
        val peaksByStrip = Array(STRIPS) { mutableListOf<Peak>() }
        for (strip in 0 until STRIPS) {
            val left = strip * width / STRIPS
            val right = (strip + 1) * width / STRIPS
            if (right - left < 24) continue
            val rows = IntArray(height)
            for (y in 0 until height) {
                val start = y * width
                for (x in left until right) if (labels[start + x].toInt() == 4) rows[y]++
            }
            val threshold = maxOf(3, ((right - left) * 0.12).roundToInt())
            var y = 0
            while (y < height) {
                if (rows[y] < threshold) { y++; continue }
                var weightedY = 0.0; var total = 0
                while (y < height && rows[y] >= threshold) {
                    weightedY += y * rows[y].toDouble(); total += rows[y]; y++
                }
                peaksByStrip[strip].add(Peak(weightedY / total, total))
            }
        }
        val distances = IntArray(61)
        for (peaks in peaksByStrip) for (i in 1 until peaks.size) {
            val d = (peaks[i].y - peaks[i - 1].y).roundToInt()
            if (d in 4..60) distances[d]++
        }
        val mode = (4..60).maxByOrNull { distances[it] } ?: return emptyList()
        if (distances[mode] < 4) return emptyList()
        var weight = 0; var total = 0
        for (d in maxOf(4, mode - 1)..minOf(60, mode + 1)) { total += distances[d] * d; weight += distances[d] }
        val spacing = total.toDouble() / weight
        val candidates = mutableListOf<Candidate>()
        for (strip in 0 until STRIPS) {
            val peaks = peaksByStrip[strip]
            var i = 0
            while (i < peaks.size) {
                var j = i
                while (j + 1 < peaks.size && abs(peaks[j + 1].y - peaks[j].y - spacing) <= spacing * 0.3) j++
                var k = i
                while (j - k + 1 >= 4) {
                    val end = minOf(j + 1, k + 5)
                    candidates.add(Candidate(strip, peaks.subList(k, end).map { it.y }))
                    k = end
                }
                i = j + 1
            }
        }
        if (candidates.isEmpty()) return emptyList()
        /** Group strip candidates into staves, comparing heights with [skew] px per strip taken out. */
        fun clusterAll(skew: Double): List<List<Candidate>> {
            val level = candidates.map { c -> Candidate(c.strip, c.lines.map { it - skew * c.strip }) }
            val clusters = mutableListOf<MutableList<Int>>()
            for ((index, candidate) in level.withIndex()) {
                val best = clusters.asSequence().filter { cl -> cl.none { level[it].strip == candidate.strip } }
                    .mapNotNull { members ->
                        val cl = members.map { level[it] }
                        val near = cl.filter { abs(it.strip - candidate.strip) <= 2 }
                        if (near.isNotEmpty()) {
                            val distance = near.minOf { abs(it.lines.first() - candidate.lines.first()) }
                            return@mapNotNull if (distance <= 1.5 * spacing) members to distance else null
                        }
                        // Across a gap of strips (text, a blank): within 3 spaces of any
                        // strip of the cluster, or within 2 of its extrapolated slope.
                        val direct = cl.minOf { abs(it.lines.first() - candidate.lines.first()) }
                        val sloped = abs(predictFirstLine(cl, candidate.strip) - candidate.lines.first())
                        when {
                            direct <= 3 * spacing -> members to minOf(direct, sloped)
                            sloped <= 2 * spacing -> members to sloped
                            else -> null
                        }
                    }.minByOrNull { it.second }?.first
                if (best == null) clusters.add(mutableListOf(index)) else best.add(index)
            }
            return clusters.map { cl -> cl.map { candidates[it] } }
        }
        var clusters = clusterAll(0.0)
        // A tilted page: staves (often packed closely, as in four voices plus
        // piano) drift several spaces across the width, and strips of one staff
        // drift towards the next. Take the page's slope out and group again.
        val slopes = clusters.filter { cl -> cl.map { it.strip }.toSet().size >= 4 }
            .map { cl -> predictFirstLine(cl, 1) - predictFirstLine(cl, 0) }.sorted()
        if (slopes.isNotEmpty()) {
            val skew = slopes[slopes.size / 2]
            if (abs(skew) * STRIPS >= 1.5 * spacing) clusters = clusterAll(skew)
        }
        val maxSupport = clusters.maxOf { it.size }
        val results = mutableListOf<StaffGeometry>()
        for (cluster in clusters) {
            if (cluster.size < maxOf(2.0, maxSupport * 0.4)) continue
            val full = cluster.filter { it.lines.size == 5 }
            val source = if (full.isNotEmpty()) full else cluster
            val lines = (0..4).map { index ->
                val values = source.map { c -> if (index < c.lines.size) c.lines[index] else c.lines.last() + spacing }
                    .sorted()
                if (values.size % 2 == 1) values[values.size / 2]
                else (values[values.size / 2 - 1] + values[values.size / 2]) / 2
            }
            val coarseLeft = cluster.minOf { it.strip } * width / STRIPS
            val coarseRight = (cluster.maxOf { it.strip } + 1) * width / STRIPS
            val profile = profileOf(labels, width, height, lines, spacing, coarseLeft, coarseRight)
            val shape = StaffGeometry(0, width, lines, spacing, cluster.size, full.isEmpty(), profile)
            val (left, right) = refineExtent(labels, width, height, shape, spacing, coarseLeft, coarseRight)
            results.add(shape.copy(left = left, right = right))
        }
        // Two staves sharing lines (or with less than a space between them) are
        // one staff found twice, e.g. strips whose groups start a line off;
        // real staves are separated by two spaces or more.
        return results.sortedBy { it.lines.first() }.fold(mutableListOf()) { out, staff ->
            if (out.isNotEmpty() && staff.lines.first() <= out.last().lines.last() + staff.spacing * 1.0) {
                if (staff.stripSupport > out.last().stripSupport) out[out.lastIndex] = staff
            } else out.add(staff)
            out
        }
    }

    /** First line of [cluster] extrapolated to [strip] by a least-squares line over its strips. */
    private fun predictFirstLine(cluster: List<Candidate>, strip: Int): Double {
        val xs = cluster.map { it.strip.toDouble() }; val ys = cluster.map { it.lines.first() }
        val mx = xs.average(); val my = ys.average()
        val sxx = xs.sumOf { (it - mx) * (it - mx) }
        if (sxx == 0.0) return ys.last()
        val slope = xs.indices.sumOf { (xs[it] - mx) * (ys[it] - my) } / sxx
        return my + slope * (strip - mx)
    }

    /**
     * Vertical offset of the five median lines in each strip: the shift that
     * best covers staff-class rows there. Measured from the middle of the
     * staff outwards, each strip within 0.6 spaces of its neighbour, so a
     * strip whose peaks include a ledger line or beam (one line off, which
     * matches only four lines) cannot make the staff jump.
     */
    private fun profileOf(labels: ByteArray, width: Int, height: Int, lines: List<Double>, spacing: Double,
                          coarseLeft: Int, coarseRight: Int): List<Pair<Double, Double>> {
        val strips = (0 until STRIPS).filter { s ->
            val l = s * width / STRIPS; val r = (s + 1) * width / STRIPS
            r > coarseLeft && l < coarseRight && r - l >= 24
        }
        if (strips.size < 2) return emptyList()
        fun shiftIn(strip: Int, expected: Int, range: Int): Int? {
            val l = strip * width / STRIPS; val r = (strip + 1) * width / STRIPS
            val y0 = maxOf(0, (lines.first() + expected - range - 2).toInt())
            val y1 = minOf(height - 1, (lines.last() + expected + range + 2).toInt() + 1)
            val rows = DoubleArray(y1 - y0 + 1)
            for (y in y0..y1) {
                var n = 0
                for (x in l until r) if (labels[y * width + x].toInt() == 4) n++
                rows[y - y0] = n.toDouble() / (r - l)
            }
            fun at(y: Int) = if (y < y0 || y > y1) 0.0 else rows[y - y0]
            var best = -1.0; var bestD = expected
            for (d in expected - range..expected + range) {
                val s = lines.sumOf { v -> val y = (v + d).roundToInt(); maxOf(at(y - 1), maxOf(at(y), at(y + 1))) } -
                    0.001 * abs(d - expected)
                if (s > best) { best = s; bestD = d }
            }
            return if (best / 5 >= 0.3) bestD else null
        }
        val centre = (coarseLeft + coarseRight) / 2.0
        val start = strips.minBy { abs((it + 0.5) * width / STRIPS - centre) }
        val first = shiftIn(start, 0, (2 * spacing).roundToInt()) ?: return emptyList()
        val step = (0.6 * spacing).roundToInt().coerceAtLeast(1)
        val shifts = sortedMapOf(start to first)
        for (direction in listOf(-1, 1)) {
            var previous = first
            for (strip in strips.filter { (it - start) * direction > 0 }.sortedBy { abs(it - start) }) {
                val d = shiftIn(strip, previous, step) ?: continue
                shifts[strip] = d
                previous = d
            }
        }
        return shifts.map { (strip, d) -> (strip + 0.5) * width / STRIPS to d.toDouble() }
    }

    private fun refineExtent(labels: ByteArray, width: Int, height: Int, shape: StaffGeometry, spacing: Double,
                             coarseLeft: Int, coarseRight: Int): Pair<Int, Int> {
        val lo = maxOf(0, coarseLeft - (2 * spacing).toInt())
        val hi = minOf(width, coarseRight + (2 * spacing).toInt())
        val occupied = BooleanArray(width)
        fun staffAt(x: Int, lines: List<Double>): Boolean {
            val top = maxOf(0, (lines.first() - spacing).toInt())
            val bottom = minOf(height, (lines.last() + spacing + 1).toInt())
            var count = 0
            for (y in top until bottom) if (labels[y * width + x].toInt() == 4 && ++count >= 2) return true
            return false
        }
        for (x in lo until hi) {
            // A tilted staff leaves the median lines at its ends: also follow its
            // own slope (never narrower than the median lines alone).
            occupied[x] = staffAt(x, shape.lines) || (shape.bent && staffAt(x, shape.linesAt(x.toDouble())))
        }
        var bestStart = -1; var bestEnd = -1; var currentStart = -1; var lastInk = -1
        val maxGap = spacing.roundToInt().coerceAtLeast(1)
        for (x in lo until hi) {
            if (!occupied[x]) continue
            if (currentStart < 0 || x - lastInk > maxGap + 1) {
                if (lastInk - currentStart > bestEnd - bestStart) { bestStart = currentStart; bestEnd = lastInk }
                currentStart = x
            }
            lastInk = x
        }
        if (lastInk - currentStart > bestEnd - bestStart) { bestStart = currentStart; bestEnd = lastInk }
        return if (bestStart >= 0 && bestEnd > bestStart) bestStart to (bestEnd + 1) else coarseLeft to coarseRight
    }
}
