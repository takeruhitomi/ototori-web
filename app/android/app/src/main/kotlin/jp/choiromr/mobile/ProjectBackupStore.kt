package jp.choiromr.mobile

import java.io.File
import java.io.InputStream
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject
import jp.choiromr.mobile.omr.RecognitionCache

/** Owns staging paths; an archive never chooses a destination in app storage. */
class ProjectBackupStore(private val files: File, private val cache: File) {
    private val root = File(cache, "project-backups")
    private fun directory(token: String): File {
        require(token.matches(Regex("[0-9a-f-]{36}")))
        return File(root, token)
    }
    private fun sourceHash(text: String): String? {
        val score = JSONObject(text)
        require(score.getJSONArray("staves").length() > 0)
        val meta = score.optJSONObject("meta")
        if (meta == null || !meta.has("source_hash") || meta.isNull("source_hash")) return null
        return meta.getString("source_hash").also { require(it.matches(Regex("[0-9a-f]{64}"))) }
    }
    private fun sha(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    fun prepare(text: String): File {
        require(text.toByteArray(Charsets.UTF_8).size <= 10_000_000)
        val token = UUID.randomUUID().toString()
        val staging = directory(token)
        check(staging.mkdirs())
        val archive = File(root, "$token.zip")
        var prepared = false
        try {
            val project = File(staging, "project.json").apply { writeText(text, Charsets.UTF_8) }
            val entries = linkedMapOf("project.json" to project)
            sourceHash(text)?.let { hash ->
                val source = PdfSourceStore(File(files, "sources")).file(hash)
                require(source.isFile && sha(source) == hash) { "原譜がありません。通常のJSON書き出しを使うか、原譜を取り込んでください。" }
                entries["source.pdf"] = source
                val raw = File(files, "recognition/${RecognitionCache.NAMESPACE}/$hash")
                for (dpi in listOf(300, 400)) {
                    File(raw, "$dpi").listFiles().orEmpty().filter { it.name.matches(Regex("(0|[1-9][0-9]{0,5})\\.bin")) }
                        .sortedBy { it.name }.forEach {
                            RecognitionCache.readExternal(it)
                            entries["recognition/$dpi/${it.name}"] = it
                        }
                }
            }
            archive.outputStream().use { ProjectArchive.write(it, entries) }
            prepared = true
            return archive
        } finally { if (!prepared) archive.delete(); staging.deleteRecursively() }
    }
    fun stage(input: InputStream): Map<String, String> {
        val token = UUID.randomUUID().toString()
        val staging = directory(token)
        check(staging.mkdirs())
        var staged = false
        try {
            val entries = ProjectArchive.read(input, staging)
            val text = entries.getValue("project.json").readText(Charsets.UTF_8)
            val hash = sourceHash(text)
            val source = entries["source.pdf"]
            require((hash == null && source == null) || (hash != null && source != null && sha(source) == hash)) {
                "楽譜と原譜のハッシュが一致しません。"
            }
            require(hash != null || entries.keys.none { it.startsWith("recognition/") })
            entries.filterKeys { it.startsWith("recognition/") }.values.forEach { RecognitionCache.readExternal(it) }
            staged = true
            return mapOf("token" to token, "text" to text)
        } finally { if (!staged) staging.deleteRecursively() }
    }
    fun commit(token: String) {
        val staging = directory(token)
        val text = File(staging, "project.json").readText(Charsets.UTF_8)
        val hash = sourceHash(text)
        if (hash != null) {
            val source = File(staging, "source.pdf")
            require(sha(source) == hash)
            val count = android.os.ParcelFileDescriptor.open(source, android.os.ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                android.graphics.pdf.PdfRenderer(descriptor).use { it.pageCount }
            }
            val recognition = RecognitionCache(File(files, "recognition"))
            val entries = File(staging, "recognition").walkTopDown().filter { it.isFile }.toList()
            // Validate all pages before publishing even the source PDF.
            entries.forEach { require(it.nameWithoutExtension.toInt() in 0 until count); RecognitionCache.readExternal(it) }
            source.inputStream().use { require(PdfSourceStore(File(files, "sources")).importPdf(it).first == hash) }
            entries.forEach { page ->
                val dpi = page.parentFile!!.name.toInt()
                val index = page.nameWithoutExtension.toInt()
                if (recognition.read(hash, index, dpi) == null) recognition.write(hash, index, dpi, RecognitionCache.readExternal(page))
            }
        }
        discard(token)
    }
    fun discard(token: String) { directory(token).deleteRecursively() }
}
