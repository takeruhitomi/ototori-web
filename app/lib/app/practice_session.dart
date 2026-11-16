import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../just_intonation.dart';
import '../playback_timeline.dart';
import '../playback_transport.dart';
import '../project_persistence.dart';
import '../score.dart';

/// A sung part or the piano (both piano staves play as one part).
class PartInfo {
  const PartInfo(this.id, this.name, this.staff);
  final String id, name;
  /// First staff index of the part.
  final int staff;
  bool get isPiano => id == 'piano';
}

/// How the mixer presents one part to a singer.
enum FocusMode { emphasis, minusOne }

/// The score open for practice, shared by every tab.
///
/// Holds playback and mixer state and saves changes to the library entry
/// automatically. Notes are scheduled by the native audio thread; this class
/// only follows its playback head.
class PracticeSession extends ChangeNotifier {
  PracticeSession({PlaybackTransport? transport}) : transport = transport ?? PlaybackTransport() {
    this.transport.addListener(_transportChanged);
  }

  static const channel = MethodChannel('jp.choiromr.mobile/score');
  final PlaybackTransport transport;
  final _notices = StreamController<String>.broadcast();
  Stream<String> get notices => _notices.stream;
  void notice(String message) { if (!_notices.isClosed) _notices.add(message); }

  ScoreDocument? score;
  String? projectId;
  ProjectPersistence _persistence = ProjectPersistence();
  bool saving = false;
  /// Library entry changed (title, edits) — the library list should refresh.
  final libraryChanged = ValueNotifier<int>(0);

  // Mixer and practice settings, stored in meta.mobile_playback.
  final volumes = <String, double>{};
  final muted = <String>{};
  final solos = <String>{};
  final instruments = <String, String>{};
  double masterVolume = 0.8, metroVolume = 0.6;
  bool metronome = false, countIn = false, follow = true, loop = false;
  /// Trial: tune complete triads of the sung parts to pure ratios.
  bool justIntonation = false;
  int loopFrom = 0, loopTo = 0;
  double? _tempo;
  String? focusPart;
  FocusMode focusMode = FocusMode.emphasis;
  /// Position while no playback is prepared.
  double _cursor = 0;

  bool get hasScore => score != null;
  String get title => '${score?.data['title'] ?? '楽譜'}';
  Map get meta => score?.data['meta'] as Map? ?? const {};
  String? get sourceHash => meta['source_hash'] is String && (meta['source_hash'] as String).isNotEmpty ? meta['source_hash'] as String : null;
  int get sourcePages => meta['source_pages'] as int? ?? 0;
  Map? get layout => meta['layout'] as Map?;
  List<String> get warnings {
    final w = score?.data['warnings'];
    return w is List ? [for (final e in w) '$e'] : const [];
  }

  List<PartInfo> get parts {
    final s = score;
    if (s == null) return const [];
    return [for (var i = 0; i < s.staves.length; i++)
      if (s.staves[i]['role'] != 'piano_lh')
        s.staves[i]['role'] == 'piano_rh' ? PartInfo('piano', 'ピアノ', i)
          : PartInfo('${s.staves[i]['id']}', '${s.staves[i]['name'] ?? s.staves[i]['id']}', i)];
  }

  /// Bars of the reference staff (the longest one), in source order.
  List<Map> get measures {
    final s = score;
    if (s == null || s.staves.isEmpty) return const [];
    final staff = s.staves.reduce((a, b) => (a['measures'] as List).length >= (b['measures'] as List).length ? a : b);
    return (staff['measures'] as List).cast<Map>();
  }

  PlaybackTimeline? _plan;
  ScoreDocument? _planScore;
  int _planRevision = -1;
  String? _repeatKey;
  PlaybackTimeline? get plan {
    final s = score;
    if (s == null) return null;
    final key = '${meta['repeats_enabled']}/${meta['repeat_override']}';
    if (!identical(_planScore, s) || _planRevision != s.revision || _repeatKey != key) {
      _plan = PlaybackTimelineBuilder().build(s.data);
      _planScore = s; _planRevision = s.revision; _repeatKey = key;
      _tuning = JustIntonationPlan.build(_plan!.notes); _tunedFor = null;
    }
    if (_plan != null && _tunedFor != justIntonation) {
      _tuning?.applyTo(_plan!.notes, on: justIntonation); _tunedFor = justIntonation;
    }
    return _plan;
  }

