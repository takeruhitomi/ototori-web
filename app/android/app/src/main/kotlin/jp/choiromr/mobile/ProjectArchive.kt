package jp.choiromr.mobile

import java.io.*
import java.security.MessageDigest
import java.util.Properties
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/** Streamed backup container. Extraction is into a new private staging directory only. */
object ProjectArchive {
    const val MAX_TOTAL = 1024L * 1024 * 1024
    private const val MAX_FILES = 2002
    private val cacheName = Regex("recognition/(300|400)/(0|[1-9][0-9]{0,5})\\.bin")
    fun allowed(name: String) = name == "project.json" || name == "source.pdf" || cacheName.matches(name)
    private fun limit(name: String) = when (name) {
        "project.json" -> 10_000_000L
        "source.pdf" -> MAX_TOTAL
        else -> 64L * 1024 * 1024
    }
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it.toInt() and 255) }
    private fun copy(input: InputStream, output: OutputStream?, maximum: Long): Pair<Long, String> {
        val sha = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(65536)
        var count = 0L
        while (true) {
            val n = input.read(buffer)
            if (n < 0) break
            count += n
            require(count <= maximum) { "バックアップが大きすぎます。" }
            sha.update(buffer, 0, n); output?.write(buffer, 0, n)
        }
        return count to sha.digest().hex()
    }
    fun write(output: OutputStream, entries: Map<String, File>) {
        require(entries.containsKey("project.json") && entries.size <= MAX_FILES && entries.keys.all(::allowed))
        val facts = entries.mapValues { (name, file) -> file.inputStream().use { copy(it, null, limit(name)) } }
        require(facts.values.sumOf { it.first } <= MAX_TOTAL)
        val manifest = Properties().apply {
            setProperty("format", "choir-omr-project"); setProperty("version", "1")
            setProperty("recognition_namespace", jp.choiromr.mobile.omr.RecognitionCache.NAMESPACE)
            setProperty("count", entries.size.toString())
            entries.keys.forEachIndexed { index, name ->
                setProperty("entry.$index.name", name)
                setProperty("entry.$index.bytes", facts.getValue(name).first.toString())
                setProperty("entry.$index.sha256", facts.getValue(name).second)
            }
        }
        val metadata = ByteArrayOutputStream().also { manifest.store(it, null) }.toByteArray()
        require(metadata.size <= 512000)
        ZipOutputStream(output).use { zip ->
            zip.putNextEntry(ZipEntry("manifest.properties")); zip.write(metadata); zip.closeEntry()
            entries.forEach { (name, file) ->
                zip.putNextEntry(ZipEntry(name))
                val actual = file.inputStream().use { copy(it, zip, facts.getValue(name).first) }
                require(actual == facts.getValue(name)) { "書き出し中に元データが変更されました。" }
                zip.closeEntry()
            }
        }
    }
    fun read(input: InputStream, destination: File): Map<String, File> {
        require(destination.isDirectory && destination.listFiles().orEmpty().isEmpty())
        val files = linkedMapOf<String, File>()
        ZipInputStream(input).use { zip ->
            val first = requireNotNull(zip.nextEntry) { "バックアップが空です。" }
            require(first.name == "manifest.properties" && !first.isDirectory)
            val metadata = ByteArrayOutputStream()
            copy(zip, metadata, 512000); zip.closeEntry()
            val manifest = Properties().apply { load(ByteArrayInputStream(metadata.toByteArray())) }
            require(manifest.getProperty("format") == "choir-omr-project" && manifest.getProperty("version") == "1")
            val count = manifest.getProperty("count").toInt()
            require(count in 1..MAX_FILES)
            val expected = linkedMapOf<String, Pair<Long, String>>()
            var total = 0L
            repeat(count) { index ->
                val name = requireNotNull(manifest.getProperty("entry.$index.name"))
                require(allowed(name) && !expected.containsKey(name)) { "バックアップ内の名前が不正です。" }
                val bytes = manifest.getProperty("entry.$index.bytes").toLong()
                val hash = requireNotNull(manifest.getProperty("entry.$index.sha256"))
                require(bytes in 0..limit(name) && hash.matches(Regex("[0-9a-f]{64}")))
                total += bytes; require(total <= MAX_TOTAL)
                expected[name] = bytes to hash
            }
            require(expected.containsKey("project.json"))
            if (expected.keys.any { it.startsWith("recognition/") }) {
                require(manifest.getProperty("recognition_namespace") == jp.choiromr.mobile.omr.RecognitionCache.NAMESPACE) {
                    "認識結果の処理バージョンが未対応です。"
                }
            }
            while (true) {
                val entry = zip.nextEntry ?: break
                val fact = expected[entry.name]
                require(fact != null && !entry.isDirectory && !files.containsKey(entry.name)) { "バックアップの項目が不正です。" }
                val file = File(destination, entry.name)
                check(file.parentFile!!.isDirectory || file.parentFile!!.mkdirs())
                val actual = FileOutputStream(file).use { output ->
                    copy(zip, output, fact.first).also { output.fd.sync() }
                }
                require(actual == fact) { "バックアップのサイズまたはハッシュが一致しません。" }
                files[entry.name] = file; zip.closeEntry()
            }
            require(files.keys == expected.keys) { "バックアップの一部が欠けています。" }
        }
        return files
    }
}
