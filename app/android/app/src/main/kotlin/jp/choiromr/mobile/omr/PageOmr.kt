package jp.choiromr.mobile.omr

import java.io.File

data class OmrModelFiles(val segmentation: File, val encoder: File, val decoder: File)
data class RecognizedStaff(val geometry: StaffGeometry, val crop: PixelRect, val decoding: DecodeResult,
                           val symbols: List<NamedSymbol>)
data class RecognizedPage(val staves: List<RecognizedStaff>, val warnings: List<String>)

/**
 * Experimental page-to-token pipeline. Input is a grayscale page already
 * resized to the recognition width. It does not yet assemble a playable score.
 *
 * The models are loaded on first use and kept until [close], so one instance
 * serves a whole conversion (loading and hash-checking 157 MB of models per
 * page was a large part of the time). [detectStaves] (segmentation) may run
 * on another thread than [recognize] (decoding), e.g. for the next page.
 * With [parallelStaves] > 1, that many staves are decoded at once, each with
 * its own decoder (more memory).
 */
class PageOmr(private val files: OmrModelFiles, private val vocabulary: SymbolVocabulary,
              private val threads: Int = 2, private val parallelStaves: Int = 1) : AutoCloseable {
    private var segmenter: PageSegmentation? = null
    private val decoders = mutableListOf<StaffDecoder>()
    private val checkpointLock = Any()

    @Synchronized private fun segmenter(): PageSegmentation =
        segmenter ?: PageSegmentation(files.segmentation, threads).also { segmenter = it }

    private fun decoder(slot: Int): StaffDecoder = synchronized(decoders) {
        while (decoders.size <= slot) decoders.add(StaffDecoder(files.encoder, files.decoder, threads))
        decoders[slot]
    }

    /** Segmentation and staff geometry; [timing] gets "clahe", "segmentation", "geometry" (ms). */
    fun detectStaves(gray: ByteArray, width: Int, height: Int, cancelled: () -> Boolean = { false },
                     timing: MutableMap<String, Long>? = null): List<StaffGeometry> {
        require(width == 1920) { "Input page must be prepared at width 1920 pixels" }
        require(height > 0 && width.toLong() * height == gray.size.toLong())
        if (cancelled()) throw InterruptedException("Recognition cancelled")
        var t = System.nanoTime()
        fun lap(name: String) { val now = System.nanoTime(); timing?.merge(name, (now - t) / 1_000_000, Long::plus); t = now }
        val adjusted = StaffCanvas.clahe(gray, width, height); lap("clahe")
        val labels = segmenter().segment(adjusted, width, height, cancelled).labels; lap("segmentation")
        return StaffGeometryDetector.detect(labels, width, height).also { lap("geometry") }
    }

    override fun close() {
        synchronized(this) { segmenter?.close(); segmenter = null }
        synchronized(decoders) { decoders.forEach { it.close() }; decoders.clear() }
    }

    private class Pixels(val bytes: ByteArray) {
        private val hash = bytes.contentHashCode()
        override fun hashCode() = hash
        override fun equals(other: Any?) = other is Pixels && other.bytes.contentEquals(bytes)
    }

    fun recognize(gray: ByteArray, width: Int, height: Int,
                  cancelled: () -> Boolean = { false },
                  onProgress: (String, Int, Int) -> Unit = { _, _, _ -> },
                  onStaff: (Int, PreparedStaff, DecodeResult) -> Unit = { _, _, _ -> },
                  checkpoints: StaffCheckpointStore? = null,
                  staves: List<StaffGeometry>? = null,
                  timing: MutableMap<String, Long>? = null): RecognizedPage {
        require(width == 1920) { "Input page must be prepared at width 1920 pixels" }
        require(height > 0 && width.toLong() * height == gray.size.toLong())
        if (cancelled()) throw InterruptedException("Recognition cancelled")
        onProgress("segmentation", 0, 1)
        val geometries = staves ?: detectStaves(gray, width, height, cancelled, timing)
        if (cancelled()) throw InterruptedException("Recognition cancelled")
        val warnings = mutableListOf<String>()
        if (geometries.isEmpty()) {
            warnings.add("五線を検出できませんでした。元のページを確認してください。")
            return RecognizedPage(emptyList(), warnings)
        }
        val output = mutableListOf<RecognizedStaff>()
        // Decodes by canvas content: the primary pass fills it (in parallel
        // when enabled); the sequential pass below reuses it.
        val memo = java.util.concurrent.ConcurrentHashMap<Pixels, DecodeResult>()
        fun decodeWith(slot: Int, prepared: PreparedStaff): DecodeResult {
            val key = Pixels(prepared.pixels)
            memo[key]?.let { return it }
            synchronized(checkpointLock) { checkpoints?.read(prepared.pixels) }?.let { memo[key] = it; return it }
            if (cancelled()) throw InterruptedException("Recognition cancelled")
            val result = decoder(slot).decode(prepared.pixels, cancelled = cancelled)
            synchronized(checkpointLock) { checkpoints?.write(prepared.pixels, result) }
            timing?.let { synchronized(it) {
                it.merge("encoder", result.encoderMillis, Long::plus); it.merge("decoder", result.decoderMillis, Long::plus)
                it.merge("staves", 1L, Long::plus)
            } }
            memo[key] = result
            return result
        }
        // Segmentation sometimes drops the left part of one staff. When both
        // neighbours agree, retain that area for inference and surface the
        // uncertainty rather than silently losing it.
        val primary = geometries.indices.map { index ->
            val geometry = geometries[index]
            val restored = StaffGeometryDetector.restoreLeft(geometry,
                (maxOf(0, index - 2)..minOf(geometries.lastIndex, index + 2))
                    .filter { it != index }.map { geometries[it] })
            restored to StaffCanvas.prepare(gray, width, height, restored,
                geometries.getOrNull(index - 1), geometries.getOrNull(index + 1))
        }
        val workers = parallelStaves.coerceIn(1, primary.size)
        if (workers > 1) {
            val next = java.util.concurrent.atomic.AtomicInteger(0)
            val pool = java.util.concurrent.Executors.newFixedThreadPool(workers)
            try {
                val jobs = (0 until workers).map { slot ->
                    pool.submit {
                        while (true) {
                            val i = next.getAndIncrement()
                            if (i >= primary.size || cancelled()) break
                            decodeWith(slot, primary[i].second)
                        }
                    }
                }
                for (job in jobs) {
                    try { job.get() } catch (e: java.util.concurrent.ExecutionException) { throw e.cause ?: e }
                }
            } finally { pool.shutdownNow() }
        }
        run {
            for (index in geometries.indices) {
                if (cancelled()) throw InterruptedException("Recognition cancelled")
                val before = geometries.getOrNull(index - 1)
                val after = geometries.getOrNull(index + 1)
                var geometry = primary[index].first
                if (geometry != geometries[index]) {
                    warnings.add("五線 ${index + 1}: 欠落を避けるため、左右の範囲を隣接する五線から補いました。")
                }
                if (geometry.inferredLine) warnings.add("五線 ${index + 1}: 1 本の位置を推定しました。")
                var canvas = primary[index].second
                onProgress("staff", index, geometries.size)
                fun decode(prepared: PreparedStaff): DecodeResult = decodeWith(0, prepared)
                var decoded = decode(canvas)
                var symbols = decoded.tokens.map(vocabulary::decode)
                val ends = BarlineEvidence.corroboratedEnds(gray, width, height, geometry, before, after)
                // Synchronized vocal stems can also align on three staves.
                // Require both neighbouring model decodes to independently
                // agree with the image count before changing this staff.
                val neighboursAgree = ends.isNotEmpty() &&
                    BarlineEvidence.measureCount(symbols) != ends.size &&
                    output.lastOrNull()?.let { BarlineEvidence.measureCount(it.symbols) == ends.size } == true &&
                    after != null && BarlineEvidence.measureCount(decode(StaffCanvas.prepare(
                        gray, width, height, after, geometry, geometries.getOrNull(index + 2)))
                        .tokens.map(vocabulary::decode)) == ends.size
                if (neighboursAgree) {
                    val originalNotes = symbols.count { it.rhythm.startsWith("note_") && it.pitch != "." }
                    val header = symbols.filter { it.rhythm.startsWith("clef_") || it.rhythm.startsWith("keySignature_") }
                    // A narrow crop can clip ledger notes/ottava marks. Keep the
                    // entire horizontal staff and retry with more vertical context.
                    // Accept only a complete decode agreeing with three image staves,
                    // preserving the header and at least the original note count.
                    for (extra in listOf(2.0, 6.0)) {
                        if (cancelled()) throw InterruptedException("Recognition cancelled")
                        val top = maxOf(
                            ((before?.lines?.lastOrNull() ?: 0.0) + geometry.spacing).toInt(),
                            (canvas.bounds.top - extra * geometry.spacing).toInt()).coerceAtLeast(0)
                        if (top >= canvas.bounds.top) continue
                        val bounds = canvas.bounds.copy(top = top)
                        val retryCanvas = PreparedStaff(StaffCanvas.canvasFor(gray, width, height, geometry, bounds), bounds)
                        val retry = decode(retryCanvas)
                        val retrySymbols = retry.tokens.map(vocabulary::decode)
                        if (retry.reachedEos && BarlineEvidence.measureCount(retrySymbols) == ends.size &&
                            retrySymbols.count { it.rhythm.startsWith("note_") && it.pitch != "." } >= originalNotes &&
                            retrySymbols.filter { it.rhythm.startsWith("clef_") || it.rhythm.startsWith("keySignature_") } == header) {
                            val oldCount = BarlineEvidence.measureCount(symbols)
                            canvas = retryCanvas
                            decoded = retry
                            symbols = retrySymbols
                            warnings.add("五線 ${index + 1}: 原譜と隣接する2本の五線の小節線を照合し、切り出し範囲を広げて再認識しました（$oldCount → ${ends.size}小節）。音符は原譜で確認してください。")
                            break
                        }
                    }
                    if (BarlineEvidence.measureCount(symbols) != ends.size) {
                        warnings.add("五線 ${index + 1}: 原譜の小節線は${ends.size}小節、認識記号は${BarlineEvidence.measureCount(symbols)}小節です。再認識では一致せず、原譜の確認が必要です。")
                    }
                }
                if (!decoded.reachedEos) warnings.add("五線 ${index + 1}: 記号の生成が上限に達しました。")
                output.add(RecognizedStaff(geometry, canvas.bounds, decoded, symbols))
                onStaff(index, canvas, decoded)
            }
        }
        onProgress("staff", geometries.size, geometries.size)
        return RecognizedPage(output, warnings)
    }
}