  JustIntonationPlan? _tuning;
  bool? _tunedFor;

  /// Chord name (C, Am…) at [beat]; null where no complete triad sounds.
  String? chordLabelAt(double beat) { plan; return _tuning?.chordAt(beat)?.label; }

  void setJustIntonation(bool value) {
    justIntonation = value;
    plan;
    _settingsChanged();
    _guard(() => transport.reload());
    if (value) notice('純正律（試作）：三和音がそろった所だけ、合唱パートの音程を少し動かします。ピアノは平均律のままです。');
  }

  /// Starting tempo. Tempo marks are not recognized, so this is a default
  /// (or a value from an imported score.json) until the singer changes it.
  double get defaultTempo => (score?.data['tempo_bpm'] as num?)?.toDouble() ?? 80;
  double get tempo => _tempo ?? defaultTempo;
  bool get playing => transport.playing;
  bool get prepared => transport.timeline != null;
  double get position => prepared ? transport.position : _cursor;
  double get totalBeats => plan?.totalBeats ?? 0;
  double get rangeFrom => prepared ? transport.rangeFrom : 0;
  double get rangeTo => prepared ? transport.rangeTo : totalBeats;

  /// Index into the performed order for the current position.
  int get performedIndex {
    final p = plan;
    if (p == null || p.measureStarts.isEmpty) return -1;
    return p.measureStarts.lastIndexWhere((b) => b <= position + 1e-6).clamp(0, p.order.length - 1);
  }

  /// Source bar index (0-based) under the playhead.
  int get currentMeasure {
    final i = performedIndex;
    return i < 0 ? 0 : plan!.order[i];
  }

  /// Progress through the current bar, 0..1.
  double get barFraction {
    final i = performedIndex;
    if (i < 0) return 0;
    final p = plan!;
    return ((position - p.measureStarts[i]) / p.measureLengths[i]).clamp(0.0, 1.0);
  }

  int get measureCount => measures.length;
  String measureLabel(int source) {
    final m = source >= 0 && source < measures.length ? measures[source] : null;
    return '${m?['number'] ?? source + 1}';
  }

  void _transportChanged() => notifyListeners();

  // ---------------------------------------------------------------- opening

  Future<void> open(ScoreDocument document, {String? projectId}) async {
    await transport.reset();
    score = document;
    this.projectId = projectId;
    _persistence = ProjectPersistence(id: projectId);
    _restoreSettings();
    _cursor = 0;
    notifyListeners();
  }

  Future<void> openProject(String id) async {
    final text = await channel.invokeMethod<String>('loadProject', {'id': id});
    if (text == null) throw const FormatException('楽譜を読み込めませんでした。');
    await open(ScoreDocument.fromProject(text), projectId: id);
  }

  Future<void> close() async {
    await transport.reset();
    score = null; projectId = null; _persistence = ProjectPersistence();
    notifyListeners();
  }

  // ----------------------------------------------------------------- saving

