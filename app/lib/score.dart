import 'dart:convert';
import 'omr_symbols.dart';
import 'project_identity.dart';

/// Edits the existing score.json representation without changing its timing,
/// metadata, or fields unknown to this version of the app.
///
/// Every edit keeps the bar's length: pitches change, rests become notes and
/// back, and an event can be split or merged with the next one in its voice.
/// History refers to parts, bars and notes by their saved IDs, so it stays
/// valid while events move inside a bar.
class ScoreDocument {
  ScoreDocument._(this.data, this.identity);
  final Map<String, dynamic> data;
  final ProjectIdentity identity;
  int get revision => identity.revision;
  final List<List<_Edit>> _undo = [];
  final List<List<_Edit>> _redo = [];

  factory ScoreDocument.parse(String text) => ScoreDocument.fromProject(text);

  static void _checkEvent(Object? event) {
    if (event is! Map || event['pitches'] is! List || (event['pitches'] as List).any((p) => p is! int || p < 0 || p > 127)) {
      throw const FormatException('音符の形式が不正です。');
    }
    final onset = beat(event['onset']);
    final duration = beat(event['duration']);
    if (!onset.isFinite || !duration.isFinite || onset < 0 || duration < 0) throw const FormatException('音符の拍位置または長さが不正です。');
  }

  static Map<String, dynamic> _readScore(String text) {
    final value = jsonDecode(text.startsWith('﻿') ? text.substring(1) : text);
    if (value is! Map<String, dynamic> || value['staves'] is! List || (value['staves'] as List).isEmpty) {
      throw const FormatException('声部を含む score.json を選択してください。');
    }
    for (final staff in value['staves'] as List) {
      if (staff is! Map || staff['measures'] is! List) throw const FormatException('声部の形式が不正です。');
      for (final measure in staff['measures'] as List) {
        if (measure is! Map || measure['events'] is! List) throw const FormatException('小節の形式が不正です。');
        (measure['events'] as List).forEach(_checkEvent);
      }
    }
    return value;
  }

