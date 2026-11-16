package jp.choiromr.mobile.omr

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BarlineEvidenceTest {
    private val width = 600
    private val height = 400
    private fun staff(top: Int) = StaffGeometry(20, 560, List(5) { top + it * 10.0 }, 10.0, 16, false)
    private fun line(gray: ByteArray, staff: StaffGeometry, x: Int) {
        for (y in staff.lines.first().toInt()..staff.lines.last().toInt()) gray[y * width + x] = 0
    }
    @Test fun corroboratesBarsButRejectsSingleStaffStemsAndMergesFinalDoubleBar() {
        val staves = listOf(staff(40), staff(160), staff(280))
        val gray = ByteArray(width * height) { -1 }
        for (s in staves) for (x in listOf(20, 180, 360, 550, 558)) line(gray, s, x)
        line(gray, staves[1], 240) // A note stem is not a shared barline.
        assertEquals(listOf(180, 360, 558),
            BarlineEvidence.corroboratedEnds(gray, width, height, staves[1], staves[0], staves[2]))
    }
    @Test fun refusesEvidenceWithoutBothNeighboursOrClosingBar() {
        val staves = listOf(staff(40), staff(160), staff(280))
        val gray = ByteArray(width * height) { -1 }
        for (s in staves) for (x in listOf(180, 360)) line(gray, s, x)
        assertTrue(BarlineEvidence.corroboratedEnds(gray, width, height, staves[1], staves[0], staves[2]).isEmpty())
        assertTrue(BarlineEvidence.corroboratedEnds(gray, width, height, staves[1], null, staves[2]).isEmpty())
    }
    @Test fun retainsThickFinalBarsWhoseDilatedStrokesNearlyTouch() {
        val staves = listOf(staff(40), staff(160), staff(280))
        val gray = ByteArray(width * height) { -1 }
        for (s in staves) {
            line(gray, s, 180)
            for (x in (548..551) + (554..560)) line(gray, s, x)
        }
        assertEquals(2, BarlineEvidence.corroboratedEnds(gray, width, height, staves[1], staves[0], staves[2]).size)
    }
    @Test fun countsTrailingMusicAndIgnoresEmptyBarsAndLowerNotes() {
        fun symbol(r: String, p: String = "upper") = NamedSymbol(r, "C4", "_", p, "_", "_")
        assertEquals(2, BarlineEvidence.measureCount(listOf(symbol("barline"), symbol("note_4"),
            symbol("barline"), symbol("note_4", "lower"), symbol("barline"), symbol("note_2"))))
    }
}
