package jp.choiromr.mobile

import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.AtomicFile
import java.io.File
import java.io.InputStream
import java.security.MessageDigest

/** Immutable source snapshots are addressed by the bytes actually imported. */
class PdfSourceStore(private val root: File) {
    fun file(hash: String): File {
        require(hash.matches(Regex("[0-9a-f]{64}"))) { "Invalid PDF source id" }
        return File(root, "$hash.pdf")
    }

    fun importPdf(input: InputStream): Pair<String, File> {
        check(root.isDirectory || root.mkdirs()) { "PDF の保存先を作成できません。" }
        val pending = File.createTempFile("import-", ".pdf", root)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            pending.outputStream().use { output ->
                val buffer = ByteArray(65536)
                while (true) {
                    val size = input.read(buffer)
                    if (size < 0) break
                    digest.update(buffer, 0, size)
                    output.write(buffer, 0, size)
                }
                output.fd.sync()
            }
            ParcelFileDescriptor.open(pending, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRenderer(descriptor).use { require(it.pageCount > 0) { "PDF にページがありません。" } }
            }
            val hash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
            val target = file(hash)
            // AtomicFile also handles interrupted writes to an existing source.
            val atomic = AtomicFile(target)
            val output = atomic.startWrite()
            try {
                pending.inputStream().use { it.copyTo(output) }
                atomic.finishWrite(output)
            } catch (e: Exception) { atomic.failWrite(output); throw e }
            return hash to target
        } finally { pending.delete() }
    }
}
