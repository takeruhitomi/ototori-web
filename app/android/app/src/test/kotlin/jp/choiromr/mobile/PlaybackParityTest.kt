package jp.choiromr.mobile

import java.io.File
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.sin
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Renders fixed scenarios with the playPreview maths and writes the 16-bit
 * output plus a JSON description to <tmp>/choir-audio-parity, so the browser
 * renderer (web/js/audio-render.js) can be compared sample by sample with
 * `node scripts/web_audio_parity.mjs`.
 *
 * [render] is MainActivity.playPreview with the AudioTrack replaced by an
 * array and the mixer taken from a per-chunk schedule. Keep it in step with
 * MainActivity when the synthesis changes.
 */
class PlaybackParityTest {
    private data class PianoSample(val pitch: Int, val data: ShortArray)
    private data class AudioEvent(val pitch: Int, val start: Int, val duration: Int, val piano: Boolean, val gain: Double, val legato: Boolean,
                                  val part: String, val accent: Boolean, val cents: Double = 0.0)
    private data class RenderedNote(val first: Long, val last: Long, val frequency: Double,
                                    val sample: ShortArray?, val sampleStep: Double, val gain: Double, val legato: Boolean,
                                    val part: String, val piano: Boolean, val accent: Boolean)
    private class Scenario(val name: String, val events: List<AudioEvent>, val lengthMs: Int, val loop: Boolean,
                           val offsetMs: Int, val loopStartMs: Int, val mixers: List<Pair<Int, AudioMixer>>, val maxFrames: Long)

    private fun loadPianoSamples(): List<PianoSample> {
        val names = listOf("A0" to 21, "C1" to 24, "Fs1" to 30, "C2" to 36, "Fs2" to 42,
            "C3" to 48, "Fs3" to 54, "C4" to 60, "Fs4" to 66, "C5" to 72, "Fs5" to 78,
            "C6" to 84, "Fs6" to 90, "C7" to 96, "Fs7" to 102, "C8" to 108)
        return names.map { (name, pitch) ->
            val bytes = File("src/main/assets/piano/$name.pcm").readBytes()
            require(bytes.isNotEmpty() && bytes.size % 2 == 0)
            val pcm = ShortArray(bytes.size / 2) { i ->
                ((bytes[2 * i].toInt() and 255) or (bytes[2 * i + 1].toInt() shl 8)).toShort()
            }
            PianoSample(pitch, pcm)
        }
    }

