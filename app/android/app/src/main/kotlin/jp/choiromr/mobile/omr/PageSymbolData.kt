package jp.choiromr.mobile.omr

fun RecognizedPdfPage.symbolData(): Map<String, Any> = mapOf(
    "staves" to page.staves.map { s -> mapOf(
        "lines" to s.geometry.lines, "left" to s.geometry.left, "right" to s.geometry.right,
        // (x, offset of the lines) along a tilted or bent staff; empty when straight.
        "profile" to s.geometry.profile.map { (x, o) -> listOf(Math.round(x * 10) / 10.0, Math.round(o * 100) / 100.0) },
        "crop" to listOf(s.crop.left, s.crop.top, s.crop.right, s.crop.bottom),
        "reachedEos" to s.decoding.reachedEos,
        "symbols" to s.symbols.mapIndexed { i, it ->
            val tokens = listOf(it.rhythm, it.pitch, it.lift, it.position, it.articulation, it.slur)
            // Attention x in page pixels (grand-staff timing); omitted when unknown.
            val x = s.decoding.tokens.getOrNull(i)?.x ?: Float.NaN
            if (x.isFinite()) tokens + StaffCanvas.pageX(s.crop, x.toDouble()) else tokens
        }
    ) }, "warnings" to page.warnings, "width" to width, "height" to height
) + (layout?.toData() ?: emptyMap()) +
    // Milliseconds per stage when this page was recognised (diagnostics only).
    (if (timing.isNotEmpty()) mapOf("timing" to timing.mapValues { it.value.toInt() }) else emptyMap())

/** True when a cached page carries the current layout analysis. */
fun hasCurrentLayout(data: Map<*, *>): Boolean =
    data["systems"] is List<*> && ((data["layout"] as? Map<*, *>)?.get("version") as? Int) == PdfOmrEngine.LAYOUT_VERSION
