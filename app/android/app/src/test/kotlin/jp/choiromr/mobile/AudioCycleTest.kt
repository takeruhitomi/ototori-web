package jp.choiromr.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioCycleTest {
    @Test fun loopsAtTheExactFrameAndRestoresTheFullCycleAfterAnOffsetStart() {
        val cycle = AudioCycle(4410, true, 2205)
        assertEquals(2205L, cycle.phase(2205))
        assertEquals(1024, cycle.chunkSize(2205, 1024))
        assertEquals(157, cycle.chunkSize(4253, 1024))
        assertEquals(0L, cycle.phase(4410))
        assertEquals(1024, cycle.chunkSize(4410, 1024))
        assertEquals(2205L, cycle.playbackPosition(0))
        assertEquals(0L, cycle.playbackPosition(2205))
        assertEquals(2205L, cycle.playbackPosition(4410))
    }
    @Test fun finitePlaybackStopsAndNeverReportsPastItsEnd() {
        val cycle = AudioCycle(1500, false)
        assertEquals(476, cycle.chunkSize(1024, 1024))
        assertEquals(0, cycle.chunkSize(1500, 1024))
        assertEquals(1500L, cycle.playbackPosition(2000))
    }
    @Test fun countInOnlyPlaysOnceBeforeLoopingTheScore() {
        val cycle = AudioCycle(6000, true, 0, 2000)
        assertEquals(1000L, cycle.phase(1000))
        assertEquals(2000L, cycle.phase(6000))
        assertEquals(2000L, cycle.phase(10000))
        assertEquals(2000L, cycle.playbackPosition(6000))
        assertEquals(100, cycle.chunkSize(5900, 1024))
        assertEquals(1024, cycle.chunkSize(6000, 1024))
    }
}