    private fun render(s: Scenario, samples: List<PianoSample>?): ShortArray {
        val events = s.events; val lengthMs = s.lengthMs; val loop = s.loop; val offsetMs = s.offsetMs; val loopStartMs = s.loopStartMs
        val output = ArrayList<Short>()
        var chunkIndex = 0
        val rate = 44100
        val notes = events.map { event ->
            val sample = samples?.minByOrNull { kotlin.math.abs(it.pitch - event.pitch) }
            val tune = 2.0.pow(event.cents / 1200.0)
            RenderedNote(event.start.toLong() * rate / 1000, (event.start.toLong() + event.duration) * rate / 1000,
                440.0 * 2.0.pow((event.pitch - 69) / 12.0) * tune, sample?.data,
                if (sample == null) 0.0 else 0.5 * 2.0.pow((event.pitch - sample.pitch) / 12.0) * tune, event.gain, event.legato,
                event.part, event.piano, event.accent)
        }.sortedBy { it.first }
        val total = maxOf(lengthMs, events.maxOfOrNull { it.start + it.duration } ?: 0).toLong() * rate / 1000
        if (total == 0L) return ShortArray(0)
        val buffer = ShortArray(1024)
        val offsetFrames = offsetMs.toLong() * rate / 1000
        val cycleClock = AudioCycle(total, loop, offsetFrames, loopStartMs.toLong() * rate / 1000)
        var position = offsetFrames
        var nextNote = 0
        val active = mutableListOf<RenderedNote>()
        val previousGains = mutableMapOf<String, Double>()
        val limiter = AudioLimiter(rate)
        while ((loop || position < total) && position - offsetFrames < s.maxFrames) {
            val cycle = cycleClock.phase(position)
            if (cycle == 0L || (position >= total && cycle == loopStartMs.toLong() * rate / 1000)) { nextNote = 0; active.clear() }
            val count = cycleClock.chunkSize(position, buffer.size)
            active.removeAll { it.last <= cycle }
            while (nextNote < notes.size && notes[nextNote].first < cycle + count) {
                val note = notes[nextNote++]
                if (note.last > cycle) active.add(note)
            }
            val mixer = s.mixers.last { it.first <= chunkIndex }.second
            val gains = active.map { mixer.gain(it.part) }
            val fromGains = active.mapIndexed { index, note -> previousGains[note.part] ?: gains[index] }
            active.forEachIndexed { index, note -> previousGains[note.part] = gains[index] }
            val instruments = active.map { mixer.instruments[it.part] ?: if (it.piano) "piano" else "choir" }
            val organHarmonics = listOf(2 to 0.5, 3 to 0.25, 4 to 0.15)
            val choirHarmonics = listOf(2 to 0.22, 3 to 0.12, 4 to 0.06)
            for (i in 0 until count) {
                val sample = cycle + i
                var value = 0.0
                for (noteIndex in active.indices) {
                    val note = active[noteIndex]
                    if (sample < note.first || sample >= note.last) continue
                    val age = sample - note.first
                    val liveGain = fromGains[noteIndex] + (gains[noteIndex] - fromGains[noteIndex]) * i / count
                    val envelope = minOf(1.0, age / 220.0, (note.last - sample) / if (note.legato) 441.0 else 2205.0) * note.gain * liveGain
                    if (envelope == 0.0) continue
                    val instrument = instruments[noteIndex]
                    val pcm = if (instrument == "piano") note.sample else null
                    if (note.part == "_metronome" || note.part == "_countin") {
                        value += sin(2 * Math.PI * (if (note.accent) 1500 else 1000) * age / rate) * envelope
                        continue
                    }
                    if (pcm == null) {
                        val phase = 2 * Math.PI * note.frequency * age / rate
                        var wave = sin(phase)
                        val harmonics = if (instrument == "organ") organHarmonics
                            else if (instrument == "choir") choirHarmonics else emptyList()
                        for ((harmonic, level) in harmonics) if (note.frequency * harmonic < rate / 2) wave += sin(phase * harmonic) * level
                        value += wave * envelope / (if (instrument == "organ") 1.9 else 1.4)
                    } else {
                        val at = age * note.sampleStep
                        val index = at.toInt()
                        if (index + 1 < pcm.size) {
                            val fraction = at - index
                            value += (pcm[index] * (1 - fraction) + pcm[index + 1] * fraction) / 32768.0 * envelope
                        }
                    }
                }
                val fadeIn = minOf(1.0, (position - offsetFrames + i) / 220.0)
                buffer[i] = (limiter.process(value * fadeIn / 2.6) * 18200).toInt().toShort()
            }
            for (i in 0 until count) output.add(buffer[i])
            position += count
            chunkIndex++
        }
        return output.toShortArray()
    }

    private fun ev(pitch: Int, start: Int, duration: Int, part: String, piano: Boolean = false, gain: Double = 1.0,
                   legato: Boolean = false, accent: Boolean = false, cents: Double = 0.0) =
        AudioEvent(pitch, start, duration, piano, gain, legato, part, accent, cents)

