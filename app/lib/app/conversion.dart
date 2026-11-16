import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../browser_assembly.dart';
import '../conversion_job.dart';
import '../native_conversion_runner.dart';
import '../omr_bridge.dart';
import '../score.dart';
import '../score_structure.dart' show EnsembleLayout;
import 'library.dart';

enum ItemStatus { waiting, running, done, failed, cancelled }

/// One PDF in the conversion queue.
class ConversionItem {
  ConversionItem({required this.name, required this.hash, required this.pages, this.job});
  final String name, hash;
  final int pages;
  /// Set when resuming a saved job; its settings win over the form.
  ConversionJob? job;
  ItemStatus status = ItemStatus.waiting;
  int completedPages = 0;
  String? detail;
  String? projectId;
  String get title => name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '');
}

/// Ensemble presets offered when automatic detection is off.
class EnsemblePreset {
  const EnsemblePreset(this.label, this.voices, {this.piano = true});
  final String label;
  final List<String> voices;
  final bool piano;
  static const all = [
    EnsemblePreset('混声四部', ['Soprano', 'Alto', 'Tenor', 'Bass']),
    EnsemblePreset('混声三部', ['Soprano', 'Alto', 'Baritone']),
    EnsemblePreset('女声三部', ['Soprano I', 'Soprano II', 'Alto']),
    EnsemblePreset('女声二部', ['Soprano', 'Alto']),
    EnsemblePreset('男声四部', ['Tenor I', 'Tenor II', 'Baritone', 'Bass']),
  ];
}

/// Recognizes queued PDFs one at a time and adds each result to the library.
///
/// Page inference runs in the Android foreground service; this class
/// observes it, then assembles the score like the browser version.
class ConversionController extends ChangeNotifier {
  ConversionController({required this.library, this.omr = const OmrBridge()});
  static const pdfChannel = MethodChannel('jp.choiromr.mobile/pdf');
  final Library library;
  final OmrBridge omr;

  final items = <ConversionItem>[];
  bool autoEnsemble = true;
  String voiceText = 'Soprano, Alto, Tenor, Bass';
  bool piano = true;
  int dpi = 300;
  /// Single-PDF only: recognize one page instead of all.
  int? singlePage;

  bool running = false, cancelRequested = false;
  bool? modelsReady;
  ConversionItem? current;
  String? stage;
  List<Map> unfinished = const [];

  /// Called when an item finishes; the shell opens single results for practice.
  void Function(ConversionItem item, ScoreDocument score, {required bool last})? onFinished;
  void Function(String message)? onNotice;
  void _notice(String m) => onNotice?.call(m);
  bool _disposed = false;

  bool get idle => !running;
  bool get batch => items.length > 1;
  int get pendingCount => items.where((i) => i.status == ItemStatus.waiting).length;
  List<String> get voiceNames => voiceText.split(RegExp(r'[,、\n]')).map((v) => v.trim()).where((v) => v.isNotEmpty).toList();

  void _changed() { if (!_disposed) notifyListeners(); }

  Future<void> checkModels() async {
    try { modelsReady = await omr.modelsReady(); } on PlatformException { modelsReady = false; }
    on MissingPluginException { modelsReady = false; }
    _changed();
  }

  Future<void> loadUnfinished() async {
    try {
      final entries = await pdfChannel.invokeListMethod<Object?>('listConversions') ?? const [];
      unfinished = [for (final e in entries) if (e is Map && e['status'] != 'complete') e];
    } on PlatformException { unfinished = const []; }
    on MissingPluginException { unfinished = const []; }
    _changed();
  }

