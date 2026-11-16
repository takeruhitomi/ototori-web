package jp.choiromr.mobile

/** Immutable snapshot swapped by the UI while the rendering thread is active. */
data class AudioMixer(
    val volumes: Map<String, Double> = emptyMap(),
    val muted: Set<String> = emptySet(),
    val solo: Set<String> = emptySet(),
    val master: Double = 0.8,
    val instruments: Map<String, String> = emptyMap(),
    val metroVolume: Double = 0.6,
) {
    // As in the browser, explicit solos take precedence over mute.
    fun gain(part: String): Double = master * when {
        part == "_metronome" || part == "_countin" -> metroVolume
        solo.isNotEmpty() && part !in solo -> 0.0
        solo.isEmpty() && part in muted -> 0.0
        else -> volumes[part] ?: 1.0
    }

    companion object {
        fun parse(raw: Map<*, *>): AudioMixer {
            fun gain(v: Any?, fallback: Double): Double =
                ((v as? Number)?.toDouble() ?: fallback).also { require(it.isFinite() && it in 0.0..1.0) }
            return AudioMixer(
                (raw["volumes"] as? Map<*, *> ?: emptyMap<Any, Any>()).entries.associate { it.key.toString() to gain(it.value, 1.0) },
                (raw["muted"] as? List<*>)?.map { it.toString() }?.toSet() ?: emptySet(),
                (raw["solo"] as? List<*>)?.map { it.toString() }?.toSet() ?: emptySet(),
                gain(raw["master"], 0.8),
                (raw["instruments"] as? Map<*, *> ?: emptyMap<Any, Any>()).entries.associate {
                    it.key.toString() to it.value.toString().also { inst -> require(inst in listOf("choir", "organ", "sine", "piano")) }
                },
                gain(raw["metroVolume"], 0.6),
            )
        }
    }
}