    private fun scenarios(): List<Scenario> {
        val mix = buildList {
            add(ev(72, 0, 500, "S", gain = 0.9, legato = true)); add(ev(74, 500, 500, "S", gain = 0.9, legato = true))
            add(ev(76, 1000, 700, "S", gain = 0.9, cents = 15.6))
            add(ev(67, 0, 1500, "A", gain = 0.8, cents = -13.7))
            add(ev(60, 200, 1200, "T")); add(ev(48, 0, 2000, "B", gain = 0.7))
            for (p in listOf(60, 64, 67)) add(ev(p, 300, 800, "P", piano = true))
            add(ev(36, 1200, 1300, "P", piano = true, cents = 3.9)); add(ev(100, 900, 150, "P", piano = true, gain = 0.5))
            for (t in listOf(0, 500, 1000, 1500)) add(ev(100, t, 40, "_metronome", accent = t == 0))
            add(ev(100, 2000, 40, "_countin", accent = true))
            for (p in 50..85 step 5) add(ev(p, 1600, 600, "L"))
        }
        val base = AudioMixer(mapOf("S" to 0.9, "A" to 0.7, "P" to 1.0), master = 0.8,
            instruments = mapOf("T" to "organ", "B" to "sine"), metroVolume = 0.6)
        val mixMixers = listOf(0 to base,
            30 to base.copy(muted = setOf("A"), instruments = mapOf("T" to "organ", "B" to "sine", "S" to "piano")),
            60 to base.copy(solo = setOf("B", "L", "P"), muted = setOf("B"), master = 1.0,
                instruments = mapOf("T" to "organ", "B" to "choir", "P" to "sine")))
        val loop = buildList {
            add(ev(69, 0, 1500, "S")); add(ev(60, 250, 1000, "P", piano = true)); add(ev(64, 500, 700, "A", legato = true, cents = -31.2))
            for (t in 0 until 1500 step 250) add(ev(100, t, 40, "_metronome", accent = t == 0))
            add(ev(100, 0, 40, "_countin", accent = true))
        }
        val range = (21..108 step 3).mapIndexed { i, p -> ev(p, i * 100, 150, "P", piano = true, cents = if (i % 2 == 0) 0.0 else -17.5) }
        return listOf(
            Scenario("mix", mix, 2500, false, 0, 0, mixMixers, Long.MAX_VALUE),
            Scenario("loop", loop, 1500, true, 600, 300, listOf(0 to AudioMixer(), 100 to AudioMixer(volumes = mapOf("S" to 0.3))), 4L * 44100),
            Scenario("range", range, 0, false, 0, 0, listOf(0 to AudioMixer()), Long.MAX_VALUE),
        )
    }

    private fun json(m: AudioMixer): String {
        fun str(s: String) = "\"" + s.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        return "{\"volumes\":{" + m.volumes.entries.joinToString(",") { str(it.key) + ":" + it.value } + "}," +
            "\"muted\":[" + m.muted.joinToString(",") { str(it) } + "],\"solo\":[" + m.solo.joinToString(",") { str(it) } + "]," +
            "\"master\":${m.master},\"instruments\":{" + m.instruments.entries.joinToString(",") { str(it.key) + ":" + str(it.value) } + "}," +
            "\"metroVolume\":${m.metroVolume}}"
    }

    private fun json(s: Scenario, frames: Int): String =
        "{\"name\":\"${s.name}\",\"lengthMs\":${s.lengthMs},\"loop\":${s.loop},\"offsetMs\":${s.offsetMs},\"loopStartMs\":${s.loopStartMs}," +
            "\"frames\":$frames,\"events\":[" + s.events.joinToString(",") { e ->
                "{\"pitch\":${e.pitch},\"start\":${e.start},\"duration\":${e.duration},\"piano\":${e.piano},\"gain\":${e.gain}," +
                    "\"legato\":${e.legato},\"partId\":\"${e.part}\",\"accent\":${e.accent},\"cents\":${e.cents}}"
            } + "],\"mixers\":[" + s.mixers.joinToString(",") { "{\"fromChunk\":${it.first},\"mixer\":${json(it.second)}}" } + "]}"

    @Test fun writesReferenceRenderings() {
        val dir = File(System.getProperty("java.io.tmpdir"), "choir-audio-parity").apply { mkdirs() }
        val samples = loadPianoSamples()
        for (s in scenarios()) {
            val pcm = render(s, samples)
            assertTrue("${s.name} is silent", pcm.any { abs(it.toInt()) > 1000 })
            assertTrue("${s.name} exceeds the limiter ceiling", pcm.all { abs(it.toInt()) <= 22750 })
            val bytes = ByteArray(pcm.size * 2)
            for (i in pcm.indices) { bytes[2 * i] = pcm[i].toByte(); bytes[2 * i + 1] = (pcm[i].toInt() shr 8).toByte() }
            File(dir, "${s.name}.pcm").writeBytes(bytes)
            File(dir, "${s.name}.json").writeText(json(s, pcm.size))
        }
    }
}
