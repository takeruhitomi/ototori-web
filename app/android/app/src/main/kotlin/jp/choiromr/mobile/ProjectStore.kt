package jp.choiromr.mobile

import android.util.AtomicFile
import java.io.File
import java.util.UUID
import org.json.JSONObject

/** App-private score library. Atomic replacement keeps the prior saved version on failure. */
class ProjectStore(private val root: File) {
    private fun file(id: String): AtomicFile {
        require(id.matches(Regex("[0-9a-f-]{36}"))) { "Invalid project id" }
        check(root.isDirectory || root.mkdirs()) { "Cannot create project directory" }
        return AtomicFile(File(root, "$id.json"))
    }

    fun save(id: String?, score: String): String {
        val bytes = score.toByteArray(Charsets.UTF_8)
        require(bytes.size <= 10_000_000) { "Score is too large" }
        val parsed = JSONObject(score)
        require(parsed.getJSONArray("staves").length() > 0)
        val key = id ?: UUID.randomUUID().toString()
        val entry = file(key)
        val payload = JSONObject().put("version", 1).put("title", parsed.optString("title", "楽譜").ifBlank { "無題の楽譜" })
            .put("updated", System.currentTimeMillis()).put("score", parsed).toString().toByteArray(Charsets.UTF_8)
        val stream = entry.startWrite()
        try {
            stream.write(payload)
            entry.finishWrite(stream)
        } catch (e: Exception) { entry.failWrite(stream); throw e }
        return key
    }

    fun load(id: String): String {
        val data = JSONObject(file(id).readFully().toString(Charsets.UTF_8))
        require(data.getInt("version") == 1) { "Unsupported project version" }
        return data.getJSONObject("score").toString()
    }

    fun delete(id: String): Boolean {
        val entry = file(id)
        if (!entry.baseFile.exists()) return false
        entry.delete()
        return true
    }

    /** Library row summary: sung part names, piano, bar count and whether the PDF is linked. */
    private fun summary(score: JSONObject): Map<String, Any> {
        val staves = score.optJSONArray("staves") ?: return emptyMap()
        val parts = mutableListOf<String>()
        var piano = false
        var measures = 0
        for (i in 0 until staves.length()) {
            val staff = staves.optJSONObject(i) ?: continue
            val role = staff.optString("role")
            if (role == "piano_rh" || role == "piano_lh") piano = true
            else parts.add(staff.optString("name").ifBlank { staff.optString("id") })
            measures = maxOf(measures, staff.optJSONArray("measures")?.length() ?: 0)
        }
        val meta = score.optJSONObject("meta")
        val hash = meta?.opt("source_hash")
        val document = score.optJSONObject("_choir_mobile_document")?.optString("document_id").orEmpty()
        return mapOf("parts" to parts, "piano" to piano, "measures" to measures,
            "hasSource" to (hash is String && hash.isNotEmpty()), "documentId" to document,
            "warnings" to (score.optJSONArray("warnings")?.length() ?: 0))
    }

    fun list(): List<Map<String, Any>> {
        if (!root.isDirectory) return emptyList()
        return root.listFiles().orEmpty().filter { it.name.matches(Regex("[0-9a-f-]{36}\\.json")) }.map { f ->
            try {
                val json = JSONObject(AtomicFile(f).readFully().toString(Charsets.UTF_8))
                mapOf("id" to f.nameWithoutExtension, "title" to json.optString("title", "楽譜").ifBlank { "無題の楽譜" }, "updated" to json.getLong("updated")) +
                    (json.optJSONObject("score")?.let { summary(it) } ?: emptyMap())
            } catch (e: Exception) {
                mapOf("id" to f.nameWithoutExtension, "title" to "読み込めない楽譜（保存データを保持しています）", "updated" to f.lastModified())
            }
        }.sortedByDescending { it["updated"] as Long }
    }
}
