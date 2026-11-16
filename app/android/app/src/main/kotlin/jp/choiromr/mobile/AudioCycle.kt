package jp.choiromr.mobile

/** Frame arithmetic shared by stream rendering and playback-head reporting. */
class AudioCycle(val frames: Long, val looping: Boolean, val offset: Long = 0, val loopStart: Long = 0) {
    init { require(frames > 0 && offset in 0..frames && loopStart in 0 until frames) }
    fun phase(generated: Long): Long {
        require(generated >= 0)
        return if (generated < frames) generated else loopStart + (generated - frames) % (frames - loopStart)
    }
    fun chunkSize(generated: Long, capacity: Int): Int {
        require(capacity > 0 && generated >= 0)
        if (!looping && generated >= frames) return 0
        return minOf(capacity.toLong(), frames - phase(generated)).toInt()
    }
    fun playbackPosition(played: Long): Long {
        require(played >= 0)
        return if (looping) phase(offset + played) else minOf(offset + played, frames)
    }
}
