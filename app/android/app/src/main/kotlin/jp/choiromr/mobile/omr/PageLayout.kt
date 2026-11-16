package jp.choiromr.mobile.omr

import kotlin.math.max
import kotlin.math.min

/**
 * One staff as seen by the layout analysis (page pixels). [profile]: (x,
 * vertical offset from [lines]) along a tilted or bent staff (see
 * [StaffGeometry.profile]); empty for a straight staff.
 */
data class LayoutStaff(val lines: List<Double>, val left: Int, val right: Int,
                       val profile: List<Pair<Double, Double>> = emptyList()) {
    private val shape = StaffGeometry(left, right, lines, if (lines.size == 5) (lines[4] - lines[0]) / 4 else 1.0, 0, false, profile)

    /** Offset of the lines at [x]; 0 for a straight staff (see [StaffGeometry.bent]). */
    fun offsetAt(x: Double): Double = if (shape.bent) shape.offsetAt(x) else 0.0

    /** Overall dy/dx of a tilted staff (0 when straight): how much vertical strokes lean. */
    val slope: Double get() = shape.slope
}

/** A system: staff indices into the page's staves sorted top to bottom. */
data class LayoutSystem(val staves: List<Int>, val pianoPair: Pair<Int, Int>?, val pianoExtra: Int?) {
    val hasBrace: Boolean get() = pianoPair != null
    fun toMap(): Map<String, Any> = buildMap {
        put("staves", staves)
        put("has_brace", hasBrace)
        pianoPair?.let { put("piano_pair", listOf(it.first, it.second)) }
        pianoExtra?.let { put("piano_extra", it) }
    }
}

/** [places]: per staff (input order), per token, its position on the page (see [SymbolPlacement]). */
data class PageLayoutResult(val systems: List<LayoutSystem>, val dropped: List<Int>, val lineInk: List<Double>,
                            val places: List<List<TokenPlace?>>? = null)

/**
 * Image rules of the browser version (choir_omr/systems.py) applied to the
 * staves found by the segmentation model; mirrored by
 * scripts/mobile_layout_reference.py.
 *
 * 1. A staff whose five lines are mostly not ink in the binarised page is a
 *    false staff (show-through, a cue staff over part of the width): dropped.
 * 2. A vertical ink line at the left end joins neighbouring staves into one
 *    system (system barline, bracket, brace); indented staves may join the
 *    system below; without any connection the gap heuristic is used.
 * 3. A brace in the left margin over two staves marks the piano pair, over
 *    the bottom three staves a three-staff piano.
 *
 * [mask] is 1 for ink (see [StaffCanvas.inkMask]). Pure Kotlin for JVM tests.
 */
object PageLayout {
    const val MIN_LINE_INK = 0.5
    private const val SYSTEM_GAP_RATIO = 1.6
    private const val INDENT_RATIO = 0.25
    private const val INDENT_GAP_RATIO = 1.5
    private const val MIN_FILL = 0.85

    /** [slope]: overall dy/dx of the staff (0 for a straight staff). */
    private class Box(val index: Int, val y0: Int, val y1: Int, val x0: Int, val x1: Int, val spacing: Double, val center: Double,
                      val slope: Double = 0.0) {
        val height get() = y1 - y0
    }

    /** Python `round` (half to even), as the reference implementation. */
    private fun pyRound(v: Double): Int = Math.rint(v).toInt()

