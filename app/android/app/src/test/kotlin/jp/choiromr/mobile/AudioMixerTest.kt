package jp.choiromr.mobile

import org.junit.Assert.assertEquals
import org.junit.Test

class AudioMixerTest {
    @Test fun multipleSolosOverrideMuteAndKeepPianoStavesTogether() {
        val mixer = AudioMixer.parse(mapOf(
            "master" to 0.5, "volumes" to mapOf("s" to 0.4, "piano" to 0.6),
            "muted" to listOf("s"), "solo" to listOf("s", "piano"),
            "instruments" to mapOf("s" to "organ", "piano" to "choir"),
        ))
        assertEquals(0.2, mixer.gain("s"), 1e-9)
        assertEquals(0.3, mixer.gain("piano"), 1e-9)
        assertEquals(0.0, mixer.gain("a"), 1e-9)
        assertEquals("organ", mixer.instruments["s"])
        assertEquals(0.0, AudioMixer(muted = setOf("s")).gain("s"), 1e-9)
    }
    @Test fun metronomeAndCountInFollowMasterButIgnorePartMuteAndSolo() {
        val mixer = AudioMixer(master = 0.5, solo = setOf("s"), metroVolume = 0.6)
        assertEquals(0.3, mixer.gain("_metronome"), 1e-9)
        assertEquals(0.3, mixer.gain("_countin"), 1e-9)
        assertEquals(0.0, mixer.copy(master = 0.0).gain("_metronome"), 1e-9)
    }
    @Test(expected = IllegalArgumentException::class)
    fun rejectsNonFiniteGainBeforeItReachesTheAudioThread() {
        AudioMixer.parse(mapOf("volumes" to mapOf("s" to Double.NaN)))
    }
}
