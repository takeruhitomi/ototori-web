package jp.choiromr.mobile.omr

import android.util.AtomicFile
import io.flutter.plugin.common.StandardMessageCodec
import java.io.File
import java.nio.ByteBuffer

/** Raw model symbols survive assembly errors, cancellation and process death. */
class RecognitionCache(private val root: File) {
    companion object {
        const val NAMESPACE = "symbols-v2-barline-context4-396-308"
        fun validate(data: Map<*, *>) {
            val width = requireNotNull(data["width"] as? Int)
            val height = data["height"] as? Int
            require(width == 1920 && height != null && height in 1..100000)
            val warnings = data["warnings"] as? List<*>
            require(warnings != null && warnings.size <= 4096 && warnings.all { it is String })
            val staves = data["staves"] as? List<*>
            require(staves != null && staves.size <= 1000)
            for (item in staves) {
                val staff = item as? Map<*, *> ?: error("Invalid staff cache")
                val crop = staff["crop"] as? List<*> ?: error("Invalid crop")
                require(crop.size == 4 && crop.all { it is Int })
                val bounds = crop.map { it as Int }
                require(bounds[0] >= 0 && bounds[1] >= 0 && bounds[2] <= width && bounds[3] <= height &&
                    bounds[0] < bounds[2] && bounds[1] < bounds[3])
                require(staff["reachedEos"] is Boolean)
                val symbols = staff["symbols"] as? List<*> ?: error("Invalid symbols")
                require(symbols.size <= 608 && symbols.all { symbol ->
                    symbol is List<*> && (symbol.size == 6 || (symbol.size == 7 && (symbol[6] as? Double)?.isFinite() == true)) &&
                        symbol.take(6).all { it is String && it.length <= 256 }
                })
            }
        }
        fun readExternal(file: File): Map<String, Any> {
            require(file.isFile && file.length() <= 64L * 1024 * 1024)
            val data = StandardMessageCodec.INSTANCE.decodeMessage(ByteBuffer.wrap(file.readBytes())) as? Map<*, *>
                ?: error("Invalid recognition data")
            validate(data)
            return data.entries.associate { (key, value) -> (key as String) to requireNotNull(value) }
        }
    }
    private fun file(pdfHash: String, page: Int, dpi: Int): AtomicFile {
        require(pdfHash.matches(Regex("[0-9a-f]{64}")) && page >= 0 && dpi in listOf(300, 400))
        // Bump the namespace when the model, crop or decoding pipeline changes.
        // (Attention x is optional: older pages without it stay valid.)
        val dir = File(root, "$NAMESPACE/$pdfHash/$dpi")
        check(dir.isDirectory || dir.mkdirs())
        return AtomicFile(File(dir, "$page.bin"))
    }

    fun read(hash: String, page: Int, dpi: Int): Map<*, *>? {
        val entry = file(hash, page, dpi)
        if (!entry.baseFile.isFile) return null
        return try {
            require(entry.baseFile.length() <= 64L * 1024 * 1024)
            val data = StandardMessageCodec.INSTANCE.decodeMessage(ByteBuffer.wrap(entry.readFully())) as? Map<*, *> ?: error("Invalid page cache")
            validate(data)
            data
        } catch (e: Exception) {
            entry.delete()
            null
        }
    }

    fun write(hash: String, page: Int, dpi: Int, data: Map<String, Any>) {
        validate(data)
        val encoded = requireNotNull(StandardMessageCodec.INSTANCE.encodeMessage(data))
        val bytes = ByteArray(encoded.position())
        encoded.flip()
        encoded.get(bytes)
        val entry = file(hash, page, dpi)
        val stream = entry.startWrite()
        try {
            stream.write(bytes)
            entry.finishWrite(stream)
        } catch (e: Exception) {
            entry.failWrite(stream)
            throw e
        }
    }
}
