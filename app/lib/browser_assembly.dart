/// Recognised pages -> playable score, the same way as the browser version.
///
/// The browser (PC) back end runs homr per *system*, converts each staff to
/// the IR, merges the systems with `structure.assemble` and corrects the
/// result with `postprocess`. This module does the same on the device with
/// the Dart ports in score_structure.dart / score_postprocess.dart.
library;

import 'grand_staff_timing.dart';
import 'omr_bridge.dart';
import 'omr_staff_assembler.dart';
import 'omr_symbols.dart';
import 'score_ir.dart';
import 'score_postprocess.dart';
import 'score_structure.dart';
import 'tempo_marks.dart';
import 'voice_labels.dart';

/// Drop lower-position tokens, as homr does for a staff that is not part of
/// a recognised grand staff.
List<OmrSymbol> upperSymbols(List<OmrSymbol> symbols) {
  final out = <OmrSymbol>[];
  for (final group in groupOmrChords(symbols)) {
    final kept = group.where((s) => s.position != 'lower').toList();
    for (var i = 0; i < kept.length; i++) {
      if (i > 0) out.add(const OmrSymbol(rhythm: 'chord', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'));
      out.add(kept[i]);
    }
  }
  return out;
}

/// One recognised staff of one system -> IR staff (homr MusicXML + PC import).
Staff staffFromSymbols(List<OmrSymbol> symbols, {String id = 'S1'}) {
  final map = OmrStaffAssembler().assemble(upperSymbols(symbols), staffId: id, detectTies: false, keepOpenSlurs: true);
  // homr's slur channel carries many ties (PC `_homr_curve_ties`).
  OmrStaffAssembler.resolveTies(map);
  final staff = Staff.fromJson(map);
  staff.id = id;
  staff.role = unknownRole;
  // A lone whole rest fills a shorter bar, as the PC MusicXML import reads it.
  for (final m in staff.measures) {
    final main = m.events.where((e) => !e.grace).toList();
    final nominal = m.nominalLength();
    if (main.length == 1 && main.first.isRest && main.first.onset == zeroFrac &&
        main.first.duration == frac(4) && nominal < frac(4) && nominal > zeroFrac) {
      main.first.duration = nominal;
    }
  }
  return staff;
}

/// Ties across a system break. homr reads one system at a time, so such a
/// tie is a slur left open at the end of one system and a slur closing on
/// the first note of the next. They become a tie when the note ends its bar,
/// the next starts the next bar and they share a pitch. All open markers are
/// removed afterwards (an unmatched slur end is dropped, as before).
void joinSystemTies(Score score) {
  for (final staff in score.staves) {
    final ms = staff.measures;
    for (var i = 1; i < ms.length; i++) {
      final prev = ms[i - 1], cur = ms[i];
      if (prev.page == cur.page && prev.system == cur.system) continue;
      final barEnd = prev.events.where((e) => !e.grace).fold(zeroFrac, (a, e) => e.end > a ? e.end : a);
      final tails = [for (final e in prev.events)
        if (!e.grace && !e.isRest && e.end == barEnd && e.slurStarts.contains(openSlurStart)) e];
      final heads = [for (final e in cur.events)
        if (!e.grace && !e.isRest && e.onset == zeroFrac && e.slurStops.contains(openSlurStop)) e];
      for (final t in tails) {
        final matches = heads.where((h) => h.pitches.any(t.pitches.contains)).toList();
        final same = matches.where((h) => h.voice == t.voice).toList();
        final h = same.length == 1 ? same.single : matches.length == 1 ? matches.single : null;
        if (h == null) continue;
        t.tieStart = true;
        h.tieStop = true;
        heads.remove(h);
      }
    }
    for (final m in ms) {
      for (final e in m.events) {
        e.slurStarts.remove(openSlurStart);
        e.slurStops.remove(openSlurStop);
      }
    }
  }
}

double _top(RecognizedStaffSymbols s) => s.lines.length == 5 ? s.lines.first : s.crop[1].toDouble();
double _bottom(RecognizedStaffSymbols s) => s.lines.length == 5 ? s.lines.last : s.crop[3].toDouble();

double _median(List<double> values) {
  final v = [...values]..sort();
  if (v.isEmpty) return 0;
  final mid = v.length ~/ 2;
  return v.length.isOdd ? v[mid] : (v[mid - 1] + v[mid]) / 2;
}

/// Gap heuristic of the PC `systems._split_by_gaps` (used when the page gives
/// no image evidence). Returns systems of staff indices.
List<SystemLayout> systemsByGaps(List<RecognizedStaffSymbols> staves) {
  if (staves.isEmpty) return [];
  if (staves.length == 1) return const [SystemLayout([0])];
  final rel = <double>[];
  for (var i = 0; i + 1 < staves.length; i++) {
    final gap = _top(staves[i + 1]) - _bottom(staves[i]);
    final height = (_bottom(staves[i]) - _top(staves[i])).clamp(1.0, double.infinity);
    rel.add(gap / height);
  }
  final med = _median(rel);
  final systems = <SystemLayout>[];
  var current = <int>[0];
  for (var i = 0; i < rel.length; i++) {
    if (rel[i] > 1.6 * med && rel[i] > 2.0) { systems.add(SystemLayout(current)); current = []; }
    current.add(i + 1);
  }
  systems.add(SystemLayout(current));
  return systems;
}

/// Re-time piano bars with the decoder's x (grand_staff_timing.dart).
/// A switch for A/B evaluation only.
bool grandStaffTimingEnabled = true;

BeatFraction? _majority(Iterable<BeatFraction?> values, {int minCount = 1}) {
  final counts = <BeatFraction, int>{};
  for (final v in values) {
    if (v != null && v > BeatFraction.zero) counts[v] = (counts[v] ?? 0) + 1;
  }
  if (counts.isEmpty) return null;
  final best = counts.entries.reduce((a, b) => b.value > a.value ? b : a);
  final tied = counts.values.where((c) => c == best.value).length > 1;
  return best.value >= minCount && !tied ? best.key : null;
}

/// Token lists of one system with the grand staff's bars re-timed where the
/// two hands do not fill the bar on their own. Bar lengths come from the
/// voices of the same system; a piano-only system uses its own agreeing bars.
List<List<OmrSymbol>> _timedSystem(List<RecognizedStaffSymbols> members, (int, int)? pair, List<String> warnings, String label) {
  // A staff whose chord markers are malformed keeps its raw symbols; its own
  // conversion reports the problem and the other staves are unaffected.
  final tokens = <List<OmrSymbol>>[];
  var malformed = false;
  for (final m in members) {
    try {
      tokens.add(upperSymbols(m.symbols));
    } on FormatException {
      tokens.add(m.symbols);
      malformed = true;
    }
  }
  if (!grandStaffTimingEnabled || pair == null || malformed) return tokens;
  final (ri, li) = pair;
  if (ri >= tokens.length || li >= tokens.length) return tokens;
  final List<List<BeatFraction?>> sums;
  try {
    sums = [for (final t in tokens) barSums(t)];
  } on FormatException {
    return tokens;
  }
  final bars = sums[ri].length;
  if (sums[li].length != bars) return tokens;
  final voices = [for (var i = 0; i < tokens.length; i++) if (i != ri && i != li && sums[i].length == bars) sums[i]];
  final lengths = <BeatFraction?>[];
  if (voices.isNotEmpty) {
    for (var k = 0; k < bars; k++) {
      lengths.add(_majority([for (final v in voices) v[k]], minCount: voices.length >= 3 ? 2 : 1));
    }
  } else {
    final agreed = _majority([for (var k = 0; k < bars; k++) if (sums[ri][k] == sums[li][k]) sums[ri][k]], minCount: 2);
    lengths.addAll(List.filled(bars, agreed));
  }
  final lines = members[ri].lines;
  final space = lines.length == 5 ? (lines.last - lines.first) / 4 : 0.0;
  if (space <= 0) return tokens;
  final timed = alignGrandStaff(tokens[ri], tokens[li], lengths, 1.2 * space);
  if (timed == null) return tokens;
  warnings.add('$label: ピアノ${timed.changedBars.map((k) => k + 1).join('・')}小節目を両手の位置で拍を合わせました。');
  return [for (var i = 0; i < tokens.length; i++) i == ri ? timed.right : i == li ? timed.left : tokens[i]];
}

class BrowserAssemblyResult {
  BrowserAssemblyResult(this.score, this.json);
  final Score score;
  final Map<String, dynamic> json;
}

/// Assemble recognised pages like the browser version. [layout] carries the
/// user's manual ensemble settings (null = automatic).
BrowserAssemblyResult assembleLikeBrowser(List<RecognizedPageSymbols> pages, {EnsembleLayout? layout,
    double? tempo, bool postprocess = true}) {
  if (pages.isEmpty) throw const FormatException('認識ページがありません。');
  final units = <Unit?>[];
  final warnings = <String>[];
  final layoutPages = <Map<String, dynamic>>[];
  for (var p = 0; p < pages.length; p++) {
    final page = pages[p];
    final pageNumber = page.pageNumber ?? p + 1;
    for (final w in page.warnings) {
      // Obsolete notice from older recognitions (layout and assembly exist now).
      if (w == '五線の傾き補正・段組み・声部の組み立ては未対応です。') continue;
      warnings.add('$pageNumberページ: $w');
    }
    final order = List.generate(page.staves.length, (i) => i)
      ..sort((a, b) => _top(page.staves[a]).compareTo(_top(page.staves[b])));
    final staves = [for (final i in order) page.staves[i]];
    if (staves.isEmpty) {
      warnings.add('$pageNumberページ: 五線がないため対象外としました（表紙・歌詞・空白ページ）。');
      continue;
    }
    final systems = page.systems ?? systemsByGaps(staves);
    final regions = <Map<String, dynamic>>[];
    for (var k = 0; k < systems.length; k++) {
      final system = systems[k];
      final members = [for (final i in system.staves) if (i >= 0 && i < staves.length) staves[i]];
      if (members.isEmpty) continue;
      final symbols = _timedSystem(members,
        system.hasBrace && system.pianoExtra == null && members.length == system.staves.length ? system.pianoPair : null,
        warnings, '$pageNumberページ${k + 1}段目');
      final converted = <Staff>[];
      for (var j = 0; j < members.length; j++) {
        final label = '$pageNumberページ${k + 1}段目${j + 1}本目';
        if (!members[j].reachedEos) warnings.add('$label: 記号の生成が上限に達しました。原譜を確認してください。');
        try {
          final staff = staffFromSymbols(symbols[j], id: 'S${j + 1}');
          for (final w in staff.warnings) { warnings.add('$label: $w'); }
          converted.add(staff);
        } on FormatException catch (e) {
          // Keep the position so the other staves keep their voice mapping;
          // the structure step fills the missing measures with rests.
          warnings.add('$label: 記号を楽譜に変換できないため休符で補います（${e.message}）。');
          converted.add(Staff(id: 'S${j + 1}'));
        }
      }
      // An empty ruled staff (staff paper, unused staves at a page end) is
      // read as a clef and a single whole-bar rest. A system holding nothing
      // else is not music and must not vote on the ensemble.
      final empty = converted.every((s) => s.measures.length <= 1 &&
          s.measures.every((m) => m.events.every((e) => e.pitches.isEmpty)));
      if (empty) {
        warnings.add('$pageNumberページ${k + 1}段目: 音符のない五線のため対象外としました。');
        continue;
      }
      final brace = system.hasBrace && system.pianoPair != null && converted.length == system.staves.length;
      units.add(Unit(converted, page: pageNumber, system: k,
        pianoOnly: system.staves.length == 2 && system.hasBrace ? true : null,
        pianoPair: brace ? system.pianoPair : null, pianoExtra: brace ? system.pianoExtra : null,
        imageLayout: page.systems != null));
      regions.add({
        'index': k,
        'x0': members.map((s) => s.left ?? s.crop[0]).reduce((a, b) => a < b ? a : b),
        'x1': members.map((s) => s.right ?? s.crop[2]).reduce((a, b) => a > b ? a : b),
        'y0': members.map((s) => s.crop[1]).reduce((a, b) => a < b ? a : b),
        'y1': members.map((s) => s.crop[3]).reduce((a, b) => a > b ? a : b),
        'staves': members.length,
        if (system.hasBrace && system.pianoPair != null) 'piano_pair': [system.pianoPair!.$1, system.pianoPair!.$2],
      });
    }
    layoutPages.add({'page': pageNumber, 'width': page.width, 'height': page.height, 'systems': regions});
  }
  if (units.isEmpty) throw const FormatException('五線を含むページがありません。PDFと認識結果を確認してください。');
  final score = assembleUnits(units, layout);
  joinSystemTies(score);
  if (score.staves.isEmpty || score.measureCount() == 0) {
    throw const FormatException('楽譜を組み立てられませんでした。原譜の編成を手動で指定してください。');
  }
  // Automatic ensemble: printed part names rename the voices (naming only).
  if (layout?.voiceNames == null && (layout?.ensemble ?? 'auto') == 'auto') {
    applyVoiceLabels(score, pages, warnings);
  }
  if (postprocess) {
    final ensemble = '${score.meta['ensemble'] ?? ''}';
    postprocessScore(score, PostOptions(ensemble: ensemble == 'auto' || ensemble == 'custom' ? '' : ensemble));
  }
  // Tempo: the caller's value, else the printed opening mark, else 80.
  if (tempo != null) {
    score.tempoBpm = tempo;
    score.meta['tempo'] = {'bpm': tempo, 'source': 'given'};
  } else {
    final first = score.staves.firstWhere((s) => s.measures.isNotEmpty, orElse: () => score.staves.first);
    final mark = tempoFromLabels(pages, first.measures.isEmpty ? (4, 4) : first.measures.first.timeSig);
    if (mark != null) {
      score.tempoBpm = mark.bpm;
      score.meta['tempo'] = mark.toJson();
      final bpm = mark.bpm == mark.bpm.roundToDouble() ? '${mark.bpm.round()}' : mark.bpm.toStringAsFixed(1);
      warnings.add('テンポを譜面の表記から読み取りました: ${tempoUnitSymbol(mark.unit)}=${mark.printed}'
          '${mark.unit == 'quarter' ? '' : '（4分音符で$bpm）'}${mark.assumedUnit ? '。音符の種類は拍子から判断しました' : ''}。');
    } else {
      score.tempoBpm = 80;
      score.meta['tempo'] = {'bpm': 80, 'source': 'default'};
      warnings.add('テンポ表記を読み取れなかったため、♩=80としました。');
    }
  }
  score.warnings.insertAll(0, warnings);
  final names = (score.meta['voice_names'] as List?)?.cast<String>() ?? const [];
  final added = [for (final s in score.staves) if (s.added) s.name];
  score.warnings.add('編成を推定しました: ${names.join(', ')}${score.meta['piano'] == true ? '＋ピアノ' : '（無伴奏）'}'
      '${added.isEmpty ? '' : '、途中から${added.join(', ')}'}。原譜と照合してください。');
  final json = score.toJson();
  final meta = json['meta'] as Map<String, dynamic>;
  meta['experimental_omr'] = true;
  meta['assembly'] = 'browser-parity-v1';
  meta['pages'] = [for (final p in layoutPages) p['page']];
  meta['layout'] = {'pages': layoutPages};
  return BrowserAssemblyResult(score, json);
}
