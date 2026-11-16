package jp.choiromr.mobile

import android.util.AtomicFile
import java.io.File
import java.util.UUID
import org.json.JSONObject

/** Job settings are separate from raw page symbols and edited scores. */
class ConversionStore(private val root: File) {
    companion object { private val lock = Any() }
    private fun file(id: String): AtomicFile {
        require(id.matches(Regex("[0-9a-f-]{36}")))
        check(root.isDirectory || root.mkdirs())
        return AtomicFile(File(root, "$id.json"))
    }
    fun save(id: String?, text: String): String = synchronized(lock) {
        require(text.toByteArray(Charsets.UTF_8).size <= 100000)
        val data = JSONObject(text)
        require(data.getInt("version") == 1)
        val settings = data.getJSONObject("settings")
        require(settings.getString("source_hash").matches(Regex("[0-9a-f]{64}")))
        require(settings.getInt("dpi") in listOf(300, 400))
        require(settings.getInt("pages") > 0)
        val key = id ?: UUID.randomUUID().toString()
        if (id != null) {
            val previous = JSONObject(load(id)).getJSONObject("settings")
            require(previous.toString() == settings.toString()) { "既存ジョブの設定を変更できません。" }
        }
        data.put("updated", System.currentTimeMillis())
        val entry = file(key)
        val output = entry.startWrite()
        try { output.write(data.toString().toByteArray(Charsets.UTF_8)); entry.finishWrite(output) }
        catch (e: Exception) { entry.failWrite(output); throw e }
        key
    }
    fun load(id: String): String = synchronized(lock) { file(id).readFully().toString(Charsets.UTF_8) }
    /**
     * Forgets a job (its settings and progress). Recognised pages stay in the
     * recognition cache, keyed by the PDF, so converting it again reuses them.
     */
    fun delete(id: String): Unit = synchronized(lock) { file(id).delete() }
    fun list(): List<Map<String, Any>> = synchronized(lock) { root.listFiles().orEmpty()
        .filter { it.name.matches(Regex("[0-9a-f-]{36}\\.json")) }.map { f ->
            try {
                val data = JSONObject(load(f.nameWithoutExtension))
                mapOf("id" to f.nameWithoutExtension, "name" to data.getJSONObject("settings").optString("name", "PDF"),
                    "status" to data.getString("status"), "completed" to data.getJSONArray("completed_pages").length(),
                    "updated" to data.getLong("updated"))
            } catch (e: Exception) {
                mapOf("id" to f.nameWithoutExtension, "name" to "読み込めない変換ジョブ", "status" to "failed", "completed" to 0, "updated" to f.lastModified())
            }
        }.sortedByDescending { it["updated"] as Long } }
}