  static double beat(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) {
      final parts = v.split('/');
      if (parts.length == 1) return double.parse(parts[0]);
      if (parts.length == 2) return double.parse(parts[0]) / double.parse(parts[1]);
    }
    throw const FormatException('拍位置の形式が不正です。');
  }

  List<dynamic> get staves => data['staves'] as List;
  List<dynamic> measures(int staff) => staves[staff]['measures'] as List;
  List<dynamic> events(int staff, int measure) => measures(staff)[measure]['events'] as List;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String encode() => const JsonEncoder.withIndent('  ').convert(data);

  String encodeProject() {
    // Version 3 (pitch changes only) stays readable by earlier app versions.
    final structural = [..._undo, ..._redo].any((batch) => batch.any((e) => e is _BarReplace));
    List<dynamic> json(List<List<_Edit>> history) => [for (final batch in history) [for (final e in batch) e.toJson()]];
    return jsonEncode({...data,
      '_choir_mobile_document': identity.toJson(),
      '_choir_mobile_history': {'version': structural ? 4 : 3, 'undo': json(_undo), 'redo': json(_redo)},
    });
  }

  factory ScoreDocument.fromProject(String text) {
    final data = _readScore(text);
    final metadata = data.remove('_choir_mobile_document');
    final history = data.remove('_choir_mobile_history');
    final score = ScoreDocument._(data, ProjectIdentity(data, metadata));
    if (history == null) return score;
    try {
      final version = history is Map ? history['version'] : null;
      if (version is! int || version < 1 || version > 4) throw const FormatException('編集履歴の形式が不正です。');
      if (version >= 3 && metadata == null) throw const FormatException('編集履歴のID情報がありません。');
      int midi(Object? v) {
        if (v is! int || v < 0 || v > 127) throw const FormatException('編集履歴の音高が不正です。');
        return v;
      }
      _Edit identified(dynamic entry) {
        final value = entry as Map;
        if (value['kind'] == 'bar') return _BarReplace.fromJson(value);
        if (value['kind'] != null) throw const FormatException('編集履歴の形式が不正です。');
        return _PitchChange(value['part_id'] as String, value['measure_id'] as String, value['note_id'] as String,
          value['pitch_id'] as String, midi(value['before']), midi(value['after']));
      }
      // Versions 1 and 2 stored positions; they only held pitch changes, so
      // positions in the current score resolve to the same notes.
      _Edit single(dynamic entry) {
        final values = (entry as List).cast<int>();
        if (values.length != 6 || values.take(4).any((i) => i < 0)) throw const FormatException('編集履歴の位置または音高が不正です。');
        final id = score.identity;
        return _PitchChange(id.partId(values[0]), id.measureId(values[0], values[1]), id.noteId(values[0], values[1], values[2]),
          id.pitchId(values[0], values[1], values[2], values[3]), midi(values[4]), midi(values[5]));
      }
      List<List<_Edit>> read(dynamic entries) => (entries as List).map((entry) {
        if (version >= 3) {
          final edits = (entry as List).map(identified).toList();
          if (edits.isEmpty) throw const FormatException('編集履歴が空です。');
          return edits;
        }
        if (version == 2 && entry is List && entry.isNotEmpty && entry.first is List) return entry.map(single).toList();
        return [single(entry)];
      }).toList();
      final undo = read(history['undo']), redo = read(history['redo']);
      // Replay both directions on a copy before exposing history to the editor.
      final copyData = jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
      final copy = ScoreDocument._(copyData, ProjectIdentity(copyData, score.identity.toJson()));
      for (final batch in undo.reversed) {
        for (final e in batch.reversed) { e.revert(copy); }
      }
      for (final batch in [...undo, ...redo.reversed]) {
        for (final e in batch) { e.apply(copy); }
      }
      score._undo.addAll(undo); score._redo.addAll(redo);
      return score;
    } on TypeError { throw const FormatException('編集履歴の形式が不正です。');
    } on RangeError { throw const FormatException('編集履歴の位置が不正です。'); }
  }

  // ------------------------------------------------------------- reading

  Map<String, dynamic> measure(int staff, int m) => measures(staff)[m] as Map<String, dynamic>;
  Map<String, dynamic> event(int staff, int m, int e) => events(staff, m)[e] as Map<String, dynamic>;
  static BeatFraction _fraction(Object? v) => BeatFraction.parse(v);
  static String _text(BeatFraction f) => f.denominator == 1 ? '${f.numerator}' : '$f';
  static int _voice(Map e) => (e['voice'] as num?)?.toInt() ?? 0;

  /// Bar length in quarter beats from the time signature.
  BeatFraction barLength(int staff, int m) {
    final time = measure(staff, m)['time_sig'];
    if (time is List && time.length == 2 && time[0] is int && time[1] is int && time[0] > 0 && time[1] > 0) {
      return BeatFraction((time[0] as int) * 4, time[1] as int);
    }
    return BeatFraction.of(4);
  }

  /// The event following [e] in its voice inside the same bar (no gap).
  int? nextInVoice(int staff, int m, int e) {
    final current = event(staff, m, e);
    if (current['grace'] == true) return null;
    final end = _fraction(current['onset']) + _fraction(current['duration']);
    final list = events(staff, m);
    for (var i = 0; i < list.length; i++) {
      final other = list[i] as Map;
      if (i == e || other['grace'] == true || _voice(other) != _voice(current)) continue;
      if (_fraction(other['onset']) == end) return i;
    }
    return null;
  }

  /// Written minus sounding pitch for a staff's note heads: from a recognized
  /// head when one exists, otherwise from the staff's octave shift.
  int writtenOffset(int staff, int m, [int? near]) {
    int? from(Map e) {
      final pitches = e['pitches'] as List;
      final heads = headsInPitchOrder(e);
      if (heads == null || pitches.isEmpty) return null;
      return (heads.first['pitch'] as int) - (pitches.first as int);
    }
    if (near != null) { final own = from(event(staff, m, near)); if (own != null) return own; }
    for (final e in events(staff, m)) { final o = from(e as Map); if (o != null) return o; }
    final shift = (staves[staff] as Map)['octave_shift'];
    return shift is int ? -12 * shift : 0;
  }

  /// The event's note heads ordered like its `pitches` (by height on the
  /// page: the lowest head first), or null without one head per pitch.
  static List<Map<String, dynamic>>? headsInPitchOrder(Map event) {
    final place = event['place'];
    if (place is! Map || place['heads'] is! List) return null;
    final heads = (place['heads'] as List).whereType<Map<String, dynamic>>().where((h) => h['y'] is num && h['pitch'] is int).toList();
    if (heads.length != (event['pitches'] as List).length || heads.length != (place['heads'] as List).length) return null;
    return heads..sort((a, b) => (b['y'] as num).compareTo(a['y'] as num));
  }

  // ------------------------------------------------------------- editing

  void transpose(int staff, int measure, int event, int pitch, int delta) {
    final note = events(staff, measure)[event] as Map;
    final pitches = note['pitches'] as List;
    final before = pitches[pitch] as int;
    final after = before + delta;
    if (after < 0 || after > 127) throw const FormatException('MIDI音高の範囲外です。');
    final targets = <({int measure, int event, int pitch})>[];
    if (note['tie_start'] == true || note['tie_stop'] == true) {
      final nodes = _tieNodes(staff, before);
      final selected = nodes.where((n) => n.measure == measure && n.event == event && n.pitch == pitch).toList();
      if (selected.length != 1) throw const FormatException('タイ接続を確認できません。');
      final pending = [selected.single], visited = <_TieNote>{};
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        if (!visited.add(current)) continue;
        for (final forward in [true, false]) {
          if (current.note[forward ? 'tie_start' : 'tie_stop'] != true) continue;
          final next = _tieMatch(nodes, current, forward);
          if (!identical(_tieMatch(nodes, next, !forward), current)) throw const FormatException('タイが複数の声部へ分岐しています。原譜を確認してください。');
          pending.add(next);
        }
      }
      for (final n in visited) { targets.add((measure: n.measure, event: n.event, pitch: n.pitch)); }
    } else { targets.add((measure: measure, event: event, pitch: pitch)); }
    if (before == after) return;
    identity.checkRevision();
    final edits = [for (final t in targets) _PitchChange(identity.partId(staff), identity.measureId(staff, t.measure),
      identity.noteId(staff, t.measure, t.event), identity.pitchId(staff, t.measure, t.event, t.pitch), before, after)];
    // All validation finishes before changing any note in the transaction.
    for (final e in edits) { e.apply(this); }
    _push(edits);
  }

  /// Sets one pitch (and its tie chain) to [sounding].
  void setPitch(int staff, int measure, int event, int pitch, int sounding) =>
    transpose(staff, measure, event, pitch, sounding - ((events(staff, measure)[event] as Map)['pitches'] as List)[pitch] as int);

  /// Turns a rest into a note. [head] places the new note head on the page
  /// (1920-wide page pixels) so the overlay can draw it.
  void restToNote(int staff, int m, int e, int sounding, {({double x, double y, int written})? head}) {
    final current = event(staff, m, e);
    if ((current['pitches'] as List).isNotEmpty) throw const FormatException('休符ではありません。');
    if (current['grace'] == true) throw const FormatException('小音符は音の高さだけ直せます。');
    _range(sounding);
    final next = _copy(current)..['pitches'] = [sounding]..remove('inferred_rest');
    final oldPlace = current['place'];
    final x = head?.x ?? (oldPlace is Map && oldPlace['x'] is num ? (oldPlace['x'] as num).toDouble() : null);
    if (head != null) {
      next['place'] = {'x': head.x, 'heads': [{'pitch': head.written, 'x': head.x, 'y': head.y, 'confidence': 0.0, 'snapped': false, 'manual': true}]};
    } else if (x != null) {
      next['place'] = {'x': x};
    } else { next.remove('place'); }
    _commit({(staff, m): _replacing(staff, m, {e: [_Snap(identity.noteId(staff, m, e), [identity.newId()], next)]})});
  }

  /// Turns a note into a rest of the same length. Ties to it are removed.
  void noteToRest(int staff, int m, int e) {
    final current = event(staff, m, e);
    if ((current['pitches'] as List).isEmpty) throw const FormatException('すでに休符です。');
    if (current['grace'] == true) throw const FormatException('小音符は休符にできません。');
    final next = _copy(current)..['pitches'] = []..remove('tie_start')..remove('tie_stop');
    final place = current['place'];
    if (place is Map && place['x'] is num) { next['place'] = {'x': place['x']}; } else { next.remove('place'); }
    final changes = <(int, int), Map<int, List<_Snap>>>{(staff, m): {e: [_Snap(identity.noteId(staff, m, e), [], next)]}};
    for (final forward in [true, false]) {
      if (current[forward ? 'tie_start' : 'tie_stop'] != true) continue;
      final partner = _tiePartner(staff, m, e, forward);
      if (partner == null) continue;
      final edited = _copy(event(staff, partner.$1, partner.$2))..remove(forward ? 'tie_stop' : 'tie_start');
      changes.putIfAbsent((staff, partner.$1), () => {})[partner.$2] = [_keep(staff, partner.$1, partner.$2, edited)];
    }
    _commit({for (final c in changes.entries) c.key: _replacing(staff, c.key.$2, c.value)});
  }

  /// Splits an event in two, the first lasting [first] (default: half).
  /// Both halves keep the pitches; the second is a new note.
  void split(int staff, int m, int e, {BeatFraction? first}) {
    final current = event(staff, m, e);
    if (current['grace'] == true) throw const FormatException('小音符は分けられません。');
    final onset = _fraction(current['onset']), duration = _fraction(current['duration']);
    final a = first ?? duration * BeatFraction(1, 2);
    if (a <= BeatFraction.zero || a >= duration) throw const FormatException('この長さには分けられません。');
    if ((duration - a).denominator > 64 || a.denominator > 64) throw const FormatException('これより短くは分けられません。');
    // The first half keeps how the event begins, the second how it ends.
    final head = _copy(current)..['duration'] = _text(a)..remove('tie_start');
    if (head['slur_stops'] != null) head['slur_stops'] = <String>[];
    final tail = _copy(current)..['onset'] = _text(onset + a)..['duration'] = _text(duration - a)..remove('tie_stop');
    if (tail['slur_starts'] != null) tail['slur_starts'] = <String>[];
    // The second half's position on the page lies between this event and the next.
    final x = _estimateX(staff, m, e, a / duration);
    final place = current['place'];
    if (x == null || place is! Map) {
      tail.remove('place');
    } else {
      tail['place'] = {'x': x, if (place['heads'] is List) 'heads': [
        for (final h in (place['heads'] as List).whereType<Map>()) {...h, 'x': x, 'confidence': 0.0, 'snapped': false, 'manual': true},
      ]};
    }
    final pitchIds = [for (final _ in current['pitches'] as List) identity.newId()];
    _commit({(staff, m): _replacing(staff, m, {e: [
      _keep(staff, m, e, head), _Snap(identity.newId(), pitchIds, tail),
    ]})});
  }

  /// Merges an event with the next one in its voice; the first one's pitches
  /// last for both.
  void mergeWithNext(int staff, int m, int e) {
    final n = nextInVoice(staff, m, e);
    if (n == null) throw const FormatException('同じ声部で続く音符がこの小節にありません。');
    final a = event(staff, m, e), b = event(staff, m, n);
    final merged = _copy(a)..['duration'] = _text(_fraction(a['duration']) + _fraction(b['duration']))..remove('tie_start');
    if (b['tie_start'] == true && (a['pitches'] as List).isNotEmpty) merged['tie_start'] = true;
    final stops = [...?(a['slur_stops'] as List?), ...?(b['slur_stops'] as List?)];
    if (stops.isNotEmpty) merged['slur_stops'] = stops;
    final changes = <(int, int), Map<int, List<_Snap>>>{(staff, m): {e: [_keep(staff, m, e, merged)], n: []}};
    // A tie that ended on the removed event now ends nowhere.
    if (a['tie_start'] == true && b['tie_stop'] != true) {
      final partner = _tiePartner(staff, m, e, true);
      if (partner != null && partner != (m, n)) {
        changes.putIfAbsent((staff, partner.$1), () => {})[partner.$2] =
          [_keep(staff, partner.$1, partner.$2, _copy(event(staff, partner.$1, partner.$2))..remove('tie_stop'))];
      }
    }
    if (b['tie_start'] == true && merged['tie_start'] != true) {
      final partner = _tiePartner(staff, m, n, true);
      if (partner != null) {
        changes.putIfAbsent((staff, partner.$1), () => {})[partner.$2] =
          [_keep(staff, partner.$1, partner.$2, _copy(event(staff, partner.$1, partner.$2))..remove('tie_stop'))];
      }
    }
    _commit({for (final c in changes.entries) c.key: _replacing(staff, c.key.$2, c.value)});
  }

  /// Adds a chord tone. [head] places it on the page like [restToNote].
  void addChordTone(int staff, int m, int e, int sounding, {({double x, double y, int written})? head}) {
    final current = event(staff, m, e);
    final pitches = current['pitches'] as List;
    if (pitches.isEmpty) return restToNote(staff, m, e, sounding, head: head);
    _range(sounding);
    if (pitches.contains(sounding)) throw const FormatException('その音はすでにあります。');
    final next = _copy(current);
    final ids = identity.pitchIds(staff, m, e);
    final heads = headsInPitchOrder(current);
    final place = next['place'];
    var index = pitches.length;
    if (heads != null && head != null && place is Map) {
      // Pitches stay index-aligned with heads ordered by height.
      index = heads.where((h) => (h['y'] as num) > head.y).length;
      (place['heads'] as List).add({'pitch': head.written, 'x': head.x, 'y': head.y, 'confidence': 0.0, 'snapped': false, 'manual': true});
    } else if (place is Map) {
      place.remove('heads');
    }
    (next['pitches'] as List).insert(index, sounding);
    ids.insert(index, identity.newId());
    _commit({(staff, m): _replacing(staff, m, {e: [_Snap(identity.noteId(staff, m, e), ids, next)]})});
  }

  /// Removes one chord tone (the last one becomes a rest).
  void removeChordTone(int staff, int m, int e, int pitch) {
    final current = event(staff, m, e);
    final pitches = current['pitches'] as List;
    if (pitches.length <= 1) return noteToRest(staff, m, e);
    final next = _copy(current);
    final heads = headsInPitchOrder(next);
    final place = next['place'];
    if (heads != null && place is Map) { (place['heads'] as List).remove(heads[pitch]); } else if (place is Map) { place.remove('heads'); }
    (next['pitches'] as List).removeAt(pitch);
    final ids = identity.pitchIds(staff, m, e)..removeAt(pitch);
    _commit({(staff, m): _replacing(staff, m, {e: [_Snap(identity.noteId(staff, m, e), ids, next)]})});
  }

  void undo() {
    if (_undo.isEmpty) return;
    identity.checkRevision();
    final batch = _undo.last;
    for (final e in batch.reversed) { e.revert(this); }
    _undo.removeLast(); _redo.add(batch); identity.advanceRevision();
  }

  void redo() {
    if (_redo.isEmpty) return;
    identity.checkRevision();
    final batch = _redo.last;
    for (final e in batch) { e.apply(this); }
    _redo.removeLast(); _undo.add(batch); identity.advanceRevision();
  }

  // ------------------------------------------------------------ internals

  void _push(List<_Edit> edits) { _undo.add(edits); _redo.clear(); identity.advanceRevision(); }
  static void _range(int pitch) { if (pitch < 0 || pitch > 127) throw const FormatException('MIDI音高の範囲外です。'); }
  static Map<String, dynamic> _copy(Map event) => (jsonDecode(jsonEncode(event)) as Map).cast<String, dynamic>();
  _Snap _keep(int staff, int m, int e, Map<String, dynamic> event) =>
    _Snap(identity.noteId(staff, m, e), identity.pitchIds(staff, m, e), event);

  /// The bar's events after replacing some of them (index -> replacements).
  List<_Snap> _replacing(int staff, int m, Map<int, List<_Snap>> replace) => [
    for (var i = 0; i < events(staff, m).length; i++)
      ...replace[i] ?? [_keep(staff, m, i, _copy(event(staff, m, i)))],
  ];

  void _commit(Map<(int, int), List<_Snap>> bars) {
    identity.checkRevision();
    final edits = <_Edit>[];
    for (final entry in bars.entries) {
      final (staff, m) = entry.key;
      for (final s in entry.value) { _checkEvent(s.event); }
      final before = [for (var i = 0; i < events(staff, m).length; i++) _keep(staff, m, i, _copy(event(staff, m, i)))];
      edits.add(_BarReplace(identity.partId(staff), identity.measureId(staff, m), before, entry.value));
    }
    for (final e in edits) { e.apply(this); }
    _push(edits);
  }

  /// Interpolated page x at [fraction] of event [e], toward the next event in
  /// its voice (or the end of the bar).
  double? _estimateX(int staff, int m, int e, BeatFraction fraction) {
    double? x(Map? ev) => ev?['place'] is Map && ev!['place']['x'] is num ? (ev['place']['x'] as num).toDouble() : null;
    final start = x(event(staff, m, e));
    if (start == null) return null;
    final n = nextInVoice(staff, m, e);
    final bounds = measure(staff, m)['bounds'];
    final end = n != null ? x(event(staff, m, n)) : bounds is Map && bounds['x1'] is num ? (bounds['x1'] as num).toDouble() - 12 : null;
    if (end == null || end <= start) return start + 24;
    return start + (end - start) * fraction.numerator / fraction.denominator;
  }

  List<_TieNote> _tieNodes(int staff, int? pitch) {
    final nodes = <_TieNote>[];
    var base = BeatFraction.zero;
    for (var m = 0; m < measures(staff).length; m++) {
      for (var e = 0; e < events(staff, m).length; e++) {
        final item = events(staff, m)[e] as Map;
        if (item['grace'] == true) continue;
        final start = base + _fraction(item['onset']);
        final end = start + _fraction(item['duration']);
        if (end.compareTo(start) <= 0) continue;
        final pitches = item['pitches'] as List;
        for (var p = 0; p < pitches.length; p++) {
          if (pitch == null || pitches[p] == pitch) nodes.add(_TieNote(m, e, p, item, start, end));
        }
      }
      base = base + barLength(staff, m);
    }
    return nodes;
  }

  static _TieNote _tieMatch(List<_TieNote> nodes, _TieNote current, bool forward) {
    var candidates = nodes.where((n) => !identical(n, current) &&
      n.note[forward ? 'tie_stop' : 'tie_start'] == true &&
      (forward ? n.start == current.end : n.end == current.start)).toList();
    final sameVoice = candidates.where((n) => _voice(n.note) == _voice(current.note)).toList();
    if (sameVoice.isNotEmpty) candidates = sameVoice;
    if (candidates.length != 1) throw const FormatException('タイの接続先が曖昧です。原譜を確認してください。');
    return candidates.single;
  }

  /// The event a tie from (or to) [e] connects to, if it can be found.
  (int, int)? _tiePartner(int staff, int m, int e, bool forward) {
    final nodes = _tieNodes(staff, null);
    final own = nodes.where((n) => n.measure == m && n.event == e).toList();
    for (final node in own) {
      try {
        final pitch = (node.note['pitches'] as List)[node.pitch];
        final partner = _tieMatch(nodes.where((n) => (n.note['pitches'] as List)[n.pitch] == pitch).toList(), node, forward);
        return (partner.measure, partner.event);
      } on FormatException { continue; }
    }
    return null;
  }

  /// A deliberately limited single-measure preview. Grace and tied notes are
  /// rejected because their performed timing requires the full playback engine.
  List<Map<String, int>> preview(int staff, int measure) {
    final tempo = (data['tempo_bpm'] as num?)?.toDouble() ?? 80;
    if (!tempo.isFinite || tempo <= 0 || tempo > 400) throw const FormatException('テンポが不正です。');
    final result = <Map<String, int>>[];
    for (final dynamic e in events(staff, measure)) {
      final pitches = e['pitches'] as List;
      if (pitches.isEmpty) continue;
      if (e['grace'] == true || e['tie_start'] == true || e['tie_stop'] == true) {
        throw const FormatException('この小節にはタイまたは小音符があるため、試聴に対応していません。');
      }
      final start = (beat(e['onset']) * 60000 / tempo).round();
      final duration = (beat(e['duration']) * 60000 / tempo).round();
      if (start < 0 || duration <= 0 || start + duration > 120000) throw const FormatException('試聴できない音符の長さです。');
      for (final p in pitches) { result.add({'pitch': p as int, 'start': start, 'duration': duration}); }
    }
    if (result.length > 1024) throw const FormatException('音符が多すぎます。');
    return result;
  }

  /// Plays one staff in written order only when no unsupported navigation,
  /// ties or grace notes would make that order misleading.
  List<Map<String, int>> previewStaff(int staff) {
    for (final s in staves) {
      for (final m in s['measures'] as List) {
        if (m['repeat_start'] == true || (m['repeat_end'] is num && m['repeat_end'] > 0) ||
            (m['ending_numbers'] is List && (m['ending_numbers'] as List).isNotEmpty) ||
            (m['navigation'] is List && (m['navigation'] as List).isNotEmpty)) {
          throw const FormatException('反復・括弧・移動記号を含む曲の通し試聴はまだ対応していません。');
        }
      }
    }
    final meta = data['meta'];
    if (meta is Map && meta['repeat_override'] != null) {
      throw const FormatException('再生順が指定された曲の通し試聴はまだ対応していません。');
    }
    final tempo = (data['tempo_bpm'] as num?)?.toDouble() ?? 80;
    if (!tempo.isFinite || tempo <= 0 || tempo > 400) throw const FormatException('テンポが不正です。');
    final output = <Map<String, int>>[];
    double offsetBeats = 0;
    for (var i = 0; i < measures(staff).length; i++) {
      final m = measures(staff)[i] as Map;
      final signature = m['time_sig'] ?? [4, 4];
      if (signature is! List || signature.length != 2 || signature[0] is! num || signature[1] is! num || signature[0] <= 0 || signature[1] <= 0) {
        throw const FormatException('拍子が不正です。');
      }
      final length = (signature[0] as num) * 4 / (signature[1] as num);
      for (final dynamic event in events(staff, i)) {
        final pitches = event['pitches'] as List;
        if (pitches.isEmpty) continue;
        if (event['grace'] == true || event['tie_start'] == true || event['tie_stop'] == true) {
          throw const FormatException('タイまたは小音符を含む曲の通し試聴はまだ対応していません。');
        }
        final onset = beat(event['onset']);
        final duration = beat(event['duration']);
        if (duration <= 0 || onset + duration > length + 0.0000001) throw const FormatException('小節を超える音符は通し試聴できません。');
        final startMs = ((offsetBeats + onset) * 60000 / tempo).round();
        final endMs = ((offsetBeats + onset + duration) * 60000 / tempo).round();
        if (endMs > 1800000 || endMs <= startMs) throw const FormatException('試聴できない曲の長さです。');
        for (final p in pitches) { output.add({'pitch': p as int, 'start': startMs, 'duration': endMs - startMs}); }
      }
      offsetBeats += length;
      if (offsetBeats * 60000 / tempo > 1800000) throw const FormatException('通し試聴は30分以内です。');
    }
    if (output.length > 50000) throw const FormatException('音符が多すぎます。');
    return output;
  }
}

