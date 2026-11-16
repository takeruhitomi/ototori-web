package jp.choiromr.mobile.omr

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.util.AtomicFile
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt
import org.json.JSONArray
import org.json.JSONObject

/** Offline label OCR, separate from expensive OMR and its existing checkpoints. */
class PageTextReader(private val root: File) {
    fun read(hash: String, index: Int, page: PdfRenderer.Page): Map<String, Any> {
        require(hash.matches(Regex("[0-9a-f]{64}")) && index >= 0)
        val directory = File(root, "labels-v1-mlkit16/$hash")
        check(directory.isDirectory || directory.mkdirs())
        val entry = AtomicFile(File(directory, "$index.json"))
        try {
            val saved = JSONObject(entry.readFully().toString(Charsets.UTF_8))
            return decode(saved)
        } catch (_: Exception) { /* Missing or corrupt OCR is regenerated. */ }
        val height = (page.height * (1920.0 / page.width)).roundToInt()
        require(height > 0 && 1920L * height <= 8_000_000L) { "声部名の画像が大きすぎます。" }
        val bitmap = Bitmap.createBitmap(1920, height, Bitmap.Config.ARGB_8888)
        val labels = JSONArray()
        val warnings = JSONArray()
        try {
            bitmap.eraseColor(Color.WHITE)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            val image = InputImage.fromBitmap(bitmap, 0)
            for (japanese in listOf(false, true)) {
                var recognizer: TextRecognizer? = null
                try {
                    recognizer = if (japanese) TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())
                        else TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
                    val result = Tasks.await(recognizer.process(image), 60, TimeUnit.SECONDS)
                    for (block in result.textBlocks) for (line in block.lines) {
                        val box = line.boundingBox ?: continue
                        if (box.width() <= 0 || box.height() <= 0) continue
                        if (labels.length() >= 2000 || line.text.length > 500) continue
                        labels.put(JSONObject().put("text", line.text).put("bounds",
                            JSONArray(listOf(box.left, box.top, box.right, box.bottom))))
                    }
                } catch (e: Exception) {
                    warnings.put("声部名の${if (japanese) "日本語" else "英字"}読み取りに失敗しました。配置からの推定を試みます。")
                    android.util.Log.w("ChoirLayout", "Label OCR failed", e)
                } finally { recognizer?.close() }
            }
        } finally { bitmap.recycle() }
        val data = JSONObject().put("labels", labels).put("warnings", warnings)
        // A transient OCR failure must not become a permanent empty cache.
        if (warnings.length() == 0) {
            val stream = entry.startWrite()
            try { stream.write(data.toString().toByteArray(Charsets.UTF_8)); entry.finishWrite(stream) }
            catch (e: Exception) { entry.failWrite(stream); throw e }
        }
        android.util.Log.i("ChoirLayout", "page=${index + 1} OCR lines=${labels.length()}")
        return decode(data)
    }
    private fun decode(data: JSONObject): Map<String, Any> {
        val labels = data.getJSONArray("labels")
        require(labels.length() <= 2000)
        return mapOf("labels" to (0 until labels.length()).map { i ->
            val item = labels.getJSONObject(i)
            val bounds = item.getJSONArray("bounds")
            require(bounds.length() == 4)
            require(bounds.getInt(2) > bounds.getInt(0) && bounds.getInt(3) > bounds.getInt(1))
            mapOf("text" to item.getString("text"), "bounds" to (0..3).map { bounds.getInt(it) })
        }, "warnings" to data.getJSONArray("warnings").let { values ->
            (0 until values.length()).map { values.getString(it) }
        })
    }
}
