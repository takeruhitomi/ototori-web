package jp.choiromr.mobile

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/** Foreground practice playback never resumes automatically after interruption. */
class AudioInterruptionGuard(private val activity: Activity, private val interrupted: (String) -> Unit) {
    private val manager = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var started = false
    private var held = false
    private val listener = AudioManager.OnAudioFocusChangeListener { change ->
        if (change < 0) interrupt("他の音声が優先されたため一時停止しました。")
    }
    private var request: AudioFocusRequest? = null
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                interrupt("音声出力先が変わったため一時停止しました。")
            }
        }
    }

    fun start() {
        if (started) return
        activity.volumeControlStream = AudioManager.STREAM_MUSIC
        val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        if (Build.VERSION.SDK_INT >= 33) activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else activity.registerReceiver(receiver, filter)
        started = true
    }

    @Suppress("DEPRECATION")
    fun acquire(): Boolean {
        if (!started) return false
        if (held) return true
        val result = if (Build.VERSION.SDK_INT >= 26) {
            val focus = request ?: AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
                .setWillPauseWhenDucked(true)
                .setOnAudioFocusChangeListener(listener, Handler(Looper.getMainLooper()))
                .build().also { request = it }
            manager.requestAudioFocus(focus)
        } else manager.requestAudioFocus(listener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
        held = result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        return held
    }

    @Suppress("DEPRECATION")
    fun release() {
        if (!held) return
        held = false
        if (Build.VERSION.SDK_INT >= 26) request?.let { manager.abandonAudioFocusRequest(it) }
        else manager.abandonAudioFocus(listener)
    }

    private fun interrupt(reason: String) {
        if (!held) return
        interrupted(reason)
        release()
    }

    fun stop() {
        if (!started) return
        interrupt("画面を離れたため一時停止しました。")
        activity.unregisterReceiver(receiver)
        started = false
    }
}