    fun analyze(mask: ByteArray, width: Int, height: Int, staves: List<LayoutStaff>): PageLayoutResult {
        require(width > 0 && height > 0 && mask.size == width * height)
        val order = staves.indices.sortedBy { staves[it].lines.firstOrNull() ?: 0.0 }
        val ink = DoubleArray(staves.size)
        for (i in staves.indices) {
            val s = staves[i]
            ink[i] = if (s.lines.size == 5) lineInk(mask, width, height, s.lines, s.left, s.right, s::offsetAt) else 0.0
        }
        val keptOriginal = order.filter { ink[it] >= MIN_LINE_INK }
        val rank = order.withIndex().associate { (r, original) -> original to r }
        // Systems are joined and braces found at the left end: use the lines there.
        val boxes = keptOriginal.map { i ->
            val s = staves[i]
            val o = s.offsetAt(s.left.toDouble())
            val l = s.lines.map { it + o }
            Box(i, pyRound(l.first()), pyRound(l.last()), s.left, s.right, (l.last() - l.first()) / 4.0,
                (l.first() + l.last()) / 2.0, s.slope)
        }
        val systems = mutableListOf<LayoutSystem>()
        if (boxes.isNotEmpty()) {
            val breaks = if (boxes.size > 1) {
                val conn = boxes.zipWithNext { a, b -> connected(mask, width, height, a, b) }
                if (conn.any { it }) joinIndented(boxes, conn.map { !it }) else splitByGaps(boxes)
            } else emptyList()
            val groups = mutableListOf(mutableListOf(0))
            breaks.forEachIndexed { i, brk -> if (brk) groups.add(mutableListOf()); groups.last().add(i + 1) }
            for (group in groups) {
                val members = group.map { boxes[it] }
                val brace = findBrace(mask, width, height, members)
                val pair = brace?.let { if (it.size == 2) it[0] to it[1] else it[1] to it[2] }
                val extra = brace?.let { if (it.size == 3) it[0] else null }
                systems.add(LayoutSystem(members.map { rank.getValue(it.index) }, pair, extra))
            }
        }
        val dropped = order.filter { it !in keptOriginal }.map { rank.getValue(it) }
        return PageLayoutResult(systems, dropped, order.map { ink[it] })
    }

    /** Skew-tolerant fraction of the staff's line pixels that are ink. */
    fun lineInk(mask: ByteArray, width: Int, height: Int, lines: List<Double>, left: Int, right: Int,
                offsetAt: (Double) -> Double = { 0.0 }): Double {
        val x0 = max(0, left); val x1 = min(width, right)
        if (x1 <= x0 || lines.size != 5) return 0.0
        val spacing = (lines.last() - lines.first()) / 4.0
        val reach = max(1, pyRound(spacing / 2))
        val strip = max(16, pyRound(8 * spacing))
        var hits = 0L; var total = 0L
        var sx = x0
        while (sx < x1) {
            val ex = min(x1, sx + strip)
            val shift = offsetAt((sx + ex) / 2.0)
            var best = 0
            for (d in -reach..reach) {
                var count = 0
                for (y in lines) {
                    val yi = pyRound(y + shift) + d
                    val a = max(0, yi - 1); val b = min(height, yi + 2)
                    if (b <= a) continue
                    for (x in sx until ex) {
                        for (row in a until b) { if (mask[row * width + x].toInt() != 0) { count++; break } }
                    }
                }
                best = max(best, count)
            }
            hits += best; total += 5L * (ex - sx)
            sx += strip
        }
        return if (total == 0L) 0.0 else hits.toDouble() / total
    }

    /** PC `staff_connections`, searched at both staves' left ends. */
    private fun connected(mask: ByteArray, width: Int, height: Int, a: Box, b: Box): Boolean {
        for (x0 in sortedSetOf(min(a.x0, b.x0), a.x0, b.x0)) {
            if (connectedAt(mask, width, height, a, b, x0)) return true
        }
        return false
    }

    private fun connectedAt(mask: ByteArray, width: Int, height: Int, a: Box, b: Box, x0: Int): Boolean {
        val sp = a.spacing
        val xa = max(0, (x0 - 4 * sp).toInt())
        val xb = min(width, (x0 + 3 * sp).toInt() + 1)
        val ya = max(0, a.y1)
        val yb = min(height, b.y0 + 1)
        if (yb - ya < 2 || xb - xa < 1) return false
        val h = yb - ya; val w = xb - xa
        val region = ByteArray(h * w) { i -> if (mask[(ya + i / w) * width + xa + i % w].toInt() != 0) 1 else 0 }
        for (x in 0 until w) {
            var filled = 0
            for (y in 0 until h) filled += region[y * w + x]
            if (filled.toDouble() / h >= MIN_FILL) return true
        }
        val kernel = max(1, pyRound(0.15 * sp))
        val closed = closeVertical(region, w, h, kernel)
        return components(closed, w, h).any { (top, ch) ->
            ch >= MIN_FILL * h && top <= (1 - MIN_FILL) * h && top + ch >= MIN_FILL * h
        }
    }

