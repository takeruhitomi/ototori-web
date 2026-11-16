package jp.choiromr.mobile.omr

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import kotlin.math.ceil
import kotlin.math.roundToInt

/** PDF is rendered at the requested resolution, then resized for homr. */
object PdfPageRasterizer {
    /**
     * Widest render. Recognition uses 1920 px, so twice that is ample; A4–A3
     * at 300 dpi (2480–3508 px) stay below it and render as before. Scans
     * stored with a huge page size (e.g. 2514 × 3607 pt, a 72-dpi image of
     * an A-size sheet) would otherwise need 10,000 × 15,000 px at 300 dpi.
     */
    const val MAX_RENDER_WIDTH = 3840

    /** Pixel size to render [pageWidth] × [pageHeight] pt at [dpi], capped at [MAX_RENDER_WIDTH]. */
    fun renderSize(pageWidth: Int, pageHeight: Int, dpi: Int): Pair<Int, Int> {
        require(pageWidth > 0 && pageHeight > 0) { "ページの大きさが不正です。" }
        val scale = minOf(dpi / 72.0, MAX_RENDER_WIDTH.toDouble() / pageWidth)
        return ceil(pageWidth * scale).toInt() to ceil(pageHeight * scale).toInt()
    }

    fun render(page: PdfRenderer.Page, dpi: Int, cancelled: () -> Boolean = { false }): Pair<ByteArray, Int> {
        require(dpi == 300 || dpi == 400)
        val (width, height) = renderSize(page.width, page.height, dpi)
        require(width > 0 && height > 0 && width.toLong() * height <= 40_000_000L) { "ページの縦横比が大きすぎます。" }
        val targetHeight = (height * (1920.0 / width)).roundToInt()
        require(targetHeight > 0 && 1920L * targetHeight <= 16_000_000L) { "ページの縦横比が大きすぎます。" }
        val source = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            source.eraseColor(Color.WHITE)
            page.render(source, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            if (cancelled()) throw InterruptedException("認識を中止しました。")
            val scaled = Bitmap.createScaledBitmap(source, 1920, targetHeight, true)
            try {
                val gray = ByteArray(1920 * targetHeight)
                val row = IntArray(1920)
                for (y in 0 until targetHeight) {
                    if (cancelled()) throw InterruptedException("認識を中止しました。")
                    scaled.getPixels(row, 0, 1920, 0, y, 1920, 1)
                    for (x in row.indices) {
                        val pixel = row[x]
                        val r = Color.red(pixel); val g = Color.green(pixel); val b = Color.blue(pixel)
                        gray[y * 1920 + x] = ((77 * r + 150 * g + 29 * b + 128) shr 8).toByte()
                    }
                }
                return gray to targetHeight
            } finally { if (scaled !== source) scaled.recycle() }
        } finally { source.recycle() }
    }
}
