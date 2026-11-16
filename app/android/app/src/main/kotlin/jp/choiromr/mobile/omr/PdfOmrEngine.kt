package jp.choiromr.mobile.omr

import android.graphics.pdf.PdfRenderer

/** [timing]: milliseconds per stage of this page (render, segmentation, encoder, decoder, layout, total...). */
data class RecognizedPdfPage(val page: RecognizedPage, val width: Int, val height: Int,
                             val layout: PageLayoutResult? = null, val timing: Map<String, Long> = emptyMap())

/** A rendered page with its staves found, ready for decoding (see [PdfOmrEngine.prepare]). */
class PreparedPdfPage(val gray: ByteArray, val height: Int, val staves: List<StaffGeometry>,
                      val timing: MutableMap<String, Long>, val started: Long)

/**
 * Connects installed models, PDF rasterization and the page token pipeline.
 * Keeps the models loaded until [close]: use one engine for all pages of a
 * conversion. [prepare] (render + staff detection) and [finish] (decoding,
 * layout) may run on different threads, so the next page can be prepared
 * while this one is decoded; PDF pages must still be opened one at a time.
 */
class PdfOmrEngine(private val models: ModelStore, private val vocabulary: SymbolVocabulary,
                   private val settings: OmrPerformance.Settings = OmrPerformance.Settings()) : AutoCloseable {
    private var omr: PageOmr? = null

    @Synchronized private fun pageOmr(): PageOmr = omr ?: run {
        val installed = requireNotNull(models.installed()) { "認識モデルを取り込んでください。" }
        PageOmr(OmrModelFiles(installed.getValue("segnet.onnx"), installed.getValue("encoder.onnx"), installed.getValue("decoder.onnx")),
            vocabulary, settings.threads, settings.parallelStaves).also { omr = it }
    }

    fun prepare(page: PdfRenderer.Page, dpi: Int, cancelled: () -> Boolean = { false }): PreparedPdfPage {
        if (cancelled()) throw InterruptedException("認識を中止しました。")
        val started = System.nanoTime()
        val timing = mutableMapOf<String, Long>()
        val image = PdfPageRasterizer.render(page, dpi, cancelled)
        timing["render"] = (System.nanoTime() - started) / 1_000_000
        val staves = pageOmr().detectStaves(image.first, 1920, image.second, cancelled, timing)
        return PreparedPdfPage(image.first, image.second, staves, timing, started)
    }

    fun finish(prepared: PreparedPdfPage, cancelled: () -> Boolean = { false },
               onProgress: (String, Int, Int) -> Unit = { _, _, _ -> },
               checkpoints: StaffCheckpointStore? = null): RecognizedPdfPage {
        val timing = prepared.timing
        val decodeStart = System.nanoTime()
        val result = pageOmr().recognize(prepared.gray, 1920, prepared.height, cancelled, onProgress,
            checkpoints = checkpoints, staves = prepared.staves, timing = timing)
        timing["decode_wall"] = (System.nanoTime() - decodeStart) / 1_000_000
        val tokens = result.staves.map { s ->
            s.symbols.mapIndexed { i, sym ->
                val x = s.decoding.tokens.getOrNull(i)?.x ?: Float.NaN
                PlacedToken(sym.rhythm, sym.pitch, if (x.isFinite()) StaffCanvas.pageX(s.crop, x.toDouble()) else null)
            }
        }
        val layoutStart = System.nanoTime()
        val layout = analyzeLayout(prepared.gray, 1920, prepared.height,
            result.staves.map { LayoutStaff(it.geometry.lines, it.geometry.left, it.geometry.right, it.geometry.profile) }, tokens)
        timing["layout"] = (System.nanoTime() - layoutStart) / 1_000_000
        timing["total"] = (System.nanoTime() - prepared.started) / 1_000_000
        timing["threads"] = settings.threads.toLong(); timing["parallel_staves"] = settings.parallelStaves.toLong()
        android.util.Log.i("ChoirOmrTiming", timing.entries.joinToString(" ") { "${it.key}=${it.value}" })
        return RecognizedPdfPage(result, 1920, prepared.height, layout, timing.toMap())
    }

    fun recognize(page: PdfRenderer.Page, dpi: Int, cancelled: () -> Boolean = { false },
                  onProgress: (String, Int, Int) -> Unit = { _, _, _ -> },
                  checkpoints: StaffCheckpointStore? = null): RecognizedPdfPage {
        onProgress("render", 0, 1)
        return finish(prepare(page, dpi, cancelled), cancelled, onProgress, checkpoints)
    }

    @Synchronized override fun close() { omr?.close(); omr = null }

    companion object {
        /** Version of the page-layout rules stored with cached pages. */
        // 2: a straight choir bracket is no longer a brace; a brace broken at
        // its middle point is joined.
        // 3: token positions (snapped barlines/noteheads, staff lines per bar).
        const val LAYOUT_VERSION = 3

        fun analyzeLayout(gray: ByteArray, width: Int, height: Int, staves: List<LayoutStaff>,
                          tokens: List<List<PlacedToken>>? = null): PageLayoutResult {
            val mask = StaffCanvas.inkMask(gray, width, height)
            val layout = PageLayout.analyze(mask, width, height, staves)
            if (tokens == null || tokens.size != staves.size) return layout
            return layout.copy(places = staves.indices.map { i ->
                SymbolPlacement.place(mask, width, height, staves[i].lines, staves[i].left, staves[i].right, tokens[i])
            })
        }

        /** Layout (and token positions) for a cached page from an older layout version (no model inference). */
        fun layoutForCached(page: PdfRenderer.Page, dpi: Int, data: Map<*, *>): Map<String, Any> {
            val image = PdfPageRasterizer.render(page, dpi)
            val height = data["height"] as Int
            require(image.second == height) { "ページの描画サイズが保存結果と一致しません。" }
            val items = (data["staves"] as List<*>).map { it as Map<*, *> }
            val staves = items.map { staff ->
                val lines = (staff["lines"] as? List<*>)?.map { (it as Number).toDouble() } ?: emptyList()
                val crop = (staff["crop"] as List<*>).map { it as Int }
                val profile = (staff["profile"] as? List<*>)?.mapNotNull { point ->
                    (point as? List<*>)?.takeIf { it.size == 2 }?.let { (it[0] as Number).toDouble() to (it[1] as Number).toDouble() }
                } ?: emptyList()
                LayoutStaff(lines, (staff["left"] as? Int) ?: crop[0], (staff["right"] as? Int) ?: crop[2], profile)
            }
            return analyzeLayout(image.first, 1920, height, staves, items.map { cachedTokens(it) }).toData()
        }

        private fun cachedTokens(staff: Map<*, *>): List<PlacedToken> = (staff["symbols"] as List<*>).map { item ->
            val s = item as List<*>
            PlacedToken(s[0] as String, s[1] as String, (s.getOrNull(6) as? Number)?.toDouble())
        }
    }
}

fun PageLayoutResult.toData(): Map<String, Any> = buildMap {
    put("systems", systems.map { it.toMap() })
    put("layout", mapOf("version" to PdfOmrEngine.LAYOUT_VERSION, "dropped_staves" to dropped, "line_ink" to lineInk))
    // Per staff, per token: null or [x, y|null, confidence, snapped, (five line heights)].
    places?.let { p -> put("places", p.map { staff -> staff.map { it?.toList() } }) }
}
