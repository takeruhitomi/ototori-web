package jp.choiromr.mobile.omr

import java.io.File
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class StaffCheckpointStoreTest {
    @get:Rule val temp = TemporaryFolder()
    private val pixels = ByteArray(1280 * 256) { (it % 251).toByte() }
    private val token = StaffToken(10, 12, 0, 1, 0, 2)
    private val decoded = DecodeResult(listOf(token), true, 19, 200)

    @Test fun aCompletedStaffSurvivesReopeningWithoutAPageResult() {
        StaffCheckpointStore(temp.root).write(pixels, decoded)
        val reopened = StaffCheckpointStore(temp.root).read(pixels)!!
        assertEquals(decoded.tokens, reopened.tokens)
        assertTrue(reopened.reachedEos)
        assertEquals(0L, reopened.decoderMillis) // Cached work has no inference time.
        // Unpublished data from an interrupted write is never a cache entry.
        File(temp.root, ".pending-interrupted").writeText("incomplete")
        assertEquals(decoded.tokens, StaffCheckpointStore(temp.root).read(pixels)!!.tokens)
    }
    @Test fun theAttentionXSurvivesTheCheckpoint() {
        val located = DecodeResult(listOf(token.copy(x = 312.25f), token), true, 1, 2)
        StaffCheckpointStore(temp.root).write(pixels, located)
        val read = StaffCheckpointStore(temp.root).read(pixels)!!.tokens
        assertEquals(312.25f, read[0].x)
        assertTrue(read[1].x.isNaN())
    }
    @Test fun canvasXMapsBackToThePage() {
        // A wide crop fills the canvas width: 1280 canvas px = 1600 page px.
        assertEquals(100.0 + 640 * 1600.0 / 1280, StaffCanvas.pageX(PixelRect(100, 0, 1700, 200), 640.0), 0.05)
        // A tall crop is fitted by height: 2000 x 800 -> 640 x 256 on the canvas.
        assertEquals(10.0 + 320 * 2000.0 / 640, StaffCanvas.pageX(PixelRect(10, 0, 2010, 800), 320.0), 0.05)
    }
    @Test fun changedPixelsOrPipelineNeverReuseAnOldStaff() {
        val store = StaffCheckpointStore(temp.root)
        store.write(pixels, decoded)
        val changed = pixels.copyOf().also { it[17] = (it[17] + 1).toByte() }
        assertNull(store.read(changed))
        assertNull(StaffCheckpointStore(temp.root, pipeline = "different-model-or-settings").read(pixels))
        assertNull(StaffCheckpointStore(temp.root, scope = "different-pdf-page-or-dpi").read(pixels))
        // Even moving a valid file to another input's name is rejected.
        store.write(changed, decoded)
        val files = temp.root.listFiles()!!.filter { it.extension == "bin" }
        files[1].writeBytes(files[0].readBytes())
        assertEquals(1, listOf(store.read(pixels), store.read(changed)).count { it != null })
    }
    @Test fun corruptionAndTruncationAreDiscardedAndCanBeRecomputed() {
        val store = StaffCheckpointStore(temp.root)
        store.write(pixels, decoded)
        var file = temp.root.listFiles()!!.single()
        val changed = file.readBytes().also { it[90] = (it[90] + 1).toByte() }
        file.writeBytes(changed)
        assertNull(store.read(pixels))
        assertFalse(file.exists())
        store.write(pixels, decoded)
        file = temp.root.listFiles()!!.single()
        file.writeBytes(file.readBytes().copyOf(80))
        assertNull(store.read(pixels))
        store.write(pixels, decoded)
        assertNotNull(StaffCheckpointStore(temp.root).read(pixels))
    }
    @Test fun cappedDecodingKeepsItsWarningStateAndInvalidResultsAreNotPublished() {
        val store = StaffCheckpointStore(temp.root)
        val capped = DecodeResult(List(608) { token }, false, 0, 10)
        store.write(pixels, capped)
        assertFalse(store.read(pixels)!!.reachedEos)
        assertEquals(608, store.read(pixels)!!.tokens.size)
        val changed = pixels.copyOf().also { it[0] = 3 }
        assertThrows(IllegalArgumentException::class.java) {
            store.write(changed, decoded.copy(tokens = listOf(token.copy(pitch = 72))))
        }
        assertNull(store.read(changed))
    }
}
