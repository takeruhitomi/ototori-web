package jp.choiromr.mobile.omr

import android.app.ActivityManager
import android.content.Context

/**
 * How recognition uses the device: ONNX threads per model and how many
 * staves are decoded at once.
 *
 * Measured on the SM-X510 (4 fast + 4 slow cores; ANDROID_BROWSER_COMPARISON.md):
 * 4 threads with one decoder was fastest (-30% vs. the old 2 threads, model
 * reload per page). Two decoders were slower (2x2) or far slower (4x2, the
 * next page's segmentation also runs, so threads exceed the fast cores),
 * and each extra decoder costs about [EXTRA_DECODER_BYTES]. Parallel staves
 * are therefore never chosen automatically; [choose] accepts an explicit
 * value for benchmarks, and only when the memory check passes.
 */
object OmrPerformance {
    data class Settings(val threads: Int = 4, val parallelStaves: Int = 1) {
        init { require(threads in 1..16 && parallelStaves in 1..4) }
    }

    /** Peak PSS difference, 2 decoders vs. 1, on the SM-X510 (1.32 GB vs. 0.89 GB). */
    const val EXTRA_DECODER_BYTES = 450L * 1024 * 1024
    /** Free memory that must remain after the extra decoder (rendering, layout, the app itself). */
    const val MIN_SPARE_BYTES = 1024L * 1024 * 1024

    fun memory(context: Context): ActivityManager.MemoryInfo {
        val manager = context.getSystemService(ActivityManager::class.java)
        return ActivityManager.MemoryInfo().also { manager.getMemoryInfo(it) }
    }

    /** True when the device can hold a second decoder with memory to spare. */
    fun parallelAllowed(context: Context): Boolean {
        val manager = context.getSystemService(ActivityManager::class.java)
        val info = memory(context)
        return !manager.isLowRamDevice && !info.lowMemory &&
            info.availMem >= EXTRA_DECODER_BYTES + MIN_SPARE_BYTES
    }

    /** Settings for this device; [threads]/[parallel] override (benchmarks). */
    fun choose(context: Context, threads: Int? = null, parallel: Int? = null): Settings {
        val cores = Runtime.getRuntime().availableProcessors()
        val staves = if (parallel != null && parallel > 1 && parallelAllowed(context)) parallel else 1
        val perModel = threads ?: (cores / 2).coerceIn(1, 4)
        return Settings(perModel.coerceIn(1, 16), staves.coerceIn(1, 4))
    }
}
