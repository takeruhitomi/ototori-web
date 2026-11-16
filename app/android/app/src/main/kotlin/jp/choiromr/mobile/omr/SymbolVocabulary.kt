/* Vocabulary generated from homr 0.7.0. See third_party/homr/NOTICE.md. */
package jp.choiromr.mobile.omr

import org.json.JSONObject
import java.security.MessageDigest

data class NamedSymbol(val rhythm: String, val pitch: String, val lift: String,
                       val position: String, val articulation: String, val slur: String)

/** Maps the six model output IDs to homr's pinned vocabulary. */
class SymbolVocabulary(bytes: ByteArray) {
    private val entries: Map<String, List<String>>

    init {
        val actual = MessageDigest.getInstance("SHA-256").digest(bytes)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        require(actual == HASH) { "Transformer vocabulary hash mismatch" }
        val json = JSONObject(bytes.toString(Charsets.UTF_8))
        entries = EXPECTED.mapValues { (name, size) ->
            val values = json.getJSONArray(name)
            require(values.length() == size) { "Invalid $name vocabulary" }
            List(size) { values.getString(it) }
        }
    }

    fun decode(token: StaffToken): NamedSymbol = NamedSymbol(
        entry("rhythm", token.rhythm), entry("pitch", token.pitch), entry("lift", token.lift),
        entry("position", token.position), entry("articulation", token.articulation), entry("slur", token.slur))

    private fun entry(name: String, index: Int): String {
        val values = entries.getValue(name)
        require(index in values.indices) { "$name token out of range: $index" }
        return values[index]
    }

    companion object {
        const val HASH = "f47b3d8f7f356ad0a4d8a84acf78383118bba9d00196d15b2a49767955343013"
        private val EXPECTED = mapOf("rhythm" to 259, "pitch" to 72, "lift" to 7,
                                      "position" to 3, "articulation" to 54, "slur" to 5)
    }
}
