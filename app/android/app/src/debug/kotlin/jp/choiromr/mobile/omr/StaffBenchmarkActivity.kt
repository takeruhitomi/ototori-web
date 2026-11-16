package jp.choiromr.mobile.omr

import android.app.Activity
import android.os.Bundle
import android.os.Debug
import android.os.ParcelFileDescriptor
import android.graphics.pdf.PdfRenderer
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/** Debug-only, adb-driven parity harness. No PDF is uploaded or sent anywhere. */
class StaffBenchmarkActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val root = requireNotNull(getExternalFilesDir(null))
        val output = File(root, "staff-benchmark-result.json")
        val pool = Executors.newSingleThreadExecutor()
        pool.execute {
            try {
                if (intent.getStringExtra("mode") == "pdf-dataset") {
                    val manifest = JSONArray(File(root, "dataset-manifest.json").readText())
                    val vocabulary = SymbolVocabulary(assets.open("omr/vocabulary.json").use { it.readBytes() })
                    val cache = RecognitionCache(File(filesDir, "recognition"))
                    val labels = PageTextReader(File(filesDir, "recognition-layout"))
                    val results = JSONArray()
                    for (piece in 0 until manifest.length()) {
                        val item = manifest.getJSONObject(piece)
                        val name = item.getString("name")
                        require(name.matches(Regex("[a-z0-9-]+")))
                        val source = File(root, "dataset-$name.pdf")
                        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(source.readBytes())
                            .joinToString("") { "%02x".format(it.toInt() and 255) }
                        require(hash == item.getString("sha256"))
                        val dpi = intent.getIntExtra("dpi", 300)
                        val pages = JSONArray()
                        val pageLabels = JSONArray()
                        val started = System.currentTimeMillis()
                        val row = JSONObject().put("name", name).put("source_hash", hash).put("dpi", dpi)
                        results.put(row)
                        // Timing options: threads / parallel override the device choice;
                        // nocache recognises again (no page cache, staff checkpoints or
                        // label cache); legacy reproduces the old flow (models loaded per
                        // page, 2 threads, one page at a time, part names on every page).
                        StaffCanvas.straighten = !intent.getBooleanExtra("nostraighten", false)
                        val legacy = intent.getBooleanExtra("legacy", false)
                        val noCache = intent.getBooleanExtra("nocache", false)
                        val settings = if (legacy) OmrPerformance.Settings(2, 1) else OmrPerformance.choose(this,
                            intent.getIntExtra("threads", -1).takeIf { it > 0 }, intent.getIntExtra("parallel", -1).takeIf { it > 0 })
                        row.put("threads", settings.threads).put("parallel_staves", settings.parallelStaves)
                            .put("legacy", legacy).put("nocache", noCache)
                            .put("avail_mem_mb", OmrPerformance.memory(this).availMem / 1048576)
                        if (noCache) File(filesDir, "recognition-layout/labels-v1-mlkit16/$hash").deleteRecursively()
                        val timings = JSONArray()
                        row.put("page_timings", timings)
                        var peakPss = 0L
                        fun samplePss() { peakPss = maxOf(peakPss, Debug.getPss()) }
                        try {
                            ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                                PdfRenderer(descriptor).use { pdf ->
                                    row.put("page_count", pdf.pageCount)
                                    val data = arrayOfNulls<Map<*, *>>(pdf.pageCount)
                                    if (!noCache) for (index in 0 until pdf.pageCount) {
                                        data[index] = cache.read(hash, index, dpi)?.let { cached ->
                                            if (hasCurrentLayout(cached)) cached else {
                                                @Suppress("UNCHECKED_CAST")
                                                val withLayout = (cached as Map<String, Any>) +
                                                    pdf.openPage(index).use { PdfOmrEngine.layoutForCached(it, dpi, cached) }
                                                cache.write(hash, index, dpi, withLayout)
                                                withLayout
                                            }
                                        }
                                    }
                                    val missing = (0 until pdf.pageCount).filter { data[it] == null }
                                    row.put("pages_recognised", missing.size)
                                    fun checkpoints(index: Int) = if (noCache) null
                                        else StaffCheckpointStore(File(filesDir, "recognition/staves"), "$hash:$dpi:$index")
                                    fun store(index: Int, page: RecognizedPdfPage) {
                                        samplePss()
                                        val symbols = page.symbolData()
                                        if (!noCache) cache.write(hash, index, dpi, symbols)
                                        data[index] = symbols
                                        timings.put(JSONObject(page.timing.mapValues { it.value }).put("page", index))
                                        row.put("completed_pages", data.count { it != null })
                                        File(root, "dataset-progress.json").writeText(results.toString())
                                    }
                                    val recogniseStart = System.currentTimeMillis()
                                    if (legacy) {
                                        for (index in missing) {
                                            val page = PdfOmrEngine(ModelStore(File(filesDir, "omr-models")), vocabulary, settings).use { engine ->
                                                pdf.openPage(index).use { engine.recognize(it, dpi, checkpoints = checkpoints(index)) }
                                            }
                                            store(index, page)
                                        }
                                    } else {
                                        PdfOmrEngine(ModelStore(File(filesDir, "omr-models")), vocabulary, settings).use { engine ->
                                            PagePipeline.run(pdf, missing, dpi, engine, { false }, ::checkpoints,
                                                { _, _, _, _ -> samplePss() }) { index, page -> store(index, page) }
                                        }
                                    }
                                    row.put("recognition_ms", System.currentTimeMillis() - recogniseStart)
                                    // Printed text: every page (legacy), else as the app reads it
                                    // (OmrBridge.recognizePage): the first three pages and pages
                                    // with a system larger than the usual size so far.
                                    val labelStart = System.currentTimeMillis()
                                    val sizesSeen = mutableMapOf<Int, Int>()
                                    for (index in 0 until pdf.pageCount) {
                                        val pageData = requireNotNull(data[index])
                                        pages.put(JSONObject(pageData))
                                        val sizes = (pageData["systems"] as? List<*>).orEmpty()
                                            .mapNotNull { ((it as? Map<*, *>)?.get("staves") as? List<*>)?.size }
                                        val usual = sizesSeen.maxByOrNull { it.value }?.key
                                        val changed = usual != null && sizes.any { it > usual }
                                        sizes.forEach { sizesSeen.merge(it, 1, Int::plus) }
                                        pageLabels.put(if (legacy || index < 3 || changed) pdf.openPage(index).use { page -> JSONObject(labels.read(hash, index, page)) }
                                            else JSONObject().put("labels", JSONArray()).put("warnings", JSONArray()))
                                    }
                                    row.put("labels_ms", System.currentTimeMillis() - labelStart)
                                    row.put("peak_pss_mb", peakPss / 1024)
                                    File(root, "dataset-$name-pages.json").writeText(pages.toString())
                                    File(root, "dataset-$name-labels.json").writeText(pageLabels.toString())
                                    row.put("page_cache_reused_last", missing.isEmpty())
                                    File(root, "dataset-progress.json").writeText(results.toString())
                                }
                            }
                            row.put("status", "recognized")
                        } catch (e: Exception) {
                            row.put("status", "failed").put("error", e.toString())
                        }
                        row.put("elapsed_ms", System.currentTimeMillis() - started)
                        File(root, "dataset-progress.json").writeText(results.toString())
                    }
                    output.writeText(JSONObject().put("dataset_complete", true).put("pieces", results).toString())
                    return@execute
                }
                if (intent.getStringExtra("mode") == "project-test") {
                    val directory = File(filesDir, "projects-selftest/${java.util.UUID.randomUUID()}")
                    val store = jp.choiromr.mobile.ProjectStore(directory)
                    val first = """{"title":"保存検証","staves":[{"id":"S1","measures":[]}]}"""
                    val id = store.save(null, first)
                    check(JSONObject(store.load(id)).getString("title") == "保存検証")
                    store.save(id, first.replace("保存検証", "更新済み"))
                    check(JSONObject(jp.choiromr.mobile.ProjectStore(directory).load(id)).getString("title") == "更新済み")
                    check(store.list().size == 1)
                    try { store.save(id, "invalid json"); error("Invalid save accepted") } catch (_: org.json.JSONException) { }
                    check(JSONObject(store.load(id)).getString("title") == "更新済み")
                    output.writeText(JSONObject().put("project_verified", true).toString())
                    return@execute
                }
                if (intent.getStringExtra("mode") == "cache-export") {
                    val hash = requireNotNull(intent.getStringExtra("hash"))
                    val dpi = intent.getIntExtra("dpi", 300)
                    val count = intent.getIntExtra("pages", 0)
                    require(count in 1..1000)
                    val cache = RecognitionCache(File(filesDir, "recognition"))
                    val pages = JSONArray()
                    for (i in 0 until count) {
                        pages.put(JSONObject(requireNotNull(cache.read(hash, i, dpi)) { "Missing page ${i + 1}" }))
                    }
                    File(root, "recognized-pages.json").writeText(pages.toString())
                    output.writeText(JSONObject().put("exported_pages", pages.length()).toString())
                    return@execute
                }
                if (intent.getStringExtra("mode") == "cache-test") {
                    val directory = File(filesDir, "cache-selftest")
                    val cache = RecognitionCache(directory)
                    val hash = "a".repeat(64)
                    val data = mapOf<String, Any>("width" to 1920, "height" to 2000, "warnings" to listOf("確認"),
                        "staves" to listOf(mapOf("crop" to listOf(0, 0, 100, 100), "reachedEos" to true,
                            "symbols" to listOf(listOf("note_4", "C4", ".", ".", ".", ".")))))
                    cache.write(hash, 0, 300, data)
                    check(RecognitionCache(directory).read(hash, 0, 300) == data)
                    check(cache.read(hash, 0, 400) == null)
                    check(cache.read("b".repeat(64), 0, 300) == null)
                    File(directory, "${RecognitionCache.NAMESPACE}/$hash/300/0.bin").writeBytes(byteArrayOf(127))
                    check(cache.read(hash, 0, 300) == null)
                    cache.write(hash, 0, 300, data)
                    check(cache.read(hash, 0, 300) == data)
                    output.writeText(JSONObject().put("cache_verified", true).toString())
                    return@execute
                }
                if (intent.getStringExtra("mode") == "pdf-raster") {
                    val descriptor = ParcelFileDescriptor.open(File(root, "benchmark.pdf"), ParcelFileDescriptor.MODE_READ_ONLY)
                    val image = PdfRenderer(descriptor).use { pdf ->
                        pdf.openPage(intent.getIntExtra("page", 0)).use { page ->
                            PdfPageRasterizer.render(page, intent.getIntExtra("dpi", 300))
                        }
                    }
                    File(root, "page-raster.gray").writeBytes(image.first)
                    output.writeText(JSONObject().put("width", 1920).put("height", image.second).toString())
                    return@execute
                }
                if (intent.getStringExtra("mode") == "pdf-page") {
                    val vocabulary = SymbolVocabulary(assets.open("omr/vocabulary.json").use { it.readBytes() })
                    val descriptor = ParcelFileDescriptor.open(File(root, "benchmark.pdf"), ParcelFileDescriptor.MODE_READ_ONLY)
                    val outputPage = PdfRenderer(descriptor).use { pdf ->
                        pdf.openPage(intent.getIntExtra("page", 0)).use { page ->
                            PdfOmrEngine(ModelStore(File(filesDir, "omr-models-test")), vocabulary)
                                .use { it.recognize(page, intent.getIntExtra("dpi", 300)) }
                        }
                    }
                    val rows = JSONArray()
                    outputPage.page.staves.forEach { staff ->
                        val symbols = JSONArray()
                        staff.symbols.forEach { s -> symbols.put(JSONArray(listOf(s.rhythm, s.pitch, s.lift, s.position, s.articulation, s.slur))) }
                        val b = staff.crop
                        rows.put(JSONObject().put("lines", JSONArray(staff.geometry.lines))
                            .put("crop", JSONArray(listOf(b.left, b.top, b.right, b.bottom)))
                            .put("symbols", symbols).put("reached_eos", staff.decoding.reachedEos))
                    }
                    output.writeText(JSONObject().put("width", outputPage.width).put("height", outputPage.height)
                        .put("staves", rows).put("warnings", JSONArray(outputPage.page.warnings))
                        .put("pss_kib_after", Debug.getPss()).toString())
                    return@execute
                }
                if (intent.getStringExtra("mode") == "install-models") {
                    val store = ModelStore(File(filesDir, "omr-models-test"))
                    File(root, "model-bundle.zip").inputStream().use { store.install(it) }
                    output.writeText(JSONObject().put("verified", store.installed() != null).toString())
                    return@execute
                }
                if (intent.getStringExtra("mode") == "page") {
                    val width = intent.getIntExtra("width", 0)
                    val height = intent.getIntExtra("height", 0)
                    val gray = File(root, "page-segmentation.gray").readBytes()
                    val files = OmrModelFiles(File(root, "segnet.onnx"), File(root, "encoder.onnx"), File(root, "decoder.onnx"))
                    val vocabulary = SymbolVocabulary(assets.open("omr/vocabulary.json").use { it.readBytes() })
                    val page = PageOmr(files, vocabulary).recognize(gray, width, height, onStaff = { i, prepared, _ ->
                        File(root, "recognized-staff-$i.gray").writeBytes(prepared.pixels)
                    })
                    val rows = JSONArray()
                    page.staves.forEach { staff ->
                        val tokenArray = JSONArray()
                        val names = JSONArray()
                        staff.decoding.tokens.forEach { t -> tokenArray.put(JSONArray(listOf(t.rhythm, t.pitch, t.lift, t.position, t.articulation, t.slur))) }
                        staff.symbols.forEach { s -> names.put(JSONArray(listOf(s.rhythm, s.pitch, s.lift, s.position, s.articulation, s.slur))) }
                        val g = staff.geometry; val b = staff.crop
                        rows.put(JSONObject().put("lines", JSONArray(g.lines)).put("crop", JSONArray(listOf(b.left, b.top, b.right, b.bottom)))
                            .put("tokens", tokenArray).put("symbols", names).put("reached_eos", staff.decoding.reachedEos))
                    }
                    output.writeText(JSONObject().put("staves", rows).put("warnings", JSONArray(page.warnings)).toString())
                    Log.i("StaffBenchmark", "page complete: ${page.staves.size} staves")
                    return@execute
                }
                if (intent.getStringExtra("mode") in listOf("clahe", "canvas")) {
                    val width = intent.getIntExtra("width", 0)
                    val height = intent.getIntExtra("height", 0)
                    val gray = File(root, "page-segmentation.gray").readBytes()
                    val pixels = if (intent.getStringExtra("mode") == "clahe") {
                        StaffCanvas.clahe(gray, width, height)
                    } else {
                        val rect = PixelRect(intent.getIntExtra("left", 0), intent.getIntExtra("top", 0),
                            intent.getIntExtra("right", width), intent.getIntExtra("bottom", height))
                        StaffCanvas.canvas(gray, width, height, rect)
                    }
                    File(root, "image-adapter.gray").writeBytes(pixels)
                    output.writeText(JSONObject().put("bytes", pixels.size).toString())
                    return@execute
                }
                if (intent.getStringExtra("mode") == "geometry") {
                    val width = intent.getIntExtra("width", 0)
                    val height = intent.getIntExtra("height", 0)
                    val labels = File(root, "page-segmentation.labels").readBytes()
                    val staves = StaffGeometryDetector.detect(labels, width, height)
                    val array = JSONArray()
                    staves.forEach { s -> array.put(JSONObject().put("left", s.left).put("right", s.right)
                        .put("lines", JSONArray(s.lines)).put("spacing", s.spacing)
                        .put("support", s.stripSupport).put("inferred_line", s.inferredLine)) }
                    output.writeText(JSONObject().put("staves", array).toString())
                    Log.i("StaffBenchmark", "geometry complete: ${staves.size} staves")
                    return@execute
                }
                if (intent.getStringExtra("mode") == "segmentation") {
                    val width = intent.getIntExtra("width", 0)
                    val height = intent.getIntExtra("height", 0)
                    val gray = File(root, "page-segmentation.gray").readBytes()
                    val result = PageSegmentation(File(root, "segnet.onnx")).use { it.segment(gray, width, height) }
                    File(root, "page-segmentation.labels").writeBytes(result.labels)
                    output.writeText(JSONObject().put("patches", result.patches)
                        .put("inference_ms", result.inferenceMillis).put("pss_kib_after", Debug.getPss()).toString())
                    Log.i("StaffBenchmark", "segmentation complete: ${result.patches} patches")
                    return@execute
                }
                val steps = intent.getIntExtra("steps", 16).coerceIn(1, 608)
                val gray = File(root, "staff-canvas.gray").readBytes()
                val result = StaffDecoder(File(root, "encoder.onnx"), File(root, "decoder.onnx")).use {
                    it.decode(gray, steps)
                }
                val tokens = JSONArray()
                val names = JSONArray()
                val vocabulary = SymbolVocabulary(assets.open("omr/vocabulary.json").use { it.readBytes() })
                result.tokens.forEach { token ->
                    tokens.put(JSONArray(listOf(token.rhythm, token.pitch, token.lift,
                                                token.position, token.articulation, token.slur)))
                    val symbol = vocabulary.decode(token)
                    names.put(JSONArray(listOf(symbol.rhythm, symbol.pitch, symbol.lift,
                                               symbol.position, symbol.articulation, symbol.slur)))
                }
                val json = JSONObject().put("tokens", tokens).put("reached_eos", result.reachedEos)
                    .put("symbols", names)
                    .put("encoder_ms", result.encoderMillis).put("decoder_ms", result.decoderMillis)
                    .put("pss_kib_after", Debug.getPss())
                output.writeText(json.toString(), Charsets.UTF_8)
                Log.i("StaffBenchmark", "complete: ${result.tokens.size} tokens, eos=${result.reachedEos}")
            } catch (e: Exception) {
                output.writeText(JSONObject().put("error", e.toString()).toString(), Charsets.UTF_8)
                Log.e("StaffBenchmark", "failed", e)
            } finally {
                pool.shutdown()
                runOnUiThread { finish() }
            }
        }
    }
}
