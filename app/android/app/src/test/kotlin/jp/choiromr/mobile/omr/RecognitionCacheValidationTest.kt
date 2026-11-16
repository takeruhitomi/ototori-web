package jp.choiromr.mobile.omr

import org.junit.Assert.assertThrows
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import io.flutter.plugin.common.StandardMessageCodec

class RecognitionCacheValidationTest {
    @get:Rule val temp = TemporaryFolder()
    private fun page() = mutableMapOf<String, Any>("width" to 1920, "height" to 2000,
        "warnings" to listOf("test"), "staves" to listOf(mapOf("crop" to listOf(1, 2, 100, 200),
            "reachedEos" to true, "symbols" to listOf(listOf("note_quarter", "C4", ".", ".", ".", ".")))))
    @Test fun acceptsActualPageShapeIncludingEmptyPagesWithWarnings() {
        RecognitionCache.validate(page())
        RecognitionCache.validate(page().apply { put("staves", emptyList<Any>()) })
    }
    @Test fun acceptsAnAttentionXAfterTheSixTokensButNothingElse() {
        fun withSymbol(symbol: List<Any>) = page().apply {
            put("staves", listOf(mapOf("crop" to listOf(1, 2, 100, 200), "reachedEos" to true, "symbols" to listOf(symbol))))
        }
        RecognitionCache.validate(withSymbol(listOf("note_4", "C4", ".", "upper", ".", ".", 412.5)))
        for (bad in listOf<Any>(Double.NaN, "412", 412)) {
            assertThrows(IllegalArgumentException::class.java) {
                RecognitionCache.validate(withSymbol(listOf("note_4", "C4", ".", "upper", ".", ".", bad)))
            }
        }
    }
    @Test fun rejectsIncompleteOrMalformedPages() {
        val invalid = listOf(page().apply { remove("height") }, page().apply { put("width", 0) },
            page().apply { put("warnings", listOf(1)) },
            page().apply { put("staves", listOf(mapOf("crop" to listOf(1, 2, 100, 3000), "reachedEos" to true, "symbols" to emptyList<Any>()))) },
            page().apply { put("staves", listOf(mapOf("crop" to listOf(1, 2, 100, 200), "reachedEos" to true, "symbols" to listOf(listOf("bad"))))) })
        invalid.forEach { data -> assertThrows(IllegalArgumentException::class.java) { RecognitionCache.validate(data) } }
    }
    @Test fun readsTheActualBinaryCacheFormatAndRejectsInvalidEncodedData() {
        fun encoded(data: Any): ByteArray {
            val buffer = StandardMessageCodec.INSTANCE.encodeMessage(data)!!
            val bytes = ByteArray(buffer.position()); buffer.flip(); buffer.get(bytes)
            return bytes
        }
        val file = temp.newFile("cache.bin")
        val data = page().apply { put("warnings", listOf("原認識結果")) }
        file.writeBytes(encoded(data))
        assertEquals(data, RecognitionCache.readExternal(file))
        file.writeBytes(encoded(mapOf("width" to 1920)))
        assertThrows(IllegalArgumentException::class.java) { RecognitionCache.readExternal(file) }
    }
}