  Timer? _saveTimer;
  void _scheduleSave() {
    if (projectId == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 700), () => save(quiet: true));
  }

  /// Saves to the library entry (creates one for a new score).
  Future<bool> save({bool quiet = false}) async {
    final s = score;
    if (s == null) return false;
    _saveTimer?.cancel();
    final session = _persistence;
    saving = true; notifyListeners();
    try {
      final id = await session.save(s.encodeProject());
      if (identical(_persistence, session)) projectId = id;
      libraryChanged.value++;
      if (!quiet) notice('ライブラリに保存しました。');
      return true;
    } on PlatformException catch (e) { notice(e.message ?? '保存できませんでした。'); return false; }
    on FormatException catch (e) { notice(e.message); return false; }
    finally { saving = false; notifyListeners(); }
  }

  Future<void> rename(String title) async {
    final s = score;
    if (s == null || title.trim().isEmpty) return;
    s.data['title'] = title.trim();
    notifyListeners();
    await save(quiet: true);
  }

  // --------------------------------------------------------------- settings

  void _restoreSettings() {
    volumes.clear(); muted.clear(); solos.clear(); instruments.clear(); _tempo = null;
    masterVolume = 0.8; metroVolume = 0.6; metronome = false; countIn = false; follow = true;
    loop = false; loopFrom = 0; loopTo = 0; focusPart = null; focusMode = FocusMode.emphasis;
    justIntonation = false;
    final saved = meta['mobile_playback'];
    if (saved is! Map) return;
    double bounded(dynamic v, double fallback, double min, double max) =>
      v is num && v.isFinite ? v.toDouble().clamp(min, max) : fallback;
    if (saved['tempo'] is num) _tempo = bounded(saved['tempo'], tempo, 20, 400);
    if (saved['volumes'] is Map) {
      for (final e in (saved['volumes'] as Map).entries) { volumes['${e.key}'] = bounded(e.value, 1, 0, 1); }
    }
    if (saved['muted'] is List) muted.addAll((saved['muted'] as List).whereType<String>());
    // Earlier versions allowed several solos; keep the first.
    if (saved['solo'] is List) solos.addAll((saved['solo'] as List).whereType<String>().take(1));
    if (saved['instruments'] is Map) {
      for (final e in (saved['instruments'] as Map).entries) {
        if (['choir', 'piano', 'organ', 'sine'].contains(e.value)) instruments['${e.key}'] = e.value as String;
      }
    }
    masterVolume = bounded(saved['master'], 0.8, 0, 1); metroVolume = bounded(saved['metroVolume'], 0.6, 0, 1);
    metronome = saved['metronome'] == true; countIn = saved['countIn'] == true; follow = saved['follow'] != false;
    loop = saved['loop'] == true;
    loopFrom = saved['loopFrom'] is int ? (saved['loopFrom'] as int).clamp(0, 9999) : 0;
    loopTo = saved['loopTo'] is int ? (saved['loopTo'] as int).clamp(0, 9999) : 0;
    focusPart = saved['focus'] is String ? saved['focus'] as String : null;
    focusMode = saved['focusMode'] == 'minus' ? FocusMode.minusOne : FocusMode.emphasis;
    justIntonation = saved['justIntonation'] == true;
  }

  void _settingsChanged({bool tempoChanged = false, bool clicksChanged = false}) {
    final s = score;
    if (s == null) return;
    final m = s.data.putIfAbsent('meta', () => <String, dynamic>{}) as Map;
    m['mobile_playback'] = {'tempo': tempo, 'volumes': volumes, 'muted': muted.toList(), 'solo': solos.toList(),
      'instruments': instruments, 'master': masterVolume, 'metronome': metronome, 'metroVolume': metroVolume,
      'countIn': countIn, 'follow': follow, 'loop': loop, 'loopFrom': loopFrom, 'loopTo': loopTo,
      'focus': focusPart, 'focusMode': focusMode == FocusMode.minusOne ? 'minus' : 'emphasis',
      'justIntonation': justIntonation};
    _guard(() => transport.update(tempo: tempoChanged ? tempo : null, volumes: volumes, muted: muted,
      solo: solos, master: masterVolume, instruments: instruments, metroVolume: metroVolume,
      clicks: clicksChanged && prepared ? _clicks(transport.timeline!) : null));
    notifyListeners();
    _scheduleSave();
  }

  double volumeOf(String id) => volumes[id] ?? 1;
  String instrumentOf(PartInfo part) => instruments[part.id] ?? (part.isPiano ? 'piano' : 'choir');

  void setVolume(String id, double value) { volumes[id] = value.clamp(0, 1); focusPart = null; _settingsChanged(); }
  void toggleMute(String id) { muted.contains(id) ? muted.remove(id) : muted.add(id); focusPart = null; _settingsChanged(); }
  /// Solo is one part at a time: soloing another part replaces it.
  void toggleSolo(String id) {
    final was = solos.contains(id);
    solos.clear();
    if (!was) solos.add(id);
    focusPart = null; _settingsChanged();
  }
  void setInstrument(String id, String instrument) { instruments[id] = instrument; _settingsChanged(); }
  void setMaster(double v) { masterVolume = v.clamp(0, 1); _settingsChanged(); }
  void setMetronome(bool on) { metronome = on; _settingsChanged(clicksChanged: true); }
  void setMetroVolume(double v) { metroVolume = v.clamp(0, 1); _settingsChanged(); }
  void setCountIn(bool on) { countIn = on; _settingsChanged(); }
  void setFollow(bool on) { follow = on; _settingsChanged(); }
  void setTempo(double bpm) { _tempo = bpm.clamp(20, 400).roundToDouble(); _settingsChanged(tempoChanged: true); }

  /// Choir shortcut: hear one part louder, or everyone except that part.
  void setFocus(String? id, [FocusMode? mode]) {
    focusPart = id;
    if (mode != null) focusMode = mode;
    volumes.clear(); muted.clear(); solos.clear();
    if (id != null) {
      if (focusMode == FocusMode.emphasis) {
        for (final p in parts) { volumes[p.id] = p.id == id ? 1 : (p.isPiano ? 0.45 : 0.3); }
      } else {
        muted.add(id);
      }
    }
    _settingsChanged();
  }

  void resetMixer() {
    volumes.clear(); muted.clear(); solos.clear(); instruments.clear(); masterVolume = 0.8; focusPart = null;
    _settingsChanged();
  }

  /// Loop over performed bars [from, to] (indices into the performed order).
  void setLoop(bool enabled, {int? from, int? to}) {
    final p = plan;
    if (p == null || p.order.isEmpty) return;
    loopFrom = (from ?? loopFrom).clamp(0, p.order.length - 1);
    loopTo = (to ?? loopTo).clamp(loopFrom, p.order.length - 1);
    loop = enabled;
    _settingsChanged();
    if (prepared) {
      final start = loop ? p.measureStarts[loopFrom] : 0.0;
      final end = loop ? p.measureStarts[loopTo] + p.measureLengths[loopTo] : p.totalBeats;
      _guard(() => transport.update(loop: loop, fromBeat: start, toBeat: end));
    }
  }

  List<double> _clicks(PlaybackTimeline timeline) {
    if (!metronome) return [];
    final reference = measures;
    return [for (var i = 0; i < timeline.order.length; i++)
      for (var beat = 0.0; beat < timeline.measureLengths[i] - 0.00001;
        beat += 4 / (((timeline.order[i] < reference.length ? reference[timeline.order[i]]['time_sig'] : null) as List? ?? [4, 4])[1] as num))
        timeline.measureStarts[i] + beat];
  }

  // --------------------------------------------------------------- playback

  Future<void> _guard(Future<void> Function() action) async {
    try { await action(); }
    on PlatformException catch (e) { notice(e.message ?? '再生できませんでした。'); }
    on FormatException catch (e) { notice(e.message); }
    on StateError catch (e) { notice(e.message); }
  }

  double get _loopStart => plan!.measureStarts[loopFrom.clamp(0, plan!.order.length - 1)];
  double get _loopEnd {
    final p = plan!;
    final to = loopTo.clamp(loopFrom.clamp(0, p.order.length - 1), p.order.length - 1);
    return p.measureStarts[to] + p.measureLengths[to];
  }

  /// Loads the whole performance (or the loop) into the audio engine.
  Future<int> _prepare({required bool start}) async {
    final p = plan!;
    if (p.measureStarts.isEmpty) throw const FormatException('再生できる小節がありません。');
    final from = loop ? _loopStart : 0.0, to = loop ? _loopEnd : p.totalBeats;
    final cursor = _cursor.clamp(from, to);
    final atStart = (cursor - from).abs() < 1e-6;
    final index = p.measureStarts.lastIndexWhere((b) => b <= cursor + 1e-6).clamp(0, p.order.length - 1);
    final reference = measures;
    final timeSig = (p.order[index] < reference.length ? reference[p.order[index]]['time_sig'] : null) as List? ?? [4, 4];
    final count = await transport.play(p, tempo: tempo, fromBeat: from, toBeat: to,
      volumes: volumes, muted: muted, solo: solos, loop: loop,
      master: masterVolume, instruments: instruments, clicks: _clicks(p), metroVolume: metroVolume,
      countInBeats: start && atStart && countIn ? p.measureLengths[index] : 0,
      countInUnit: 4 / (timeSig[1] as num),
      start: start && atStart);
    if (!atStart) {
      await transport.seek(cursor);
      if (start) await transport.resume();
    }
    if (p.warnings.isNotEmpty && start) notice(p.warnings.join('\n'));
    return count;
  }

  Future<void> togglePlay() => _guard(() async {
    if (score == null) return;
    if (!prepared) {
      final count = await _prepare(start: true);
      if (count == 0) notice('再生する音がありません。ミュートと音量を確認してください。');
    } else if (transport.playing) {
      await transport.pause();
    } else {
      await transport.resume();
    }
  });

  Future<void> stop() => _guard(() async {
    if (!prepared) { _cursor = loop && plan != null ? _loopStart : 0; notifyListeners(); return; }
    await transport.stop();
  });

  /// Moves the playhead to [beat]; outside the loop, the loop is turned off.
  Future<void> seekBeat(double beat) => _guard(() async {
    final p = plan;
    if (p == null) return;
    beat = beat.clamp(0, p.totalBeats);
    if (loop && (beat < _loopStart - 1e-6 || beat >= _loopEnd)) {
      loop = false;
      _settingsChanged();
      if (prepared) await transport.update(loop: false, fromBeat: 0, toBeat: p.totalBeats);
      notice('ループ範囲の外へ移動したため、ループを解除しました。');
    }
    if (!prepared) { _cursor = beat; notifyListeners(); return; }
    await transport.seek(beat.clamp(transport.rangeFrom, transport.rangeTo));
  });

  /// Jumps to source bar [source], preferring the next performance of it.
  Future<void> seekToMeasure(int source) async {
    final p = plan;
    if (p == null || p.order.isEmpty) return;
    var index = p.order.indexWhere((m) => m == source, performedIndex.clamp(0, p.order.length - 1));
    if (index < 0) index = p.order.indexOf(source);
    if (index < 0) { notice('この小節は演奏順に含まれていません。'); return; }
    await seekBeat(p.measureStarts[index]);
  }

  Future<void> stepMeasure(int delta) async {
    final p = plan;
    if (p == null || p.order.isEmpty) return;
    final current = performedIndex;
    // Going back from inside a bar returns to its start first.
    final inside = position - p.measureStarts[current] > 0.25;
    final target = delta < 0 && inside ? current : (current + delta).clamp(0, p.order.length - 1);
    await seekBeat(p.measureStarts[target]);
  }

  // ---------------------------------------------------------------- editing

  void _edited() {
    // Bar lengths never change, so the playback position stays valid.
    final keep = position;
    _guard(transport.reset);
    _cursor = keep;
    notifyListeners();
    if (projectId != null) save(quiet: true);
  }

  void transpose(int staff, int measure, int event, int pitch, int delta) {
    try { score!.transpose(staff, measure, event, pitch, delta); _edited(); }
    on FormatException catch (e) { notice(e.message); }
  }

  /// Runs one change to the score; problems are shown as a notice.
  bool edit(void Function(ScoreDocument score) change) {
    final s = score;
    if (s == null) return false;
    try { change(s); _edited(); return true; } on FormatException catch (e) { notice(e.message); return false; }
  }

  void undo() { try { score!.undo(); _edited(); } on FormatException catch (e) { notice(e.message); } }
  void redo() { try { score!.redo(); _edited(); } on FormatException catch (e) { notice(e.message); } }

  void applyRepeats(bool enabled, List<Map<String, dynamic>>? regions) {
    final m = score!.data.putIfAbsent('meta', () => <String, dynamic>{}) as Map;
    m['repeats_enabled'] = enabled; m['repeat_override'] = regions;
    loopFrom = 0; loopTo = 0; loop = false;
    _edited();
  }

  Future<void> attachSource() async {
    try {
      final pdf = await const MethodChannel('jp.choiromr.mobile/pdf').invokeMapMethod<Object?, Object?>('pickPdf');
      if (pdf == null || score == null) return;
      final m = score!.data.putIfAbsent('meta', () => <String, dynamic>{}) as Map;
      m['source_hash'] = pdf['sourceHash']; m['source_pages'] = pdf['pages'];
      notifyListeners();
      await save(quiet: true);
    } on PlatformException catch (e) { notice(e.message ?? 'PDFを開けませんでした。'); }
  }

  /// Plays one pitch for checking an edit.
  Future<void> audition(int pitch, {bool piano = false}) => _guard(() async {
    await transport.stop();
    await channel.invokeMethod<void>('play', {'events': [
      {'pitch': pitch, 'start': 0, 'duration': 1000, 'piano': piano, 'gain': 0.7, 'legato': false},
    ]});
  });

  @override
  void dispose() {
    _saveTimer?.cancel();
    transport.removeListener(_transportChanged);
    transport.dispose();
    _notices.close();
    libraryChanged.dispose();
    super.dispose();
  }
}