abstract class _Edit {
  void apply(ScoreDocument d);
  void revert(ScoreDocument d);
  Map<String, dynamic> toJson();
}

/// One pitch of one note, by ID. Also moves the note head drawn on the page.
class _PitchChange implements _Edit {
  _PitchChange(this.part, this.measure, this.note, this.pitch, this.before, this.after);
  final String part, measure, note, pitch;
  final int before, after;
  @override void apply(ScoreDocument d) => _set(d, before, after);
  @override void revert(ScoreDocument d) => _set(d, after, before);
  void _set(ScoreDocument d, int expected, int value) {
    final at = d.identity.locate({'part_id': part, 'measure_id': measure, 'note_id': note, 'pitch_id': pitch});
    final event = d.event(at.staff, at.measure, at.event);
    final pitches = event['pitches'] as List;
    if (pitches[at.pitch] != expected) throw const FormatException('編集履歴が楽譜と一致しません。');
    final heads = ScoreDocument.headsInPitchOrder(event);
    if (heads != null) heads[at.pitch]['pitch'] = (heads[at.pitch]['pitch'] as int) + value - expected;
    pitches[at.pitch] = value;
  }
  @override Map<String, dynamic> toJson() =>
    {'part_id': part, 'measure_id': measure, 'note_id': note, 'pitch_id': pitch, 'before': before, 'after': after};
}

