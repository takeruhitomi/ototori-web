package jp.choiromr.mobile.omr

import org.opencv.android.OpenCVLoader
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import org.opencv.core.Rect
import org.opencv.core.Scalar
import org.opencv.core.Size
import org.opencv.imgproc.Imgproc
import kotlin.math.ceil
import kotlin.math.floor

data class PixelRect(val left: Int, val top: Int, val right: Int, val bottom: Int)
data class PreparedStaff(val pixels: ByteArray, val bounds: PixelRect)

/** Native OpenCV image adapters. Source is one-channel 8-bit grayscale. */
object StaffCanvas {
    private val ready: Boolean by lazy { OpenCVLoader.initLocal() }
    private fun checkReady() { check(ready) { "Could not load OpenCV" } }

    /** Same 8x8 / clip 1.0 CLAHE settings as the homr input adapter. */
    fun clahe(gray: ByteArray, width: Int, height: Int): ByteArray {
        checkReady()
        validate(gray, width, height)
        val source = Mat(height, width, CvType.CV_8UC1)
        val dest = Mat()
        val filter = Imgproc.createCLAHE(1.0, Size(8.0, 8.0))
        try {
            source.put(0, 0, gray)
            filter.apply(source, dest)
            return ByteArray(gray.size).also { dest.get(0, 0, it) }
        } finally { filter.collectGarbage(); dest.release(); source.release() }
    }

    /**
     * Binary ink mask (1 = ink) after background flattening and Otsu, as the
     * browser version's `systems.ink_mask`.
     */
    fun inkMask(gray: ByteArray, width: Int, height: Int): ByteArray {
        checkReady()
        validate(gray, width, height)
        val source = Mat(height, width, CvType.CV_8UC1)
        val background = Mat(); val bgFloat = Mat(); val srcFloat = Mat(); val ratio = Mat()
        val flat = Mat(); val binary = Mat()
        try {
            source.put(0, 0, gray)
            val k = maxOf(31, (minOf(width, height) / 20) or 1)
            Imgproc.GaussianBlur(source, background, Size(0.0, 0.0), k / 3.0)
            background.convertTo(bgFloat, CvType.CV_32F)
            Core.max(bgFloat, Scalar(1.0), bgFloat)
            source.convertTo(srcFloat, CvType.CV_32F)
            Core.divide(srcFloat, bgFloat, ratio, 255.0)
            // numpy's astype(uint8) truncates; OpenCV rounds. Shift by -0.5.
            ratio.convertTo(flat, CvType.CV_8U, 1.0, -0.5)
            Imgproc.threshold(flat, binary, 0.0, 1.0, Imgproc.THRESH_BINARY_INV or Imgproc.THRESH_OTSU)
            return ByteArray(gray.size).also { binary.get(0, 0, it) }
        } finally {
            binary.release(); flat.release(); ratio.release(); srcFloat.release(); bgFloat.release()
            background.release(); source.release()
        }
    }

    /**
     * Prepare a detected staff. A tilted or bent staff ([StaffGeometry.bent])
     * is straightened column by column before cropping (see [straightCrop]);
     * piano grand-staff grouping is intentionally a separate operation.
     */
    fun prepare(gray: ByteArray, width: Int, height: Int, staff: StaffGeometry,
                previous: StaffGeometry?, next: StaffGeometry?): PreparedStaff {
        validate(gray, width, height)
        require(staff.lines.size == 5 && staff.spacing > 0)
        val left = floor(staff.left - 2 * staff.spacing).toInt().coerceIn(0, width - 1)
        val right = ceil(staff.right + 2 * staff.spacing).toInt().coerceIn(left + 1, width)
        val topLimit = previous?.lines?.lastOrNull() ?: 0.0
        val bottomLimit = next?.lines?.firstOrNull() ?: height.toDouble()
        val top = floor(maxOf(topLimit, staff.lines.first() - 4 * staff.spacing)).toInt().coerceIn(0, height - 1)
        val bottom = ceil(minOf(bottomLimit, staff.lines.last() + 4 * staff.spacing)).toInt().coerceIn(top + 1, height)
        val bounds = PixelRect(left, top, right, bottom)
        return PreparedStaff(canvasFor(gray, width, height, staff, bounds), bounds)
    }

    /** Straightening switch for A/B measurements (debug benchmark only). */
    @Volatile var straighten = true

