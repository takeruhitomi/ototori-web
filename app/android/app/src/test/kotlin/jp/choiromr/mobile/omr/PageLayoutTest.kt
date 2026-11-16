package jp.choiromr.mobile.omr

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PageLayoutTest {
    private val width = 800
    private val height = 1400
    private val spacing = 10.0

    private fun staff(top: Double, left: Int = 100, right: Int = 700) =
        LayoutStaff((0..4).map { top + it * spacing }, left, right)

    private fun mask(staves: List<LayoutStaff>, inked: Set<Int> = staves.indices.toSet()): ByteArray {
        val m = ByteArray(width * height)
        staves.forEachIndexed { i, s ->
            if (i !in inked) return@forEachIndexed
            for (y in s.lines) for (x in s.left until s.right) m[y.toInt() * width + x] = 1
        }
        return m
    }

    private fun vertical(m: ByteArray, x: Int, y0: Int, y1: Int, thickness: Int = 2) {
        for (y in y0..y1) for (dx in 0 until thickness) m[y * width + x + dx] = 1
    }

    @Test fun systemBarlineGroupsStavesAndGapsSeparateSystems() {
        val staves = listOf(staff(100.0), staff(180.0), staff(260.0), staff(500.0), staff(580.0), staff(660.0))
        val m = mask(staves)
        vertical(m, 100, 100, 300)   // first system barline
        vertical(m, 100, 500, 700)   // second system barline
        val layout = PageLayout.analyze(m, width, height, staves)
        assertEquals(listOf(listOf(0, 1, 2), listOf(3, 4, 5)), layout.systems.map { it.staves })
        assertEquals(emptyList<Int>(), layout.dropped)
    }

    @Test fun faintStaffWithoutInkIsDropped() {
        val staves = listOf(staff(100.0), staff(180.0), staff(260.0), staff(340.0))
        val m = mask(staves, inked = setOf(0, 1, 3))
        vertical(m, 100, 100, 380)
        val layout = PageLayout.analyze(m, width, height, staves)
        assertEquals(listOf(2), layout.dropped)
        assertEquals(listOf(listOf(0, 1, 3)), layout.systems.map { it.staves })
    }

    /** Brace glyph: the left edge bulges out towards the middle point. */
    private fun brace(m: ByteArray, x: Int, y0: Int, y1: Int, skipMiddle: Int = 0) {
        val mid = (y0 + y1) / 2
        for (y in y0..y1) {
            if (kotlin.math.abs(y - mid) < skipMiddle) continue
            val t = (y - y0).toDouble() / (y1 - y0)
            val left = x + 8 - Math.round(8 * (1 - kotlin.math.abs(2 * t - 1))).toInt()
            for (dx in 0 until 3) m[y * width + left + dx] = 1
        }
    }

    @Test fun braceMarksPianoPairAndThreeStaffPiano() {
        val staves = listOf(staff(100.0), staff(180.0), staff(260.0), staff(340.0), staff(420.0))
        val m = mask(staves)
        vertical(m, 100, 100, 460)
        brace(m, 80, 340, 460)
        val two = PageLayout.analyze(m, width, height, staves)
        assertEquals(3 to 4, two.systems.single().pianoPair)
        assertNull(two.systems.single().pianoExtra)

        val m3 = mask(staves)
        vertical(m3, 100, 100, 460)
        brace(m3, 80, 260, 460)
        val three = PageLayout.analyze(m3, width, height, staves)
        assertEquals(3 to 4, three.systems.single().pianoPair)
        assertEquals(2, three.systems.single().pianoExtra)
    }

    @Test fun straightChoirBracketIsNotAPianoBrace() {
        // 瑠璃色の地球: the bracket joining the two voice staves was taken for a
        // brace, so the voices became the piano and the piano the voices.
        val staves = listOf(staff(100.0), staff(180.0), staff(260.0), staff(340.0))
        val m = mask(staves)
        vertical(m, 100, 100, 380)
        vertical(m, 88, 95, 225, thickness = 7)
        assertNull(PageLayout.analyze(m, width, height, staves).systems.single().pianoPair)

        brace(m, 76, 260, 380)
        assertEquals(2 to 3, PageLayout.analyze(m, width, height, staves).systems.single().pianoPair)
    }

    @Test fun braceBrokenAtItsMiddlePointStillMarksThePair() {
        val staves = listOf(staff(100.0), staff(180.0), staff(260.0), staff(340.0))
        val m = mask(staves)
        vertical(m, 100, 100, 380)
        vertical(m, 88, 95, 225, thickness = 7)
        brace(m, 76, 260, 380, skipMiddle = 9)
        assertEquals(2 to 3, PageLayout.analyze(m, width, height, staves).systems.single().pianoPair)
    }

    @Test fun leaningBracketOnATiltedPageIsStillNotABrace() {
        // Page rotated about 3.4 degrees: staves rise 0.06 px per px, vertical
        // strokes lean 0.06 px per row. The bracket's bar then travels as far
        // as a small brace's edge unless the lean is taken out.
        val slope = -0.06
        val tops = listOf(100.0, 180.0, 260.0, 340.0)
        val staves = tops.map { top ->
            LayoutStaff((0..4).map { top + it * spacing }, 100, 700, listOf(100.0 to -slope * 300, 700.0 to slope * 300))
        }
        val m = ByteArray(width * height)
        for (top in tops) for (x in 100 until 700) for (i in 0..4) {
            m[(top + i * spacing + slope * (x - 400)).toInt() * width + x] = 1
        }
        fun lean(y: Int) = (-slope * (y - 100)).toInt()
        for (y in 118..398) for (dx in 0..1) m[y * width + 100 + lean(y) + dx] = 1          // system barline
        for (y in 113..243) for (dx in 0 until 7) m[y * width + 80 + lean(y) + dx] = 1      // choir bracket
        val mid = (278 + 398) / 2
        for (y in 278..398) {                                                              // piano brace
            val t = (y - 278).toDouble() / (398 - 278)
            val x = 64 + lean(y) + 8 - Math.round(8 * (1 - kotlin.math.abs(2 * t - 1))).toInt()
            for (dx in 0 until 3) m[y * width + x + dx] = 1
        }
        assertEquals(mid, mid)
        assertEquals(2 to 3, PageLayout.analyze(m, width, height, staves).systems.single().pianoPair)
    }

    @Test fun lineInkToleratesSkew() {
        val s = staff(100.0)
        val m = ByteArray(width * height)
        // Lines drift down by 4 px across the width (scan skew).
        for (y in s.lines) for (x in s.left until s.right) {
            val yy = (y + 4.0 * (x - s.left) / (s.right - s.left)).toInt()
            m[yy * width + x] = 1
        }
        val ink = PageLayout.lineInk(m, width, height, s.lines, s.left, s.right)
        assert(ink > 0.9) { "ink $ink" }
    }
}
