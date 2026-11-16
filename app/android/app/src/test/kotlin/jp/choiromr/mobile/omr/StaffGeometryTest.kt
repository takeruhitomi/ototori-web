package jp.choiromr.mobile.omr

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class StaffGeometryTest {
    private val width = 960
    private val height = 480

    private fun staff(labels: ByteArray, top: Int, left: Int, right: Int, lines: Int = 5) {
        repeat(lines) { i ->
            val y = top + i * 12
            for (x in left until right) labels[y * width + x] = 4
        }
    }

    @Test fun blankPageHasNoStaves() {
        assertTrue(StaffGeometryDetector.detect(ByteArray(width * height), width, height).isEmpty())
    }
    @Test fun restoresClippedLastStaffFromTwoPrecedingStaves() {
        fun geometry(top: Double, left: Int) = StaffGeometry(left, 1773,
            List(5) { top + it * 15.0 }, 15.0, 16, false)
        val last = geometry(2430.0, 331)
        val neighbours = listOf(geometry(2061.0, 121), geometry(2280.0, 121))
        assertEquals(121, StaffGeometryDetector.restoreLeft(last, neighbours).left)
        assertEquals(last, StaffGeometryDetector.restoreLeft(last, neighbours.take(1)))
        assertEquals(last, StaffGeometryDetector.restoreLeft(last,
            listOf(geometry(2061.0, 121), geometry(2280.0, 240))))
    }

    @Test fun detectsTwoStavesAndKeepsTheirOrder() {
        val labels = ByteArray(width * height)
        staff(labels, 60, 90, 870)
        staff(labels, 240, 90, 870)
        val result = StaffGeometryDetector.detect(labels, width, height)
        assertEquals(2, result.size)
        assertEquals(60.0, result[0].lines.first(), 0.5)
        assertEquals(108.0, result[0].lines.last(), 0.5)
        assertEquals(240.0, result[1].lines.first(), 0.5)
    }

    /** Staff label pixels whose lines rise by [slope] px per px (a tilted page). */
    private fun tilted(labels: ByteArray, top: Double, left: Int, right: Int, slope: Double, skip: IntRange = IntRange.EMPTY) {
        for (x in left until right) {
            if (x in skip) continue
            for (i in 0..4) labels[(top + i * 12 + slope * (x - left)).toInt() * width + x] = 4
        }
    }

    @Test fun tiltedStaffKeepsItsFullWidthAndProfile() {
        val labels = ByteArray(width * height)
        val slope = -0.05  // about 3 degrees: 40 px over the staff
        tilted(labels, 140.0, 60, 900, slope)
        tilted(labels, 340.0, 60, 900, slope)
        val result = StaffGeometryDetector.detect(labels, width, height)
        assertEquals(2, result.size)
        val staff = result[0]
        assertTrue(staff.bent)
        assertTrue("left ${staff.left}", staff.left <= 70)
        assertTrue("right ${staff.right}", staff.right >= 890)
        assertEquals(140.0, staff.linesAt(60.0).first(), 4.0)
        assertEquals(140.0 + slope * 820, staff.linesAt(880.0).first(), 4.0)
    }

    @Test fun tiltedStaffInterruptedByTextStaysOneStaff() {
        val labels = ByteArray(width * height)
        tilted(labels, 140.0, 60, 900, -0.05, skip = 300 until 600)
        // Five strips without lines: the far side is still matched along the slope.
        assertEquals(1, StaffGeometryDetector.detect(labels, width, height).size)
    }

    @Test fun straightStaffIsNotBent() {
        val labels = ByteArray(width * height)
        staff(labels, 60, 90, 870)
        assertTrue(!StaffGeometryDetector.detect(labels, width, height).single().bent)
    }

    @Test fun straightCropLevelsATiltedStaff() {
        val w = 200; val h = 120
        val gray = ByteArray(w * h) { -1 }  // white
        for (x in 0 until w) { val y = (40 + 0.1 * x).toInt(); gray[y * w + x] = 0 }
        val staff = StaffGeometry(0, w, List(5) { 50.0 + it * 2 }, 2.0, 16, false,
            listOf(0.0 to -10.0, 200.0 to 10.0))
        val crop = StaffCanvas.straightCrop(gray, w, h, staff, PixelRect(0, 0, w, h))
        // The sloped line (y 40 -> 60) lies at one height (50) after straightening.
        for (x in listOf(5, 100, 195)) {
            val darkest = (49..51).minOf { crop[it * w + x].toInt() and 0xff }
            assertTrue("x $x: $darkest", darkest < 128)
        }
    }

    @Test fun labelsAGroupWithMissingBottomLineAsInferred() {
        val labels = ByteArray(width * height)
        staff(labels, 60, 90, 870)
        staff(labels, 240, 90, 870, lines = 4)
        val result = StaffGeometryDetector.detect(labels, width, height)
        assertEquals(2, result.size)
        assertTrue(result[1].inferredLine)
        assertEquals(288.0, result[1].lines.last(), 0.5)
    }
}
