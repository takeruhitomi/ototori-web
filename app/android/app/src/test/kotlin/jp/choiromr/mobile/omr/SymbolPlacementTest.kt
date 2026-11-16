package jp.choiromr.mobile.omr

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SymbolPlacementTest {
    private val width = 900
    private val height = 300
    private val sp = 12.0

    /** Five lines from x0 to x1, the top line at [top] + slope * (x - x0). */
    private fun staff(m: ByteArray, top: Double, slope: Double = 0.0, x0: Int = 50, x1: Int = 850) {
        for (x in x0 until x1) for (i in 0..4) {
            val y = (top + i * sp + slope * (x - x0)).toInt()
            m[y * width + x] = 1
        }
    }

    private fun vertical(m: ByteArray, x: Int, y0: Int, y1: Int) { for (y in y0..y1) { m[y * width + x] = 1; m[y * width + x + 1] = 1 } }

    private fun head(m: ByteArray, cx: Double, cy: Double, hollow: Boolean = false) {
        for (y in (cy - 6).toInt()..(cy + 6).toInt()) for (x in (cx - 8).toInt()..(cx + 8).toInt()) {
            val r = ((x - cx) / 7.0) * ((x - cx) / 7.0) + ((y - cy) / 5.0) * ((y - cy) / 5.0)
            if (r <= 1.0 && (!hollow || r >= 0.45)) m[y * width + x] = 1
        }
    }

    @Test fun pitchesFromClefAndStep() {
        assertEquals(SymbolPlacement.diatonic("E4"), SymbolPlacement.clefBottom("clef_G2"))
        assertEquals(SymbolPlacement.diatonic("G2"), SymbolPlacement.clefBottom("clef_F4"))
        assertEquals(SymbolPlacement.diatonic("F3"), SymbolPlacement.clefBottom("clef_C3"))
    }

    @Test fun barlinesAndNoteheadsSnapOnATiltedStaff() {
        val m = ByteArray(width * height)
        val slope = 0.03  // about 1.7 degrees: 24 px over the staff
        staff(m, 100.0, slope)
        fun topAt(x: Int) = 100.0 + slope * (x - 50)
        vertical(m, 450, topAt(450).toInt(), (topAt(450) + 4 * sp).toInt())
        // G4 (second line from the bottom) at x 300; B4 (middle line) half note at x 600.
        head(m, 300.0, topAt(300) + 3 * sp)
        head(m, 600.0, topAt(600) + 2 * sp, hollow = true)
        val lines = (0..4).map { 100.0 + 12.0 + it * sp }  // detected (median) lines of the tilted staff
        val tokens = listOf(
            PlacedToken("clef_G2", ".", 60.0), PlacedToken("note_4", "G4", 285.0),
            PlacedToken("barline", ".", 430.0), PlacedToken("note_2", "B4", 590.0),
            PlacedToken("rest_4", "_", 700.0), PlacedToken("barline", ".", 820.0))
        val places = SymbolPlacement.place(m, width, height, lines, 50, 850, tokens)
        val bar = places[2]!!
        assertTrue(bar.snapped)
        assertEquals(450.5, bar.x, 1.0)
        assertEquals(topAt(450), bar.lines!![0], 1.5)
        val g4 = places[1]!!
        assertTrue("G4 ${g4}", g4.snapped)
        assertEquals(300.0, g4.x, 2.0)
        assertEquals(topAt(300) + 3 * sp, g4.y!!, 2.0)
        val b4 = places[3]!!
        assertTrue("B4 ${b4}", b4.snapped)
        assertEquals(600.0, b4.x, 2.0)
        assertFalse(places[4]!!.snapped)
        // No vertical line at the last barline: kept at the attention x, unconfirmed.
        assertFalse(places[5]!!.snapped)
        assertEquals(0.0, places[5]!!.confidence, 1e-9)
        assertNotNull(places[0]!!.lines)
    }

    @Test fun noteWithoutAHeadAtItsPitchIsNotSnapped() {
        val m = ByteArray(width * height)
        staff(m, 100.0)
        head(m, 300.0, 100.0 + 3 * sp)  // a G4 head, but the token says D5
        val lines = (0..4).map { 100.0 + it * sp }
        val places = SymbolPlacement.place(m, width, height, lines, 50, 850,
            listOf(PlacedToken("clef_G2", ".", 60.0), PlacedToken("note_4", "D5", 300.0)))
        assertFalse(places[1]!!.snapped)
        assertTrue(places[1]!!.confidence < 0.5)
    }

    /**
     * Debug harness for real pages (skipped unless PLACEMENT_INPUT is set):
     * reads masks and tokens written by work/parity-exp/placement/dump.py and
     * writes the places next to them.
     */
    @Test fun realPagesFromDump() {
        val dir = System.getenv("PLACEMENT_INPUT")?.let(::File) ?: return
        for (file in dir.listFiles { f -> f.name.endsWith(".tokens.txt") }!!.sorted()) {
            val lines = file.readLines()
            val (w, h) = lines[0].split(" ").map { it.toInt() }
            val mask = File(file.path.removeSuffix(".tokens.txt") + ".mask").readBytes()
            val out = StringBuilder()
            var i = 1
            var staffIndex = 0
            while (i < lines.size) {
                val head = lines[i++].split(" ")
                val left = head[1].toInt(); val right = head[2].toInt()
                val staffLines = head.subList(3, 8).map { it.toDouble() }
                val n = head[8].toInt()
                val tokens = (0 until n).map {
                    val p = lines[i++].split("\t")
                    PlacedToken(p[0], p[1], p[2].toDoubleOrNull())
                }
                val places = SymbolPlacement.place(mask, w, h, staffLines, left, right, tokens)
                places.forEachIndexed { j, p ->
                    if (p != null) out.append("$staffIndex $j ${p.toList().joinToString(" ") { it?.toString() ?: "null" }}\n")
                }
                staffIndex++
            }
            File(file.path.removeSuffix(".tokens.txt") + ".places.txt").writeText(out.toString())
        }
    }
}
