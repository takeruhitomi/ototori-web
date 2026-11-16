package jp.choiromr.mobile

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.net.Uri
import androidx.core.content.FileProvider
import android.os.Debug
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import jp.choiromr.mobile.omr.ModelStore
import jp.choiromr.mobile.omr.RecognitionCache
import jp.choiromr.mobile.omr.PdfOmrEngine
import jp.choiromr.mobile.omr.SymbolVocabulary
import jp.choiromr.mobile.omr.StaffCheckpointStore
import jp.choiromr.mobile.omr.PageTextReader
import jp.choiromr.mobile.omr.symbolData
import jp.choiromr.mobile.omr.hasCurrentLayout
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.sin
import kotlin.math.pow
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    private data class PianoSample(val pitch: Int, val data: ShortArray)
    private data class AudioEvent(val pitch: Int, val start: Int, val duration: Int, val piano: Boolean, val gain: Double, val legato: Boolean,
                                  val part: String, val accent: Boolean, val cents: Double = 0.0)
    private data class RenderedNote(val first: Long, val last: Long, val frequency: Double,
                                    val sample: ShortArray?, val sampleStep: Double, val gain: Double, val legato: Boolean,
                                    val part: String, val piano: Boolean, val accent: Boolean)
    private val audioMixer = AtomicReference(AudioMixer())
    private val executor = Executors.newSingleThreadExecutor()
    private var pendingPicker: MethodChannel.Result? = null
    private var pendingPdfs: MethodChannel.Result? = null
    private var descriptor: ParcelFileDescriptor? = null
    private var renderer: PdfRenderer? = null
    private var pdfHash: String? = null
    private var pendingScore: MethodChannel.Result? = null
    private var pendingExport: MethodChannel.Result? = null
    private var exportBytes: ByteArray? = null
    private var exportFile: File? = null
    private var pendingBackup: MethodChannel.Result? = null
    private var pendingModels: MethodChannel.Result? = null
    private val audioExecutor = Executors.newSingleThreadExecutor()
    private val audioGeneration = AtomicInteger()
    private val audioPositionMs = AtomicLong()
    private val audioPlaying = AtomicBoolean()
    private val audioError = AtomicReference<String?>(null)
    private val audioInterruption = AtomicReference<String?>(null)
    private val audioGuard by lazy { AudioInterruptionGuard(this) { reason ->
        audioGeneration.incrementAndGet(); audioPlaying.set(false); audioInterruption.set(reason)
    } }
    private val recognitionRunning = AtomicBoolean()
    private val recognitionCancelled = AtomicBoolean()
    private var pianoSamples: List<PianoSample>? = null

    // A song file received from another app, staged and waiting for the UI.
    private var incomingChannel: MethodChannel? = null
    private var incoming: Map<String, String>? = null
    private var incomingError: String? = null

    private fun receive(intent: Intent?) {
        val uri: Uri = when (intent?.action) {
            Intent.ACTION_VIEW -> intent.data
            Intent.ACTION_SEND -> intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else -> null
        } ?: return
        // Handle each delivery once (not again after a configuration change).
        intent?.action = null
        executor.execute {
            try {
                val staged = requireNotNull(contentResolver.openInputStream(uri)) { "ファイルを開けません。" }
                    .use { ProjectBackupStore(filesDir, cacheDir).stage(it) }
                runOnUiThread {
                    // A newer file replaces one the UI has not taken yet.
                    incoming?.get("token")?.let { old -> executor.execute { ProjectBackupStore(filesDir, cacheDir).discard(old) } }
                    incoming = staged; incomingError = null
                    incomingChannel?.invokeMethod("incomingProject", null)
                }
            } catch (e: Exception) {
                runOnUiThread { incomingError = "音鳥の曲ファイルとして開けませんでした（${e.message}）。"; incomingChannel?.invokeMethod("incomingProject", null) }
            } catch (e: OutOfMemoryError) {
                runOnUiThread { incomingError = "メモリ不足で曲ファイルを開けませんでした。"; incomingChannel?.invokeMethod("incomingProject", null) }
            }
        }
    }

    /** A file name for a song title: no path or reserved characters. */
    private fun shareName(title: String): String =
        title.replace(Regex("""[\\/:*?"<>|\s]+"""), "_").trim('_').take(60).ifEmpty { "音鳥の曲" }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receive(intent)
    }

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        incomingChannel = MethodChannel(engine.dartExecutor.binaryMessenger, "jp.choiromr.mobile/incoming").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    // Returns {token, text}, {error} or null, once.
                    "takeIncomingProject" -> {
                        val value: Map<String, String>? = incomingError?.let { mapOf("error" to it) } ?: incoming
                        incoming = null; incomingError = null
                        result.success(value)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        receive(intent)
        MethodChannel(engine.dartExecutor.binaryMessenger, "jp.choiromr.mobile/omr").setMethodCallHandler { call, result ->
            when (call.method) {
                "readPageLabels" -> executor.execute {
                    try {
                        val index = requireNotNull(call.argument<Int>("page"))
                        val pdf = requireNotNull(renderer)
                        require(index in 0 until pdf.pageCount)
                        val labels = pdf.openPage(index).use { page ->
                            PageTextReader(File(filesDir, "recognition-layout")).read(requireNotNull(pdfHash), index, page)
                        }
                        runOnUiThread { result.success(labels) }
                    } catch (e: Exception) { runOnUiThread { result.error("layout", "声部名を読み取れません: ${e.message}", null) } }
                    catch (e: OutOfMemoryError) { runOnUiThread { result.error("memory", "声部名の読み取りでメモリが不足しました。", null) } }
                }
                "modelsReady" -> executor.execute {
                    try {
                        val store = ModelStore(File(filesDir, "omr-models"))
                        var ready = store.installed() != null
                        if (!ready && assets.list("omr")?.contains("models.zip") == true) {
                            assets.open("omr/models.zip").use { store.install(it) }
                            ready = true
                        }
                        runOnUiThread { result.success(ready) }
                    } catch (e: Exception) { runOnUiThread { result.error("models", e.message, null) } }
                }
                "importModels" -> {
                    if (pendingModels != null) { result.error("busy", "モデルの選択中です。", null); return@setMethodCallHandler }
                    pendingModels = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/zip"
                        }, 20)
                    } catch (e: Exception) { pendingModels = null; result.error("picker", e.message, null) }
                }
                "cancel" -> { recognitionCancelled.set(true); ConversionService.cancel(call.argument<String>("jobId")); result.success(null) }
                "recognizePage" -> {
                    val page = call.argument<Int>("page") ?: -1
                    val dpi = call.argument<Int>("dpi") ?: 0
                    if (dpi !in listOf(300, 400) || page < 0) {
                        result.error("input", "ページまたは解像度が不正です。", null); return@setMethodCallHandler
                    }
                    if (ConversionService.activeId() != null) {
                        result.error("busy", "保存した変換ジョブが実行中です。", null); return@setMethodCallHandler
                    }
                    if (!recognitionRunning.compareAndSet(false, true)) {
                        result.error("busy", "別の認識が実行中です。", null); return@setMethodCallHandler
                    }
                    recognitionCancelled.set(false)
                    executor.execute {
                        var leased = false
                        try {
                            val pdf = requireNotNull(renderer) { "PDFを選択してください。" }
                            require(page in 0 until pdf.pageCount) { "ページ番号が範囲外です。" }
                            val hash = requireNotNull(pdfHash)
                            val cache = RecognitionCache(File(filesDir, "recognition"))
                            val cached = cache.read(hash, page, dpi)
                            if (cached != null) {
                                val complete = if (hasCurrentLayout(cached)) cached else {
                                    // Pages saved before the layout analysis: render the
                                    // page again (no model inference) and add the systems.
                                    @Suppress("UNCHECKED_CAST")
                                    val base = (cached as Map<String, Any>)
                                    val withLayout = base + pdf.openPage(page).use { PdfOmrEngine.layoutForCached(it, dpi, cached) }
                                    cache.write(hash, page, dpi, withLayout)
                                    withLayout
                                }
                                runOnUiThread { result.success(complete) }
                                return@execute
                            }
                            leased = RecognitionLease.acquire("activity")
                            check(leased) { "別の認識処理が実行中です。" }
                            val vocabulary = SymbolVocabulary(assets.open("omr/vocabulary.json").use { it.readBytes() })
                            val output = PdfOmrEngine(ModelStore(File(filesDir, "omr-models")), vocabulary,
                                jp.choiromr.mobile.omr.OmrPerformance.choose(this@MainActivity)).use { engine ->
                                pdf.openPage(page).use { pdfPage ->
                                    engine.recognize(pdfPage, dpi, cancelled = { recognitionCancelled.get() },
                                        checkpoints = StaffCheckpointStore(File(filesDir, "recognition/staves"), "$hash:$dpi:$page"))
                                }
                            }
                            val data = output.symbolData()
                            cache.write(hash, page, dpi, data)
                            runOnUiThread { result.success(data) }
                        } catch (e: Exception) {
                            val code = if (e is InterruptedException) "cancelled" else "recognition"
                            runOnUiThread { result.error(code, "認識を完了できません: ${e.message}", null) }
                        } catch (e: OutOfMemoryError) {
                            runOnUiThread { result.error("memory", "メモリが足りずページを認識できませんでした。", null) }
                        } finally { if (leased) RecognitionLease.release("activity"); recognitionRunning.set(false) }
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "jp.choiromr.mobile/score").setMethodCallHandler { call, result ->
            when (call.method) {
                // Lets the mixer handle on the right edge win over the system back
                // gesture. Rects arrive in logical pixels; an empty list clears.
                "setGestureExclusion" -> {
                    val density = resources.displayMetrics.density
                    val rects = (call.argument<List<List<Double>>>("rects") ?: emptyList()).map {
                        android.graphics.Rect((it[0] * density).toInt(), (it[1] * density).toInt(), (it[2] * density).toInt(), (it[3] * density).toInt())
                    }
                    window.decorView.systemGestureExclusionRects = rects
                    result.success(null)
                }
                // Display preferences (color set, light/dark). Small JSON, atomic replace.
                "loadAppSettings", "saveAppSettings" -> executor.execute {
                    try {
                        val file = android.util.AtomicFile(File(filesDir, "app_settings.json"))
                        val value: Any? = if (call.method == "loadAppSettings") {
                            if (file.baseFile.exists()) file.readFully().toString(Charsets.UTF_8) else null
                        } else {
                            val text = requireNotNull(call.argument<String>("text"))
                            require(text.length < 10_000) { "Settings are too large" }
                            org.json.JSONObject(text)
                            val stream = file.startWrite()
                            try { stream.write(text.toByteArray(Charsets.UTF_8)); file.finishWrite(stream) }
                            catch (e: Exception) { file.failWrite(stream); throw e }
                            null
                        }
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) { runOnUiThread { result.error("settings", "設定を保存・読み込みできません: ${e.message}", null) } }
                }
                "exportProjectBackup" -> {
                    val text = call.argument<String>("text")
                    if (pendingExport != null || text == null) {
                        result.error("backup", "保存先を選択中か、楽譜がありません。", null); return@setMethodCallHandler
                    }
                    pendingExport = result
                    executor.execute {
                        try {
                            check(!RecognitionLease.busy() && ConversionService.activeId() == null) { "認識が終了してからバックアップしてください。" }
                            val archive = ProjectBackupStore(filesDir, cacheDir).prepare(text)
                            runOnUiThread {
                                try {
                                    check(!isFinishing && !isDestroyed)
                                    exportFile = archive
                                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                        addCategory(Intent.CATEGORY_OPENABLE); type = "application/zip"
                                        putExtra(Intent.EXTRA_TITLE, "choir-project.zip")
                                    }, 19)
                                } catch (e: Exception) {
                                    archive.delete(); exportFile = null; pendingExport = null
                                    result.error("backup", "バックアップを保存できません: ${e.message}", null)
                                }
                            }
                        } catch (e: Exception) { runOnUiThread { pendingExport = null; result.error("backup", "バックアップを作成できません: ${e.message}", null) } }
                        catch (e: OutOfMemoryError) { runOnUiThread { pendingExport = null; result.error("memory", "メモリ不足でバックアップを作成できませんでした。", null) } }
                    }
                }
                "shareProject" -> {
                    val text = call.argument<String>("text")
                    val title = call.argument<String>("title") ?: ""
                    if (text == null) { result.error("share", "楽譜がありません。", null); return@setMethodCallHandler }
                    executor.execute {
                        try {
                            check(!RecognitionLease.busy() && ConversionService.activeId() == null) { "認識が終了してから共有してください。" }
                            val archive = ProjectBackupStore(filesDir, cacheDir).prepare(text)
                            val folder = File(cacheDir, "shared").apply { mkdirs(); listFiles()?.forEach { it.delete() } }
                            val file = File(folder, "${shareName(title)}.ototori")
                            if (!archive.renameTo(file)) { archive.copyTo(file, true); archive.delete() }
                            runOnUiThread {
                                try {
                                    val uri = FileProvider.getUriForFile(this, "$packageName.share", file)
                                    val send = Intent(Intent.ACTION_SEND).apply {
                                        type = "application/octet-stream"
                                        putExtra(Intent.EXTRA_STREAM, uri)
                                        putExtra(Intent.EXTRA_SUBJECT, title)
                                        clipData = android.content.ClipData.newRawUri(title, uri)
                                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                    }
                                    startActivity(Intent.createChooser(send, "曲を共有"))
                                    result.success(true)
                                } catch (e: Exception) { result.error("share", "共有できません: ${e.message}", null) }
                            }
                        } catch (e: Exception) { runOnUiThread { result.error("share", "共有ファイルを作れません: ${e.message}", null) } }
                        catch (e: OutOfMemoryError) { runOnUiThread { result.error("memory", "メモリ不足で共有ファイルを作れませんでした。", null) } }
                    }
                }
                "pickProjectBackup" -> {
                    if (pendingBackup != null) { result.error("backup", "バックアップを選択中です。", null); return@setMethodCallHandler }
                    pendingBackup = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE); type = "application/zip"
                        }, 22)
                    } catch (e: Exception) { pendingBackup = null; result.error("backup", e.message, null) }
                }
                "commitProjectBackup", "discardProjectBackup" -> executor.execute {
                    try {
                        val token = requireNotNull(call.argument<String>("token"))
                        val store = ProjectBackupStore(filesDir, cacheDir)
                        if (call.method == "commitProjectBackup") {
                            check(!RecognitionLease.busy() && ConversionService.activeId() == null) { "認識が終了してから復元してください。" }
                            store.commit(token)
                        } else store.discard(token)
                        runOnUiThread { result.success(null) }
                    } catch (e: Exception) { runOnUiThread { result.error("backup", "バックアップを復元できません: ${e.message}", null) } }
                    catch (e: OutOfMemoryError) { runOnUiThread { result.error("memory", "メモリ不足で復元できませんでした。", null) } }
                }
                "listProjects", "loadProject", "saveProject", "deleteProject" -> executor.execute {
                    try {
                        val store = ProjectStore(File(filesDir, "projects"))
                        val value: Any = when (call.method) {
                            "listProjects" -> store.list()
                            "loadProject" -> store.load(requireNotNull(call.argument<String>("id")))
                            "deleteProject" -> store.delete(requireNotNull(call.argument<String>("id")))
                            else -> store.save(call.argument<String>("id"), requireNotNull(call.argument<String>("text")))
                        }
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) { runOnUiThread { result.error("project", "楽譜の保存・読み込みに失敗しました: ${e.message}", null) } }
                }
                "pick" -> {
                    if (pendingScore != null) { result.error("busy", "ファイル選択中です。", null); return@setMethodCallHandler }
                    pendingScore = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE); type = "application/json"
                        }, 18)
                    } catch (e: Exception) { pendingScore = null; result.error("picker", e.message, null) }
                }
                "save", "saveMidi", "saveMusicXml" -> {
                    val midi = call.method == "saveMidi"
                    val xml = call.method == "saveMusicXml"
                    val value = if (midi) call.argument<ByteArray>("bytes") else call.argument<String>("text")?.toByteArray(Charsets.UTF_8)
                    if (pendingExport != null || value == null || value.size > 10_000_000) {
                        result.error("save", "書き出すデータが大きすぎるか、保存先を選択中です。", null); return@setMethodCallHandler
                    }
                    pendingExport = result; exportBytes = value
                    try {
                        val suggested = call.argument<String>("name")
                        val filename = if (midi && suggested != null && suggested.matches(Regex("[a-zA-Z0-9_-]+\\.mid"))) suggested
                            else if (midi) "choir-score.mid" else if (xml) "choir-score.musicxml" else "score-edited.json"
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                            // Some Android providers map audio/midi to .rtx and
                            // append it to .mid; x-midi preserves the MIDI suffix.
                            addCategory(Intent.CATEGORY_OPENABLE); type = if (midi) "audio/x-midi" else if (xml) "application/vnd.recordare.musicxml+xml" else "application/json"
                            putExtra(Intent.EXTRA_TITLE, filename)
                        }, 19)
                    } catch (e: Exception) { pendingExport = null; exportBytes = null; result.error("save", e.message, null) }
                }
                "playbackStatus" -> result.success(mapOf("playing" to audioPlaying.get(), "positionMs" to audioPositionMs.get(), "error" to audioError.get(), "interruption" to audioInterruption.get()))
                "stop" -> { audioGeneration.incrementAndGet(); audioPlaying.set(false); audioGuard.release(); result.success(null) }
                "updateMixer" -> try {
                    audioMixer.set(AudioMixer.parse(call.arguments as Map<*, *>)); result.success(null)
                } catch (e: Exception) { result.error("audio", "ミキサー設定が不正です: ${e.message}", null) }
                "play" -> {
                    try {
                        val raw = call.argument<List<Map<String, Any>>>("events") ?: emptyList()
                        require(raw.size <= 50000)
                        val defaultPiano = call.argument<Boolean>("piano") == true
                        val lengthMs = call.argument<Int>("lengthMs") ?: 0
                        val loop = call.argument<Boolean>("loop") == true
                        val offsetMs = call.argument<Int>("offsetMs") ?: 0
                        val loopStartMs = call.argument<Int>("loopStartMs") ?: 0
                        require(offsetMs in 0..lengthMs)
                        require(lengthMs in 0..1800000)
                        require(loopStartMs >= 0 && (lengthMs == 0 || loopStartMs < lengthMs))
                        audioMixer.set(AudioMixer.parse(call.argument<Map<String, Any>>("mixer") ?: emptyMap<String, Any>()))
                        val events = raw.map { e ->
                            val pitch = requireNotNull(e["pitch"] as? Int); val start = requireNotNull(e["start"] as? Int); val duration = requireNotNull(e["duration"] as? Int)
                            val piano = e["piano"] as? Boolean ?: defaultPiano
                            val gain = (e["gain"] as? Number)?.toDouble() ?: 1.0
                            val legato = e["legato"] as? Boolean ?: false
                            require(pitch in 0..127 && start >= 0 && duration > 0 && start.toLong() + duration <= 1800000)
                            require(gain.isFinite() && gain in 0.0..1.0)
                            // Just-intonation offset; the written pitch stays as sent.
                            val cents = (e["cents"] as? Number)?.toDouble() ?: 0.0
                            require(cents.isFinite() && cents in -200.0..200.0)
                            AudioEvent(pitch, start, duration, piano, gain, legato, e["partId"] as? String ?: "", e["accent"] == true, cents)
                        }
                        check(audioGuard.acquire()) { "音声出力の優先権を取得できません。画面を開いてから再試行してください。" }
                        recognitionCancelled.set(true)
                        ConversionService.cancel(ConversionService.activeId(), "再生を優先するため認識を中断しました。保存済みページから再開できます。")
                        val generation = audioGeneration.incrementAndGet()
                        audioInterruption.set(null)
                        audioPositionMs.set(offsetMs.toLong()); audioPlaying.set(true); audioError.set(null)
                        audioExecutor.execute {
                            var replied = false
                            try {
                                val samples = loadPianoSamples()
                                if (audioGeneration.get() == generation) audioPositionMs.set(offsetMs.toLong())
                                replied = true
                                runOnUiThread { result.success(null) }
                                playPreview(events, generation, samples, lengthMs, loop, offsetMs, loopStartMs)
                            } catch (e: Exception) {
                                if (audioGeneration.get() == generation) audioError.set(e.message ?: "音声出力を開始できません。")
                                android.util.Log.e("ChoirAudio", "Preview failed", e)
                                if (!replied) runOnUiThread { result.error("audio", "音源を読み込めません: ${e.message}", null) }
                            } finally {
                                if (audioGeneration.get() == generation) audioPlaying.set(false)
                                runOnUiThread { if (audioGeneration.get() == generation) audioGuard.release() }
                            }
                        }
                    } catch (e: Exception) { result.error("audio", "試聴できません: ${e.message}", null) }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(engine.dartExecutor.binaryMessenger, "jp.choiromr.mobile/pdf").setMethodCallHandler { call, result ->
            when (call.method) {
                "startNativeConversion" -> executor.execute {
                    try {
                        val id = requireNotNull(call.argument<String>("id"))
                        ConversionStore(File(filesDir, "conversions")).load(id)
                        runOnUiThread {
                            try {
                                val current = ConversionService.activeId()
                                if (current != id) {
                                    check(current == null && !RecognitionLease.busy()) { "別の認識が実行中です。" }
                                    check(ConversionService.reserve(id)) { "別の認識が開始されました。" }
                                    try {
                                        val intent = Intent(this, ConversionService::class.java).setAction(ConversionService.START).putExtra("id", id)
                                        if (android.os.Build.VERSION.SDK_INT >= 26) startForegroundService(intent) else startService(intent)
                                    } catch (e: Exception) { ConversionService.releaseReservation(id); throw e }
                                    if (android.os.Build.VERSION.SDK_INT >= 33 &&
                                        checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                                        val preferences = getSharedPreferences("notification-permission", MODE_PRIVATE)
                                        if (!preferences.getBoolean("asked", false)) {
                                            preferences.edit().putBoolean("asked", true).apply()
                                            try {
                                                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 21)
                                            } catch (e: Exception) {
                                                android.util.Log.w("ChoirConversion", "Cannot request optional notification permission", e)
                                            }
                                        }
                                    }
                                }
                                result.success(null)
                            } catch (e: Exception) { result.error("conversion", "変換を開始できません: ${e.message}", null) }
                        }
                    } catch (e: Exception) { runOnUiThread { result.error("conversion", e.message, null) } }
                }
                "nativeConversionState" -> executor.execute {
                    try {
                        val id = requireNotNull(call.argument<String>("id"))
                        val wasActive = ConversionService.activeId() == id
                        val text = ConversionStore(File(filesDir, "conversions")).load(id)
                        runOnUiThread { result.success(mapOf("active" to (wasActive || ConversionService.activeId() == id), "text" to text)) }
                    } catch (e: Exception) { runOnUiThread { result.error("conversion", e.message, null) } }
                }
                "saveConversion", "listConversions", "loadConversion", "deleteConversion" -> executor.execute {
                    try {
                        val store = ConversionStore(File(filesDir, "conversions"))
                        val value: Any = when (call.method) {
                            "listConversions" -> store.list()
                            "loadConversion" -> store.load(requireNotNull(call.argument<String>("id")))
                            "deleteConversion" -> {
                                val id = requireNotNull(call.argument<String>("id"))
                                check(ConversionService.activeId() != id) { "実行中の変換は削除できません。" }
                                store.delete(id)
                                true
                            }
                            else -> {
                                val id = call.argument<String>("id")
                                check(id == null || ConversionService.activeId() != id) { "実行中のジョブは認識処理が更新します。" }
                                store.save(id, requireNotNull(call.argument<String>("text")))
                            }
                        }
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) { runOnUiThread { result.error("conversion", "変換ジョブを保存・読み込みできません: ${e.message}", null) } }
                }
                "openSourcePdf" -> executor.execute {
                    var nextDescriptor: ParcelFileDescriptor? = null
                    var nextRenderer: PdfRenderer? = null
                    try {
                        val hash = requireNotNull(call.argument<String>("hash"))
                        nextDescriptor = ParcelFileDescriptor.open(PdfSourceStore(File(filesDir, "sources")).file(hash), ParcelFileDescriptor.MODE_READ_ONLY)
                        nextRenderer = PdfRenderer(nextDescriptor)
                        val count = nextRenderer.pageCount
                        require(count > 0)
                        call.argument<Int>("pages")?.let { require(it == count) { "保存されたページ数と一致しません。" } }
                        renderer?.close(); descriptor?.close()
                        renderer = nextRenderer; descriptor = nextDescriptor; pdfHash = hash
                        nextRenderer = null; nextDescriptor = null
                        runOnUiThread { result.success(mapOf("pages" to count, "sourceHash" to hash)) }
                    } catch (e: Exception) {
                        nextRenderer?.close(); nextDescriptor?.close()
                        runOnUiThread { result.error("source", "保存した PDF を開けません: ${e.message}", null) }
                    }
                }
                "renderSourcePage" -> executor.execute {
                    try {
                        val hash = requireNotNull(call.argument<String>("hash"))
                        val index = requireNotNull(call.argument<Int>("page"))
                        val source = PdfSourceStore(File(filesDir, "sources")).file(hash)
                        val bytes = ParcelFileDescriptor.open(source, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
                            PdfRenderer(descriptor).use { pdf ->
                                require(index in 0 until pdf.pageCount) { "原譜のページ番号が範囲外です。" }
                                pdf.openPage(index).use { page ->
                                    val scale = minOf(2.0, 1600.0 / max(page.width, page.height))
                                    val bitmap = Bitmap.createBitmap(max(1, (page.width * scale).roundToInt()), max(1, (page.height * scale).roundToInt()), Bitmap.Config.ARGB_8888)
                                    try {
                                        bitmap.eraseColor(Color.WHITE)
                                        page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                        val output = ByteArrayOutputStream()
                                        check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
                                        output.toByteArray()
                                    } finally { bitmap.recycle() }
                                }
                            }
                        }
                        runOnUiThread { result.success(bytes) }
                    } catch (e: Exception) { runOnUiThread { result.error("source", "原譜を表示できません: ${e.message}", null) } }
                    catch (e: OutOfMemoryError) { runOnUiThread { result.error("memory", "原譜画像のメモリを確保できませんでした。", null) } }
                }
                "pickPdfs" -> {
                    // Batch conversion: import several PDFs without replacing the open renderer.
                    if (pendingPdfs != null) { result.error("busy", "ファイル選択中です。", null); return@setMethodCallHandler }
                    pendingPdfs = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/pdf"
                            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        }, 23)
                    } catch (e: Exception) {
                        pendingPdfs = null
                        result.error("picker", "ファイル選択を開始できません: ${e.message}", null)
                    }
                }
                "pickPdf" -> {
                    if (pendingPicker != null) { result.error("busy", "ファイル選択中です。", null); return@setMethodCallHandler }
                    pendingPicker = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            addCategory(Intent.CATEGORY_OPENABLE)
                            type = "application/pdf"
                        }, 17)
                    } catch (e: Exception) {
                        pendingPicker = null
                        result.error("picker", "ファイル選択を開始できません: ${e.message}", null)
                    }
                }
                "renderPage" -> {
                    val page = call.argument<Int>("page") ?: -1
                    val dpi = call.argument<Int>("dpi") ?: 0
                    executor.execute {
                        try {
                            require(dpi == 300 || dpi == 400)
                            val pdf = requireNotNull(renderer) { "PDFを選択してください。" }
                            require(page in 0 until pdf.pageCount) { "ページ番号が範囲外です。" }
                            val data = pdf.openPage(page).use { p ->
                                val (width, height) = jp.choiromr.mobile.omr.PdfPageRasterizer.renderSize(p.width, p.height, dpi)
                                require(width > 0 && height > 0 && width.toLong() * height <= 40_000_000L) { "ページの縦横比が大きすぎます。" }
                                val start = android.os.SystemClock.elapsedRealtime()
                                val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                                try {
                                    bitmap.eraseColor(Color.WHITE)
                                    p.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                    val elapsed = android.os.SystemClock.elapsedRealtime() - start
                                    val pss = Debug.getPss() * 1024L
                                    val scale = minOf(1.0, 1200.0 / max(width, height))
                                    val small = Bitmap.createScaledBitmap(bitmap, max(1, (width * scale).roundToInt()), max(1, (height * scale).roundToInt()), true)
                                    try {
                                        val bytes = ByteArrayOutputStream()
                                        check(small.compress(Bitmap.CompressFormat.PNG, 100, bytes))
                                        mapOf("width" to width, "height" to height, "elapsedMs" to elapsed,
                                            "pssBytes" to pss, "bitmapBytes" to bitmap.allocationByteCount.toLong(), "preview" to bytes.toByteArray())
                                    } finally { if (small !== bitmap) small.recycle() }
                                } finally { bitmap.recycle() }
                            }
                            runOnUiThread { result.success(data) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("render", "描画できません: ${e.message}", null) }
                        } catch (e: OutOfMemoryError) {
                            runOnUiThread { result.error("memory", "メモリが足りず描画できませんでした。", null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    @Deprecated("Activity result API used for compatibility with FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 20) {
            val result = pendingModels ?: return
            pendingModels = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { result.success(false); return }
            executor.execute {
                try {
                    requireNotNull(contentResolver.openInputStream(uri)).use { input ->
                        ModelStore(File(filesDir, "omr-models")).install(input)
                    }
                    runOnUiThread { result.success(true) }
                } catch (e: Exception) {
                    runOnUiThread { result.error("models", "モデルを取り込めません: ${e.message}", null) }
                }
            }
            return
        }
        if (requestCode == 18) {
            val result = pendingScore ?: return
            pendingScore = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
            executor.execute {
                try {
                    val bytes = requireNotNull(contentResolver.openInputStream(uri)).use { input ->
                        val output = ByteArrayOutputStream()
                        val buffer = ByteArray(8192)
                        while (true) {
                            val count = input.read(buffer)
                            if (count < 0) break
                            output.write(buffer, 0, count)
                            require(output.size() <= 10_000_000) { "ファイルが大きすぎます。" }
                        }
                        output.toByteArray()
                    }
                    require(bytes.size <= 10_000_000) { "ファイルが大きすぎます。" }
                    val text = bytes.toString(Charsets.UTF_8)
                    runOnUiThread { result.success(text) }
                } catch (e: Exception) { runOnUiThread { result.error("open", "楽譜を開けません: ${e.message}", null) } }
            }
            return
        }
        if (requestCode == 19) {
            val result = pendingExport ?: return
            pendingExport = null
            val bytes = exportBytes; exportBytes = null
            val archive = exportFile; exportFile = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null || (bytes == null && archive == null)) {
                archive?.delete(); result.success(false); return
            }
            executor.execute {
                try {
                    requireNotNull(contentResolver.openOutputStream(uri, "wt")).use { output ->
                        if (archive != null) archive.inputStream().use { it.copyTo(output) }
                        else output.write(requireNotNull(bytes))
                    }
                    runOnUiThread { result.success(true) }
                } catch (e: Exception) { runOnUiThread { result.error("save", "保存できません: ${e.message}", null) } }
                finally { archive?.delete() }
            }
            return
        }
        if (requestCode == 22) {
            val result = pendingBackup ?: return
            pendingBackup = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
            executor.execute {
                try {
                    check(!RecognitionLease.busy() && ConversionService.activeId() == null) { "認識が終了してから復元してください。" }
                    val staged = requireNotNull(contentResolver.openInputStream(uri)).use { ProjectBackupStore(filesDir, cacheDir).stage(it) }
                    runOnUiThread { result.success(staged) }
                } catch (e: Exception) { runOnUiThread { result.error("backup", "バックアップを開けません: ${e.message}", null) } }
                catch (e: OutOfMemoryError) { runOnUiThread { result.error("memory", "メモリ不足でバックアップを開けませんでした。", null) } }
            }
            return
        }
        if (requestCode == 23) {
            val result = pendingPdfs ?: return
            pendingPdfs = null
            val uris = buildList {
                data?.clipData?.let { clip -> for (i in 0 until clip.itemCount) add(clip.getItemAt(i).uri) }
                if (isEmpty()) data?.data?.let { add(it) }
            }
            if (resultCode != Activity.RESULT_OK || uris.isEmpty()) { result.success(null); return }
            executor.execute {
                val picked = uris.map { uri ->
                    val filename = try {
                        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                            if (it.moveToFirst()) it.getString(0) else null
                        }
                    } catch (e: Exception) { null } ?: "PDF"
                    try {
                        val imported = requireNotNull(contentResolver.openInputStream(uri)).use {
                            PdfSourceStore(File(filesDir, "sources")).importPdf(it)
                        }
                        val count = ParcelFileDescriptor.open(imported.second, ParcelFileDescriptor.MODE_READ_ONLY).use { d ->
                            PdfRenderer(d).use { it.pageCount }
                        }
                        require(count > 0) { "ページがありません。" }
                        mapOf("name" to filename, "pages" to count, "sourceHash" to imported.first)
                    } catch (e: Exception) { mapOf("name" to filename, "error" to "PDFを開けません: ${e.message}") }
                }
                runOnUiThread { result.success(picked) }
            }
            return
        }
        if (requestCode != 17) return
        val result = pendingPicker ?: return
        pendingPicker = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        executor.execute {
            var newDescriptor: ParcelFileDescriptor? = null
            var newRenderer: PdfRenderer? = null
            try {
                val filename = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                } ?: "PDF"
                val imported = requireNotNull(contentResolver.openInputStream(uri)).use {
                    PdfSourceStore(File(filesDir, "sources")).importPdf(it)
                }
                val hash = imported.first
                newDescriptor = ParcelFileDescriptor.open(imported.second, ParcelFileDescriptor.MODE_READ_ONLY)
                newRenderer = PdfRenderer(newDescriptor)
                require(newRenderer.pageCount > 0) { "ページがありません。" }
                renderer?.close(); descriptor?.close()
                renderer = newRenderer; descriptor = newDescriptor
                pdfHash = hash
                val count = newRenderer.pageCount
                newRenderer = null; newDescriptor = null
                runOnUiThread { result.success(mapOf("name" to filename, "pages" to count, "sourceHash" to hash)) }
            } catch (e: Exception) {
                newRenderer?.close(); newDescriptor?.close()
                runOnUiThread { result.error("open", "PDFを開けません: ${e.message}", null) }
            }
        }
    }

    override fun onStart() { super.onStart(); audioGuard.start() }
    override fun onStop() { audioGuard.stop(); super.onStop() }

    override fun onDestroy() {
        exportFile?.delete(); exportFile = null
        audioGuard.stop()
        recognitionCancelled.set(true)
        audioGeneration.incrementAndGet()
        audioExecutor.shutdown()
        executor.execute { renderer?.close(); descriptor?.close() }
        executor.shutdown()
        super.onDestroy()
    }

    private fun loadPianoSamples(): List<PianoSample> {
        pianoSamples?.let { return it }
        val names = listOf("A0" to 21, "C1" to 24, "Fs1" to 30, "C2" to 36, "Fs2" to 42,
            "C3" to 48, "Fs3" to 54, "C4" to 60, "Fs4" to 66, "C5" to 72, "Fs5" to 78,
            "C6" to 84, "Fs6" to 90, "C7" to 96, "Fs7" to 102, "C8" to 108)
        return names.map { (name, pitch) ->
            val bytes = assets.open("piano/$name.pcm").use { it.readBytes() }
            require(bytes.isNotEmpty() && bytes.size % 2 == 0)
            val pcm = ShortArray(bytes.size / 2) { i ->
                ((bytes[2 * i].toInt() and 255) or (bytes[2 * i + 1].toInt() shl 8)).toShort()
            }
            PianoSample(pitch, pcm)
        }.also { pianoSamples = it }
    }

    private fun playPreview(events: List<AudioEvent>, generation: Int, samples: List<PianoSample>?, lengthMs: Int, loop: Boolean, offsetMs: Int, loopStartMs: Int) {
        if (audioGeneration.get() != generation) return
        val rate = 44100
        val notes = events.map { event ->
            val sample = samples?.minByOrNull { kotlin.math.abs(it.pitch - event.pitch) }
            // Tuning applies to both the oscillator and the piano sample speed.
            val tune = 2.0.pow(event.cents / 1200.0)
            RenderedNote(event.start.toLong() * rate / 1000, (event.start.toLong() + event.duration) * rate / 1000,
                440.0 * 2.0.pow((event.pitch - 69) / 12.0) * tune, sample?.data,
                if (sample == null) 0.0 else 0.5 * 2.0.pow((event.pitch - sample.pitch) / 12.0) * tune, event.gain, event.legato,
                event.part, event.piano, event.accent)
        }.sortedBy { it.first }
        val total = maxOf(lengthMs, events.maxOfOrNull { it.start + it.duration } ?: 0).toLong() * rate / 1000
        if (total == 0L) return
        val minBuffer = AudioTrack.getMinBufferSize(rate, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(minBuffer > 0) { "音声出力を初期化できません。" }
        val track = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(rate).setEncoding(AudioFormat.ENCODING_PCM_16BIT).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
            .setBufferSizeInBytes(max(minBuffer, 4096)).setTransferMode(AudioTrack.MODE_STREAM).build()
        try {
            track.play()
            val buffer = ShortArray(1024)
            val offsetFrames = offsetMs.toLong() * rate / 1000
            val cycleClock = AudioCycle(total, loop, offsetFrames, loopStartMs.toLong() * rate / 1000)
            var position = offsetFrames
            var nextNote = 0
            val active = mutableListOf<RenderedNote>()
            val previousGains = mutableMapOf<String, Double>()
            val limiter = AudioLimiter(rate)
            var lastHead = 0L
            var headWraps = 0L
            fun playedFrames(): Long {
                val head = track.playbackHeadPosition.toLong() and 0xffffffffL
                if (head < lastHead) headWraps += (1L shl 32)
                lastHead = head
                return headWraps + head
            }
            fun updatePosition() {
                val frames = playedFrames()
                if (audioGeneration.get() == generation) audioPositionMs.set(cycleClock.playbackPosition(frames) * 1000 / rate)
            }
            while ((loop || position < total) && audioGeneration.get() == generation) {
                val cycle = cycleClock.phase(position)
                if (cycle == 0L || (position >= total && cycle == loopStartMs.toLong() * rate / 1000)) { nextNote = 0; active.clear() }
                val count = cycleClock.chunkSize(position, buffer.size)
                active.removeAll { it.last <= cycle }
                while (nextNote < notes.size && notes[nextNote].first < cycle + count) {
                    val note = notes[nextNote++]
                    if (note.last > cycle) active.add(note)
                }
                val mixer = audioMixer.get()
                // RenderedNote contains sample arrays. Hashing it as a map key
                // would scan the entire PCM asset for every output sample.
                val gains = active.map { mixer.gain(it.part) }
                val fromGains = active.mapIndexed { index, note -> previousGains[note.part] ?: gains[index] }
                active.forEachIndexed { index, note -> previousGains[note.part] = gains[index] }
                val instruments = active.map { mixer.instruments[it.part] ?: if (it.piano) "piano" else "choir" }
                val organHarmonics = listOf(2 to 0.5, 3 to 0.25, 4 to 0.15)
                val choirHarmonics = listOf(2 to 0.22, 3 to 0.12, 4 to 0.06)
                for (i in 0 until count) {
                    val sample = cycle + i
                    var value = 0.0
                    for (noteIndex in active.indices) {
                        val note = active[noteIndex]
                        if (sample < note.first || sample >= note.last) continue
                        val age = sample - note.first
                        val liveGain = fromGains[noteIndex] + (gains[noteIndex] - fromGains[noteIndex]) * i / count
                        val envelope = minOf(1.0, age / 220.0, (note.last - sample) / if (note.legato) 441.0 else 2205.0) * note.gain * liveGain
                        if (envelope == 0.0) continue
                        val instrument = instruments[noteIndex]
                        val pcm = if (instrument == "piano") note.sample else null
                        if (note.part == "_metronome" || note.part == "_countin") {
                            value += sin(2 * Math.PI * (if (note.accent) 1500 else 1000) * age / rate) * envelope
                            continue
                        }
                        if (pcm == null) {
                            val phase = 2 * Math.PI * note.frequency * age / rate
                            var wave = sin(phase)
                            val harmonics = if (instrument == "organ") organHarmonics
                                else if (instrument == "choir") choirHarmonics else emptyList()
                            for ((harmonic, level) in harmonics) if (note.frequency * harmonic < rate / 2) wave += sin(phase * harmonic) * level
                            value += wave * envelope / (if (instrument == "organ") 1.9 else 1.4)
                        } else {
                            val at = age * note.sampleStep
                            val index = at.toInt()
                            if (index + 1 < pcm.size) {
                                val fraction = at - index
                                value += (pcm[index] * (1 - fraction) + pcm[index + 1] * fraction) / 32768.0 * envelope
                            }
                        }
                    }
                    val fadeIn = minOf(1.0, (position - offsetFrames + i) / 220.0)
                    // 7000 per unit as before; above 2.6 units the limiter turns the
                    // level down smoothly instead of clipping (heard as buzzing).
                    buffer[i] = (limiter.process(value * fadeIn / 2.6) * 18200).toInt().toShort()
                }
                check(track.write(buffer, 0, count) == count) { "音声データを出力できません。" }
                position += count
                updatePosition()
            }
            while (audioGeneration.get() == generation && playedFrames() < position) {
                updatePosition()
                Thread.sleep(20)
            }
            if (audioGeneration.get() == generation) audioPositionMs.set(position * 1000 / rate)
        } finally { track.pause(); track.flush(); track.release() }
    }
}