/// A bar's events with their IDs.
class _Snap {
  _Snap(this.note, this.pitchIds, this.event);
  final String note;
  final List<String> pitchIds;
  final Map<String, dynamic> event;
  Map<String, dynamic> toJson() => {'note_id': note, 'pitch_ids': pitchIds, 'event': event};
  static _Snap fromJson(Object? value) {
    final v = value as Map;
    final event = (v['event'] as Map).cast<String, dynamic>();
    ScoreDocument._checkEvent(event);
    final ids = (v['pitch_ids'] as List).cast<String>();
    if (ids.length != (event['pitches'] as List).length || v['note_id'] is! String) throw const FormatException('編集履歴のIDが不正です。');
    return _Snap(v['note_id'] as String, ids, event);
  }
}

/// All events of one bar before and after a structural edit.
class _BarReplace implements _Edit {
  _BarReplace(this.part, this.measure, this.before, this.after);
  factory _BarReplace.fromJson(Map v) => _BarReplace(v['part_id'] as String, v['measure_id'] as String,
    [for (final s in v['before'] as List) _Snap.fromJson(s)], [for (final s in v['after'] as List) _Snap.fromJson(s)]);
  final String part, measure;
  final List<_Snap> before, after;
  @override void apply(ScoreDocument d) => _swap(d, before, after);
  @override void revert(ScoreDocument d) => _swap(d, after, before);
  void _swap(ScoreDocument d, List<_Snap> expected, List<_Snap> value) {
    final at = d.identity.locateMeasure(part, measure);
    final current = d.events(at.staff, at.measure);
    if (current.length != expected.length) throw const FormatException('編集履歴が楽譜と一致しません。');
    for (var i = 0; i < current.length; i++) {
      if (d.identity.noteId(at.staff, at.measure, i) != expected[i].note || !_same(current[i], expected[i].event)) {
        throw const FormatException('編集履歴が楽譜と一致しません。');
      }
    }
    d.identity.replaceEvents(at.staff, at.measure, [for (final s in value) ScoreDocument._copy(s.event)],
      [for (final s in value) s.note], [for (final s in value) List.of(s.pitchIds)]);
  }
  @override Map<String, dynamic> toJson() => {'kind': 'bar', 'part_id': part, 'measure_id': measure,
    'before': [for (final s in before) s.toJson()], 'after': [for (final s in after) s.toJson()]};
}

bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length && a.keys.every((k) => b.containsKey(k) && _same(a[k], b[k]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) { if (!_same(a[i], b[i])) return false; }
    return true;
  }
  return a == b;
}

class _TieNote {
  _TieNote(this.measure, this.event, this.pitch, this.note, this.start, this.end);
  final int measure, event, pitch;
  final Map note;
  final BeatFraction start, end;
}

String pitchName(int midi) => '${const ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'][midi % 12]}${midi ~/ 12 - 1}';