    /** OpenCV MORPH_CLOSE with a (k x 1) kernel: dilate, then erode (default borders). */
    private fun closeVertical(src: ByteArray, w: Int, h: Int, k: Int): ByteArray {
        if (k <= 1) return src
        val anchor = k / 2
        val dilated = ByteArray(src.size)
        for (x in 0 until w) for (y in 0 until h) {
            var v = 0
            for (i in 0 until k) { val yy = y + i - anchor; if (yy in 0 until h && src[yy * w + x].toInt() != 0) { v = 1; break } }
            dilated[y * w + x] = v.toByte()
        }
        val eroded = ByteArray(src.size)
        for (x in 0 until w) for (y in 0 until h) {
            var v = 1
            for (i in 0 until k) { val yy = y + i - anchor; if (yy in 0 until h && dilated[yy * w + x].toInt() == 0) { v = 0; break } }
            eroded[y * w + x] = v.toByte()
        }
        return eroded
    }

    /**
     * 8-connected components: (top, height, left, width, area) of each.
     * [leftTravel] is how far the left edge moves over the middle 80% of the
     * rows: a brace curves (large), a bracket or barline is straight (~0).
     * On a tilted page a straight bar leans: [componentStats]' shear (the
     * staves' dy/dx) is taken out first.
     */
    private data class Component(val top: Int, val height: Int, val left: Int, val width: Int, val area: Int,
                                 val leftTravel: Double = 0.0) {
        val bottom get() = top + height
        val right get() = left + width
    }

    private fun components(src: ByteArray, w: Int, h: Int): List<Pair<Int, Int>> =
        componentStats(src, w, h).map { it.top to it.height }

    private fun componentStats(src: ByteArray, w: Int, h: Int, shear: Double = 0.0): List<Component> {
        val seen = BooleanArray(src.size)
        val out = mutableListOf<Component>()
        val queue = IntArray(src.size)
        for (start in src.indices) {
            if (src[start].toInt() == 0 || seen[start]) continue
            var head = 0; var tail = 0
            queue[tail++] = start; seen[start] = true
            var top = h; var bottom = -1; var left = w; var right = -1; var area = 0
            while (head < tail) {
                val p = queue[head++]
                val y = p / w; val x = p % w
                area++
                if (y < top) top = y; if (y > bottom) bottom = y
                if (x < left) left = x; if (x > right) right = x
                for (dy in -1..1) for (dx in -1..1) {
                    if (dx == 0 && dy == 0) continue
                    val ny = y + dy; val nx = x + dx
                    if (ny !in 0 until h || nx !in 0 until w) continue
                    val q = ny * w + nx
                    if (!seen[q] && src[q].toInt() != 0) { seen[q] = true; queue[tail++] = q }
                }
            }
            val rows = bottom - top + 1
            val rowLeft = IntArray(rows) { Int.MAX_VALUE }
            for (k in 0 until tail) {
                val r = queue[k] / w - top
                rowLeft[r] = min(rowLeft[r], queue[k] % w)
            }
            // A vertical bar on a page whose staves rise by `shear` per pixel
            // leans by -shear per row; undo that before measuring the curve.
            var lo = Double.MAX_VALUE; var hi = -Double.MAX_VALUE
            for (r in (rows * 0.1).toInt() until (rows * 0.9).toInt()) {
                val v = rowLeft[r] + shear * r
                lo = min(lo, v); hi = max(hi, v)
            }
            out.add(Component(top, rows, left, right - left + 1, area, if (hi >= lo) hi - lo else 0.0))
        }
        return out
    }

    private fun median(values: List<Double>): Double {
        val v = values.sorted()
        if (v.isEmpty()) return 0.0
        val m = v.size / 2
        return if (v.size % 2 == 1) v[m] else (v[m - 1] + v[m]) / 2
    }

    private fun splitByGaps(boxes: List<Box>): List<Boolean> {
        if (boxes.size < 2) return emptyList()
        val rel = (0 until boxes.size - 1).map { i ->
            (boxes[i + 1].y0 - boxes[i].y1).toDouble() / max(1.0, boxes[i].height.toDouble())
        }
        val med = median(rel)
        return rel.map { it > SYSTEM_GAP_RATIO * med && it > 2.0 }
    }