  /// Opens the document picker (multiple selection) and queues the PDFs.
  Future<void> pickPdfs() async {
    if (running) return;
    try {
      final picked = await pdfChannel.invokeListMethod<Object?>('pickPdfs');
      if (picked == null) return;
      // Finished rows from the previous run make room for the new selection.
      items.removeWhere((i) => i.status != ItemStatus.waiting);
      for (final p in picked) {
        if (p is! Map) continue;
        if (p['error'] is String) { _notice('${p['name']}: ${p['error']}'); continue; }
        final hash = p['sourceHash'] as String;
        if (items.any((i) => i.hash == hash)) continue;
        items.add(ConversionItem(name: '${p['name']}', hash: hash, pages: p['pages'] as int));
      }
      singlePage = null;
      _changed();
    } on PlatformException catch (e) { _notice(e.message ?? 'PDFを開けませんでした。'); }
  }

  void remove(ConversionItem item) { if (!running) { items.remove(item); _changed(); } }
  void clearFinished() { items.removeWhere((i) => i.status != ItemStatus.waiting); _changed(); }

  void setAuto(bool v) { autoEnsemble = v; _changed(); }
  void setPreset(EnsemblePreset p) { voiceText = p.voices.join(', '); piano = p.piano; _changed(); }
  void setVoices(String text) { voiceText = text; _changed(); }
  void setPiano(bool v) { piano = v; _changed(); }
  void setDpi(int v) { dpi = v; _changed(); }
  void setSinglePage(int? page) { singlePage = page; _changed(); }

  /// Deletes an interrupted job from the list. Pages already read stay in
  /// the recognition cache, so converting the same PDF again reuses them.
  Future<void> deleteUnfinished(String id) async {
    if (running) return;
    try {
      await pdfChannel.invokeMethod<bool>('deleteConversion', {'id': id});
      items.removeWhere((i) => i.job?.id == id && i.status == ItemStatus.waiting);
    } on PlatformException catch (e) { _notice(e.message ?? '削除できませんでした。'); }
    await loadUnfinished();
  }

  /// Restores a saved job (PDF, parts, pages) and queues it for resuming.
  Future<void> resume(String id) async {
    if (running) return;
    try {
      final text = await pdfChannel.invokeMethod<String>('loadConversion', {'id': id});
      if (text == null) throw const FormatException('変換ジョブがありません。');
      final job = ConversionJob.restore(id, text);
      final s = job.settings;
      autoEnsemble = s['auto_ensemble'] as bool? ?? true;
      if (!autoEnsemble) { voiceText = (s['voice_names'] as List).join(', '); piano = s['piano'] as bool; }
      dpi = s['dpi'] as int;
      singlePage = s['all_pages'] == true ? null : s['selected_page'] as int;
      items.removeWhere((i) => i.status != ItemStatus.waiting || i.hash == s['source_hash']);
      items.add(ConversionItem(name: s['name'] as String, hash: s['source_hash'] as String, pages: s['pages'] as int, job: job)
        ..completedPages = job.completedPages.length);
      _changed();
      await start();
    } on PlatformException catch (e) { _notice(e.message ?? '変換ジョブを開けませんでした。'); }
    on FormatException catch (e) { _notice(e.message); }
  }

  String? validate() {
    if (items.where((i) => i.status == ItemStatus.waiting).isEmpty) return 'PDFを選んでください。';
    if (!autoEnsemble && (voiceNames.isEmpty || voiceNames.length > 12)) return 'パート名を1〜12個入力してください。';
    return null;
  }

  Future<void> start() async {
    if (running) return;
    final problem = validate();
    if (problem != null) { _notice(problem); return; }
    if (!await omr.modelsReady()) { modelsReady = false; _changed(); _notice('認識モデルを準備できませんでした。アプリを入れ直してください。'); return; }
    running = true; cancelRequested = false; _changed();
    try {
      final queue = items.where((i) => i.status == ItemStatus.waiting).toList();
      for (var k = 0; k < queue.length; k++) {
        if (cancelRequested || _disposed) break;
        await _convert(queue[k], last: k == queue.length - 1);
      }
      if (cancelRequested) {
        for (final i in items.where((i) => i.status == ItemStatus.waiting)) { i.status = ItemStatus.cancelled; }
      }
    } finally {
      running = false; current = null; stage = null; _changed();
      await loadUnfinished();
    }
  }