    /** [canvas] of [rect], straightened first when the staff is tilted or bent. */
    fun canvasFor(gray: ByteArray, width: Int, height: Int, staff: StaffGeometry, rect: PixelRect): ByteArray {
        if (!straighten || !staff.bent) return canvas(gray, width, height, rect)
        val w = rect.right - rect.left; val h = rect.bottom - rect.top
        return canvas(straightCrop(gray, width, height, staff, rect), w, h, PixelRect(0, 0, w, h))
    }

    /**
     * The pixels of [rect] with every column moved vertically by the staff's
     * offset there, so its lines run level at [StaffGeometry.lines] (linear
     * interpolation; white outside the page). Columns keep their x, so page
     * x positions of the decoded symbols are unchanged.
     */
    fun straightCrop(gray: ByteArray, width: Int, height: Int, staff: StaffGeometry, rect: PixelRect): ByteArray {
        validate(gray, width, height)
        val w = rect.right - rect.left; val h = rect.bottom - rect.top
        val out = ByteArray(w * h)
        for (dx in 0 until w) {
            val x = rect.left + dx
            val shift = staff.offsetAt(x + 0.5)
            for (dy in 0 until h) {
                val sy = rect.top + dy + shift
                val y0 = floor(sy).toInt(); val t = sy - y0
                fun at(y: Int): Double = if (y in 0 until height) (gray[y * width + x].toInt() and 0xff).toDouble() else 255.0
                out[dy * w + dx] = Math.round(at(y0) * (1 - t) + at(y0 + 1) * t).toInt().coerceIn(0, 255).toByte()
            }
        }
        return out
    }

    /** Size of a crop resized into the decoder canvas, keeping its aspect ratio. */
    fun fittedSize(cropWidth: Int, cropHeight: Int): Pair<Int, Int> {
        val canvasWidth = StaffDecoder.WIDTH
        val canvasHeight = StaffDecoder.HEIGHT
        return if (cropHeight.toDouble() / cropWidth > canvasHeight.toDouble() / canvasWidth) {
            (cropWidth.toDouble() / cropHeight * canvasHeight).toInt().coerceAtLeast(1) to canvasHeight
        } else {
            canvasWidth to (cropHeight.toDouble() / cropWidth * canvasWidth).toInt().coerceAtLeast(1)
        }
    }

    /** Canvas x (left-aligned, as [canvas] places the crop) -> page x, one decimal. */
    fun pageX(rect: PixelRect, canvasX: Double): Double {
        val (fittedWidth, _) = fittedSize(rect.right - rect.left, rect.bottom - rect.top)
        return Math.round((rect.left + canvasX * (rect.right - rect.left) / fittedWidth) * 10) / 10.0
    }

    /** Resize a rectangular crop as homr does and center it vertically on white. */
    fun canvas(gray: ByteArray, width: Int, height: Int, rect: PixelRect): ByteArray {
        checkReady()
        validate(gray, width, height)
        require(rect.left >= 0 && rect.top >= 0 && rect.right <= width && rect.bottom <= height &&
                rect.right > rect.left && rect.bottom > rect.top)
        val cropWidth = rect.right - rect.left
        val cropHeight = rect.bottom - rect.top
        val canvasWidth = StaffDecoder.WIDTH
        val canvasHeight = StaffDecoder.HEIGHT
        val (fittedWidth, fittedHeight) = fittedSize(cropWidth, cropHeight)
        val source = Mat(height, width, CvType.CV_8UC1)
        val resized = Mat()
        val target = Mat(canvasHeight, canvasWidth, CvType.CV_8UC1, Scalar(255.0))
        var crop: Mat? = null
        var destination: Mat? = null
        try {
            source.put(0, 0, gray)
            crop = source.submat(Rect(rect.left, rect.top, cropWidth, cropHeight))
            Imgproc.resize(crop, resized, Size(fittedWidth.toDouble(), fittedHeight.toDouble()))
            val y = (canvasHeight - fittedHeight) / 2
            destination = target.submat(Rect(0, y, fittedWidth, fittedHeight))
            resized.copyTo(destination)
            return ByteArray(canvasWidth * canvasHeight).also { target.get(0, 0, it) }
        } finally {
            destination?.release(); crop?.release(); target.release(); resized.release(); source.release()
        }
    }

    private fun validate(gray: ByteArray, width: Int, height: Int) {
        require(width > 0 && height > 0 && width.toLong() * height <= 16_000_000L)
        require(gray.size == width * height)
    }
}