    private fun joinIndented(boxes: List<Box>, breaks: List<Boolean>): List<Boolean> {
        val n = boxes.size
        if (n < 2 || breaks.none { it }) return breaks
        val widest = boxes.maxOf { it.x1 - it.x0 }
        val left = boxes.minOf { it.x0 }
        if (widest <= 0) return breaks
        val indented = boxes.map { (it.x0 - left) > INDENT_RATIO * widest }
        if (indented.none { it }) return breaks
        val gaps = (0 until n - 1).map { boxes[it + 1].y0 - boxes[it].y1 }
        val inner = gaps.filterIndexed { i, _ -> !breaks[i] }.map { it.toDouble() }
        if (inner.isEmpty()) return breaks
        val limit = INDENT_GAP_RATIO * median(inner)
        val out = breaks.toMutableList()
        var start = 0
        for (i in 0 until n - 1) {
            if (out[i]) {
                val groupIndented = (start..i).all { indented[it] }
                if (groupIndented && gaps[i] <= limit) { out[i] = false; continue }
                start = i + 1
            }
        }
        return out
    }

    /** Indices (within [staves]) covered by the best brace: 2, or the bottom 3. */
    private fun findBrace(mask: ByteArray, width: Int, height: Int, staves: List<Box>): List<Int>? {
        if (staves.size < 2) return null
        val starts = staves.map { it.x0 }
        val candidates = sortedSetOf(starts.min(), median(starts.map { it.toDouble() }).toInt())
        var best: Pair<Double, List<Int>>? = null
        for (sx0 in candidates) {
            val found = findBraceAt(mask, width, height, staves, sx0) ?: continue
            if (best == null || found.first > best.first) best = found
        }
        return best?.second
    }

    private fun findBraceAt(mask: ByteArray, width: Int, height: Int, staves: List<Box>, sx0: Int): Pair<Double, List<Int>>? {
        val sp = median(staves.map { it.spacing })
        val hs = median(staves.map { it.height.toDouble() })
        val yTop = staves.minOf { it.y0 }; val yBot = staves.maxOf { it.y1 }
        val x1 = (sx0 - 0.2 * sp).toInt()
        val x0 = max(0, (sx0 - 6 * sp).toInt())
        val y0 = max(0, (yTop - hs).toInt())
        val y1 = min(height, (yBot + hs).toInt())
        if (x1 - x0 < 2 || y1 - y0 < 2) return null
        val w = x1 - x0; val h = y1 - y0
        val region = ByteArray(w * h) { i -> if (mask[(y0 + i / w) * width + x0 + i % w].toInt() != 0) 1 else 0 }
        // A brace curves; the straight bar of a choir bracket (or a system
        // barline) is not a brace even when it spans two staves.
        val curved = componentStats(region, w, h, median(staves.map { it.slope })).filter {
            it.width <= 3.0 * sp && it.width >= 0.5 * sp && it.area >= 0.3 * it.height &&
                it.height >= hs && it.leftTravel >= 0.5 * sp
        }
        fun coveredBy(c: Component) =
            staves.indices.filter { y0 + c.top <= staves[it].center && staves[it].center <= y0 + c.bottom }
        // The thin middle of a small brace can vanish in the binarised page,
        // leaving an upper and a lower half over neighbouring staves.
        val halves = mutableListOf<Component>()
        for (a in curved) {
            val ca = coveredBy(a).singleOrNull() ?: continue
            for (b in curved) {
                if (coveredBy(b).singleOrNull() != ca + 1) continue
                val gap = b.top - a.bottom
                if (gap < 0 || gap > staves[ca + 1].y0 - staves[ca].y1) continue
                if (b.left >= a.right || a.left >= b.right) continue
                val left = min(a.left, b.left)
                halves.add(Component(a.top, b.bottom - a.top, left, max(a.right, b.right) - left, a.area + b.area))
            }
        }
        var best: Pair<Double, List<Int>>? = null
        for (c in curved + halves) {
            if (c.height < 1.5 * hs) continue
            val top = y0 + c.top; val bottom = y0 + c.top + c.height
            val covered = staves.indices.filter { top <= staves[it].center && staves[it].center <= bottom }
            if (covered.size !in 2..3 || covered.last() != covered.first() + covered.size - 1) continue
            if (covered.size == 3 && covered.last() != staves.lastIndex) continue
            val span = staves[covered.last()].y1 - staves[covered.first()].y0
            if (c.height > span + 1.5 * hs) continue
            val score = c.width.toDouble() * c.height
            if (best == null || score > best.first) best = score to covered
        }
        return best
    }
}
