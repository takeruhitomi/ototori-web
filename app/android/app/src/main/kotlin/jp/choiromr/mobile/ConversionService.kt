package jp.choiromr.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.graphics.pdf.PdfRenderer
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.os.SystemClock
import jp.choiromr.mobile.omr.ModelStore
import jp.choiromr.mobile.omr.OmrPerformance
import jp.choiromr.mobile.omr.PagePipeline
import jp.choiromr.mobile.omr.PdfOmrEngine
import jp.choiromr.mobile.omr.RecognitionCache
import jp.choiromr.mobile.omr.SymbolVocabulary
import jp.choiromr.mobile.omr.StaffCheckpointStore
import jp.choiromr.mobile.omr.symbolData
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONArray
import org.json.JSONObject

/** User-started, checkpointed inference; score assembly remains in shared Dart. */
class ConversionService : Service() {
    class Run(val id: String) {
        val cancelled = AtomicBoolean()
        val reason = AtomicReference<String?>(null)
    }
    companion object {
        private val active = AtomicReference<Run?>(null)
        const val START = "jp.choiromr.mobile.START_CONVERSION"
        const val CANCEL = "jp.choiromr.mobile.CANCEL_CONVERSION"
        private const val CHANNEL = "score-conversion"
        private const val NOTIFICATION = 42
        fun activeId(): String? = active.get()?.id
        fun reserve(id: String): Boolean = active.compareAndSet(null, Run(id))
        fun releaseReservation(id: String) { active.get()?.takeIf { it.id == id }?.let { active.compareAndSet(it, null) } }
        fun cancel(id: String?, reason: String? = null) {
            active.get()?.takeIf { it.id == id }?.let {
                if (reason != null) it.reason.set(reason)
                it.cancelled.set(true)
            }
        }
    }
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private var run: Run? = null
    private var wake: PowerManager.WakeLock? = null
    private var lastNotification = 0L
    private val notifications get() = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
    override fun onBind(intent: Intent?): IBinder? = null
    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= 26) notifications.createNotificationChannel(
            NotificationChannel(CHANNEL, "楽譜の認識", NotificationManager.IMPORTANCE_LOW))
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val id = intent?.getStringExtra("id")
        if (intent?.action == CANCEL) {
            cancel(id)
            if (run == null) stopSelf(startId)
            return START_NOT_STICKY
        }
        val token = active.get()?.takeIf { it.id == id }
        if (token == null) { stopSelf(startId); return START_NOT_STICKY }
        if (run != null) return START_NOT_STICKY
        run = token
        try { startForeground(NOTIFICATION, notification("認識を準備中", token.id, true)) }
        catch (e: Exception) {
            val store = ConversionStore(File(filesDir, "conversions"))
            try { recordFailure(store, token, JSONObject(store.load(token.id)), "変換を開始できません: ${e.message}") }
            catch (failure: Exception) { android.util.Log.e("ChoirConversion", "Cannot record start failure", failure) }
            run = null
            active.compareAndSet(token, null); stopSelf(startId)
            return START_NOT_STICKY
        }
        worker.execute { execute(token, startId) }
        return START_NOT_STICKY
    }

    private fun execute(token: Run, startId: Int) {
        val store = ConversionStore(File(filesDir, "conversions"))
        var data: JSONObject? = null
        var leased = false
        var result = "認識を中止しました"
        try {
            data = JSONObject(store.load(token.id))
            leased = RecognitionLease.acquire(token.id)
            check(leased) { "別の認識処理が実行中です。" }
            if (token.cancelled.get()) throw InterruptedException()
            acquireWake()
            val settings = data.getJSONObject("settings")
            val hash = settings.getString("source_hash")
            val dpi = settings.getInt("dpi")
            val count = settings.getInt("pages")
            val selected = if (settings.getBoolean("all_pages")) (0 until count).toList()
                else listOf(settings.getInt("selected_page"))
            val completed = mutableSetOf<Int>()
            val cache = RecognitionCache(File(filesDir, "recognition"))
            val vocabulary = SymbolVocabulary(assets.open("omr/vocabulary.json").use { it.readBytes() })
            persist(store, token.id, data, "running", completed)
            ParcelFileDescriptor.open(PdfSourceStore(File(filesDir, "sources")).file(hash), ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                PdfRenderer(descriptor).use { pdf ->
                    require(pdf.pageCount == count) { "PDF のページ数が保存設定と一致しません。" }
                    // Pages saved earlier count as done; the rest are recognised by one
                    // engine (models loaded once), the next page prepared while this
                    // one is decoded.
                    val missing = selected.filter { cache.read(hash, it, dpi) == null }
                    for (index in selected - missing.toSet()) completed.add(index)
                    if (completed.isNotEmpty()) persist(store, token.id, data, "running", completed)
                    PdfOmrEngine(ModelStore(File(filesDir, "omr-models")), vocabulary,
                        OmrPerformance.choose(this)).use { engine ->
                        PagePipeline.run(pdf, missing, dpi, engine, { token.cancelled.get() },
                            { index -> StaffCheckpointStore(File(filesDir, "recognition/staves"), "$hash:$dpi:$index") },
                            { index, stage, done, total -> progress("${index + 1} / $count ページ・$stage $done / $total", token.id) }
                        ) { index, output ->
                            cache.write(hash, index, dpi, output.symbolData())
                            completed.add(index)
                            persist(store, token.id, data, "running", completed)
                            progress("${completed.size} / ${selected.size} ページ完了", token.id, true)
                        }
                    }
                    if (token.cancelled.get()) throw InterruptedException()
                }
            }
            if (token.cancelled.get()) throw InterruptedException()
            persist(store, token.id, data, "recognized", completed)
            result = "ページの読み取りが終わりました。音鳥に戻ると曲を仕上げます"
        } catch (e: Exception) {
            result = if (token.cancelled.get() || e is InterruptedException) token.reason.get() ?: "認識を中止しました" else "認識に失敗しました: ${e.message}"
            data?.let { recordFailure(store, token, it, result) }
        } catch (e: OutOfMemoryError) {
            result = "メモリ不足で認識を中断しました。保存したページから再開できます"
            data?.let { recordFailure(store, token, it, result) }
        } finally {
            releaseWake()
            if (leased) RecognitionLease.release(token.id)
            main.post {
                stopForeground(STOP_FOREGROUND_REMOVE)
                try { notifications.notify(NOTIFICATION, notification(result, token.id, false)) } catch (_: SecurityException) { }
                if (run === token) run = null
                active.compareAndSet(token, null)
                // A notification CANCEL command has a newer startId. End the
                // idle service too; this main-thread block cannot race a start.
                stopSelf()
            }
        }
    }
    private fun persist(store: ConversionStore, id: String, data: JSONObject, status: String, completed: Set<Int>) {
        data.put("status", status).put("completed_pages", JSONArray(completed.sorted())).put("error", JSONObject.NULL)
        store.save(id, data.toString())
    }
    private fun recordFailure(store: ConversionStore, token: Run, data: JSONObject, reason: String) {
        try {
            data.put("status", if (token.cancelled.get()) "cancelled" else "failed").put("error", reason)
            store.save(token.id, data.toString())
        } catch (e: Exception) { android.util.Log.e("ChoirConversion", "Cannot save failure state", e) }
    }
    private fun progress(text: String, id: String, force: Boolean = false) {
        val now = SystemClock.elapsedRealtime()
        if (!force && now - lastNotification < 1000) return
        lastNotification = now
        try { notifications.notify(NOTIFICATION, notification(text, id, true)) } catch (_: SecurityException) { }
    }
    @Suppress("DEPRECATION")
    private fun notification(text: String, id: String, ongoing: Boolean): Notification {
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL) else Notification.Builder(this)
        builder.setSmallIcon(R.drawable.ic_stat_ototori).setColor(0xFF1E2A6E.toInt()).setContentTitle(if (ongoing) "楽譜を変換中" else "楽譜の変換").setContentText(text)
            .setContentIntent(open).setOnlyAlertOnce(true).setOngoing(ongoing).setAutoCancel(!ongoing)
        if (ongoing) {
            val cancel = PendingIntent.getService(this, 1, Intent(this, ConversionService::class.java).setAction(CANCEL).putExtra("id", id), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            builder.addAction(android.R.drawable.ic_menu_close_clear_cancel, "中止", cancel)
        }
        return builder.build()
    }
    @Synchronized private fun acquireWake() {
        wake = (getSystemService(POWER_SERVICE) as PowerManager).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "choiromr:conversion").apply {
            setReferenceCounted(false); acquire(6 * 60 * 60 * 1000L)
        }
    }
    @Synchronized private fun releaseWake() { wake?.let { if (it.isHeld) it.release() }; wake = null }
    override fun onTimeout(startId: Int, fgsType: Int) {
        run?.let { it.reason.set("OS の実行時間制限で中断しました。保存済みページから再開できます"); it.cancelled.set(true) }
        releaseWake(); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
    }
    override fun onDestroy() {
        run?.cancelled?.set(true)
        releaseWake(); worker.shutdown(); super.onDestroy()
    }
}