  Future<void> cancel() async {
    cancelRequested = true; stage = '中止しています…'; _changed();
    try { await omr.cancel(jobId: current?.job?.id); } on PlatformException catch (e) { _notice(e.message ?? '中止できませんでした。'); }
  }

  Future<void> _convert(ConversionItem item, {required bool last}) async {
    current = item; item.status = ItemStatus.running; item.detail = null; stage = 'PDFを準備しています'; _changed();
    final names = autoEnsemble ? ['Auto'] : voiceNames;
    final allPages = batch || singlePage == null;
    final pageList = allPages ? List.generate(item.pages, (i) => i) : [singlePage!.clamp(0, item.pages - 1)];
    ConversionJob? job;
    try {
      final pdf = await pdfChannel.invokeMapMethod<Object?, Object?>('openSourcePdf', {'hash': item.hash, 'pages': item.pages});
      if (pdf?['pages'] != item.pages) throw const FormatException('保存した PDF とページ数が一致しません。');
      final requested = ConversionJob({'source_hash': item.hash, 'name': item.name, 'dpi': dpi,
        'pages': item.pages, 'selected_page': allPages ? 0 : pageList.single, 'all_pages': allPages,
        'piano': autoEnsemble ? false : piano, 'voice_names': names, 'auto_ensemble': autoEnsemble});
      job = item.job?.signature == requested.signature ? item.job! : requested;
      item.job = job;
      if (job.id == null) await job.save('pending');
      stage = 'ページを認識しています'; _changed();
      final attached = await const NativeConversionRunner().run(job, attached: () => !_disposed && !cancelRequested,
        onProgress: (j) { item.completedPages = j.completedPages.length; _changed(); });
      if (cancelRequested) { item.status = ItemStatus.cancelled; await job.save('cancelled'); return; }
      if (!attached) return;
      // Pages saved by the service are reused; this pass only reads them back.
      final recognized = <RecognizedPageSymbols>[];
      for (final index in pageList) {
        if (cancelRequested) { item.status = ItemStatus.cancelled; await job.save('cancelled'); return; }
        stage = '楽譜を組み立てています（${index + 1} / ${item.pages}ページ）'; _changed();
        recognized.add(await omr.recognizePage(page: index, dpi: dpi));
      }
      final result = assembleLikeBrowser(recognized,
        layout: autoEnsemble ? EnsembleLayout() : EnsembleLayout(voiceNames: names, piano: piano));
      final assembled = result.json;
      if (autoEnsemble) {
        assembled['meta']['ensemble_detection'] = {'automatic': true, 'evidence': 'layout-and-clefs',
          'voice_names': (assembled['meta']['voice_names'] as List?) ?? const [], 'piano': assembled['meta']['piano'] == true};
      }
      assembled['title'] = allPages ? item.title : '${item.title}（${pageList.single + 1}ページ）';
      assembled['meta']['source_hash'] = item.hash;
      assembled['meta']['source_pages'] = item.pages;
      final document = ScoreDocument.parse(jsonEncode(assembled));
      stage = 'ライブラリに保存しています'; _changed();
      item.projectId = await library.add(document);
      await job.save('complete');
      item.status = ItemStatus.done;
      item.completedPages = pageList.length;
      _changed();
      onFinished?.call(item, document, last: last);
    } on PlatformException catch (e) {
      await _fail(item, job, e.code == 'cancelled' ? null : e.message ?? '認識できませんでした。');
    } on FormatException catch (e) {
      await _fail(item, job, e.message);
    }
  }

  Future<void> _fail(ConversionItem item, ConversionJob? job, String? error) async {
    item.status = cancelRequested || error == null ? ItemStatus.cancelled : ItemStatus.failed;
    item.detail = error;
    _changed();
    if (job?.id == null) return;
    try { await job!.save(item.status == ItemStatus.cancelled ? 'cancelled' : 'failed', error: error); }
    catch (e) { item.detail = '${error ?? ''}\n進捗の保存にも失敗しました: $e'; _changed(); }
  }

  @override
  void dispose() { _disposed = true; super.dispose(); }
}
