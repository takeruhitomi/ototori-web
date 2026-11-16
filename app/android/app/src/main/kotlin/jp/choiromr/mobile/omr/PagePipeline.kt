package jp.choiromr.mobile.omr

import android.graphics.pdf.PdfRenderer
import java.util.concurrent.Callable
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Recognises several pages of one PDF, rendering and segmenting the next page
 * (on its own thread) while the current page's staves are decoded. Only that
 * thread opens pages of [pdf] while this runs (PdfRenderer allows one open
 * page at a time); callers must not use [pdf] until [run] returns.
 */
object PagePipeline {
    fun run(pdf: PdfRenderer, pages: List<Int>, dpi: Int, engine: PdfOmrEngine,
            cancelled: () -> Boolean,
            checkpoints: (Int) -> StaffCheckpointStore?,
            onProgress: (page: Int, stage: String, done: Int, total: Int) -> Unit,
            onPage: (page: Int, result: RecognizedPdfPage) -> Unit) {
        if (pages.isEmpty()) return
        val preparer = Executors.newSingleThreadExecutor()
        try {
            fun prepare(index: Int) = preparer.submit(Callable {
                pdf.openPage(index).use { engine.prepare(it, dpi, cancelled) }
            })
            var next = prepare(pages.first())
            for ((k, index) in pages.withIndex()) {
                onProgress(index, "render", 0, 1)
                val prepared = try { next.get() } catch (e: ExecutionException) { throw e.cause ?: e }
                if (k + 1 < pages.size) next = prepare(pages[k + 1])
                val result = engine.finish(prepared, cancelled, { stage, done, total -> onProgress(index, stage, done, total) },
                    checkpoints(index))
                onPage(index, result)
            }
        } finally {
            preparer.shutdownNow()
            // The preparing thread may still hold a page open or use the models.
            preparer.awaitTermination(60, TimeUnit.SECONDS)
        }
    }
}
