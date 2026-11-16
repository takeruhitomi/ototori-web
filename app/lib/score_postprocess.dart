/// Post-processing corrections on the score IR.
///
/// Port of the PC/browser back end `choir_omr/postprocess.py` (SPEC §8).
/// Steps, in order: key vote, time vote, measure-length consensus, rhythm
/// repair, measure-length normalisation, octave shift, tie merge, voice range
/// clamp, empty-measure fill. Every step mutates the score in place.
library;

import 'score_ir.dart';
import 'score_structure.dart' show stableSort;

const voiceRangesByEnsemble = <String, Map<String, (int, int)>>{
  'TTBB': {'tenor': (48, 71), 'baritone': (43, 65), 'bass': (38, 62)},
  'SATB': {'soprano': (60, 84), 'alto': (53, 77), 'tenor': (48, 69), 'bass': (40, 64)},
};
const defaultVoiceRanges = <String, (int, int)>{
  'soprano': (60, 84), 'alto': (53, 77), 'tenor': (48, 71), 'baritone': (43, 65), 'bass': (38, 64),
};

(int, int)? voiceRangeFor(String voiceType, [String ensemble = '']) {
  final vt = voiceType.trim().toLowerCase();
  if (vt.isEmpty) return null;
  final table = voiceRangesByEnsemble[ensemble.toUpperCase()];
  if (table != null && table.containsKey(vt)) return table[vt];
  return defaultVoiceRanges[vt];
}

class PostOptions {
  PostOptions({this.keyFifths, this.timeSig, Frac? tolerance, this.keyPersistSystems = 2,
    this.fallbackSystemMeasures = 4, this.ensemble = '', this.clampOutsideFraction = 0.6,
    this.clampFixedFraction = 0.8, this.consensusMinStaves = 2, this.repairMaxEvents = 24,
    this.repairMaxCost = 6.0})
      : tolerance = tolerance ?? frac(1, 8);
  final int? keyFifths;
  final (int, int)? timeSig;
  final Frac tolerance;
  final int keyPersistSystems, fallbackSystemMeasures, consensusMinStaves, repairMaxEvents;
  final String ensemble;
  final double clampOutsideFraction, clampFixedFraction, repairMaxCost;
  bool doVoteKey = true, doVoteTime = true, doConsensusLengths = true, doRhythmRepair = true,
      doNormalizeLengths = true, doOctaveShift = true, doMergeTies = true, doClampRanges = true,
      doFillEmpty = true;
  (int, int)? rangeFor(String voiceType) => voiceRangeFor(voiceType, ensemble);
}

Map<String, dynamic> _noteMeta(Score score) =>
    (score.meta['postprocess'] ??= <String, dynamic>{}) as Map<String, dynamic>;

List<List<Measure>> _measureColumns(Score score) {
  final n = score.measureCount();
  return [for (var i = 0; i < n; i++) [for (final s in score.staves) if (i < s.measures.length) s.measures[i]]];
}

List<int> _systemIds(List<List<Measure>> columns, int fallbackSize) {
  final ids = <int>[];
  var current = -1;
  Object? lastKey;
  var blockCount = 0;
  for (final col in columns) {
    final page = col.map((m) => m.page).firstWhere((p) => p != null, orElse: () => null);
    final system = col.map((m) => m.system).firstWhere((s) => s != null, orElse: () => null);
    if (system != null) {
      final key = ('sys', page, system);
      if (key != lastKey) { current++; lastKey = key; }
    } else {
      final key = ('blk', page, null);
      if (key != lastKey || blockCount >= (fallbackSize < 1 ? 1 : fallbackSize)) {
        current++; lastKey = key; blockCount = 0;
      }
      blockCount++;
    }
    ids.add(current);
  }
  return ids;
}

List<T> _smoothRuns<T>(List<T> values, int minPersist) {
  if (values.isEmpty) return [];
  final runs = <(T, int)>[];
  for (final v in values) {
    if (runs.isNotEmpty && runs.last.$1 == v) {
      runs[runs.length - 1] = (v, runs.last.$2 + 1);
    } else {
      runs.add((v, 1));
    }
  }
  if (runs.length == 1) return [...values];
  T? accepted;
  var found = false;
  for (final (v, length) in runs) { if (length >= minPersist) { accepted = v; found = true; break; } }
  if (!found) {
    var best = runs.first;
    for (final r in runs) { if (r.$2 > best.$2) best = r; }
    accepted = best.$1;
  }
  final out = <T>[];
  for (final (v, length) in runs) {
    if (length >= minPersist) accepted = v;
    for (var i = 0; i < length; i++) { out.add(accepted as T); }
  }
  return out;
}

List<NoteEvent> _voiceEvents(Measure measure, int voice) {
  final list = [for (final e in measure.events) if (e.voice == voice) e];
  stableSort(list, (a, b) {
    final c = a.onset.compareTo(b.onset);
    if (c != 0) return c;
    // graces first (Python key: e.grace is False)
    return (a.grace ? 0 : 1).compareTo(b.grace ? 0 : 1);
  });
  return list;
}

// ---------------------------------------------------------------- 1. key
void voteKeySignature(Score score, PostOptions options) {
  final columns = _measureColumns(score);
  if (columns.isEmpty) return;
  var changed = 0;
  if (options.keyFifths != null) {
    final forced = options.keyFifths!.clamp(-7, 7);
    for (final col in columns) {
      for (final m in col) {
        if (m.keyFifths != forced) { m.warnings.add('key signature ${m.keyFifths} forced to $forced'); m.keyFifths = forced; changed++; }
      }
    }
    _noteMeta(score)['key_fifths'] = forced;
    _noteMeta(score)['key_changes'] = changed;
    return;
  }
  int? prev;
  final perMeasure = <int>[];
  for (final col in columns) {
    final vals = [for (final m in col) if (m.keyFifths >= -7 && m.keyFifths <= 7) m.keyFifths];
    final v = majority(vals, prefer: prev) ?? prev ?? 0;
    perMeasure.add(v);
    prev = v;
  }
  final sysIds = _systemIds(columns, options.fallbackSystemMeasures);
  final sysValues = <int, List<int>>{};
  for (var i = 0; i < sysIds.length; i++) { (sysValues[sysIds[i]] ??= []).add(perMeasure[i]); }
  final ordered = sysValues.keys.toList()..sort();
  final sysKey = [for (final sid in ordered) majority(sysValues[sid]!)!];
  final smoothed = _smoothRuns(sysKey, options.keyPersistSystems < 1 ? 1 : options.keyPersistSystems);
  final finalBySys = {for (var i = 0; i < ordered.length; i++) ordered[i]: smoothed[i]};
  for (var i = 0; i < columns.length; i++) {
    final k = finalBySys[sysIds[i]]!;
    for (final m in columns[i]) {
      if (m.keyFifths != k) { m.warnings.add('key signature ${m.keyFifths} -> $k (vote)'); m.keyFifths = k; changed++; }
    }
  }
  _noteMeta(score)['key_changes'] = changed;
}

// ---------------------------------------------------------------- 2. time
int _fitCount(List<Measure> col, (int, int) ts) {
  final nominal = frac(ts.$1 * 4, ts.$2);
  return col.where((m) => m.events.isNotEmpty && m.actualLength() == nominal).length;
}

void voteTimeSignature(Score score, PostOptions options) {
  final columns = _measureColumns(score);
  if (columns.isEmpty) return;
  var changed = 0;
  if (options.timeSig != null) {
    final forced = options.timeSig!;
    for (final col in columns) {
      for (final m in col) {
        if (m.timeSig != forced) { m.warnings.add('time signature forced to ${forced.$1}/${forced.$2}'); m.timeSig = forced; changed++; }
      }
    }
    _noteMeta(score)['time_sig'] = [forced.$1, forced.$2];
    _noteMeta(score)['time_changes'] = changed;
    return;
  }
  final raw = <(int, int)>[];
  (int, int)? prev;
  for (final col in columns) {
    final vals = [for (final m in col) if (m.timeSig.$1 > 0 && m.timeSig.$2 > 0) m.timeSig];
    final v = majority(vals, prefer: prev) ?? prev ?? (4, 4);
    raw.add(v);
    prev = v;
  }
  final out = <(int, int)>[];
  for (var i = 0; i < raw.length; i++) {
    var ts = raw[i];
    final p = i > 0 ? out[i - 1] : null;
    final n = i + 1 < raw.length ? raw[i + 1] : null;
    if (p != null && n != null && ts != p && p == n) {
      if (_fitCount(columns[i], ts) < _fitCount(columns[i], p)) ts = p;
    }
    out.add(ts);
  }
  for (var i = 0; i < columns.length; i++) {
    final ts = out[i];
    for (final m in columns[i]) {
      if (m.timeSig != ts) {
        m.warnings.add('time signature ${m.timeSig.$1}/${m.timeSig.$2} -> ${ts.$1}/${ts.$2} (vote)');
        m.timeSig = ts; changed++;
      }
    }
  }
  _noteMeta(score)['time_changes'] = changed;
}

// ---------------------------------------------------------------- 2b. consensus
bool _isSequential(List<NoteEvent> events) {
  var pos = zeroFrac;
  for (final e in events) {
    if (e.onset != pos) return false;
    pos = e.end;
  }
  return true;
}

Frac _evidenceLength(Measure measure) {
  var best = zeroFrac;
  final nominal = measure.nominalLength();
  for (final v in measure.voices()) {
    final evs = [for (final e in _voiceEvents(measure, v)) if (!e.grace) e];
    if (evs.isEmpty) continue;
    final total = evs.fold(zeroFrac, (Frac s, e) => s + e.duration);
    final actual = evs.map((e) => e.end).reduce(Frac.max);
    final Frac length;
    if (_isSequential(evs)) {
      length = actual;
    } else if (total >= nominal) {
      length = total;
    } else {
      length = actual;
    }
    best = Frac.max(best, length);
  }
  return best;
}

(int, int)? _plausibleBarLength(Frac k) {
  if (k < frac(1) || k > frac(8)) return null;
  if (k.denominator == 1) return (k.numerator, 4);
  if (k.denominator == 2) return (k.numerator, 8);
  return null;
}

void consensusMeasureLengths(Score score, PostOptions options) {
  final columns = _measureColumns(score);
  if (columns.isEmpty) return;
  final minStaves = options.consensusMinStaves.clamp(1, score.staves.isEmpty ? 1 : score.staves.length);
  var changed = 0;
  (int, int)? override;
  (int, int)? prevPrinted;
  for (final col in columns) {
    final printed = col.isNotEmpty ? col.first.timeSig : (4, 4);
    if (prevPrinted != null && printed != prevPrinted) override = null;
    prevPrinted = printed;
    final nominalPrinted = frac(printed.$1 * 4, printed.$2);
    final lengths = [for (final m in col) if (m.events.any((e) => e.pitches.isNotEmpty)) _evidenceLength(m)];
    final agreed = lengths.isNotEmpty && lengths.every((k) => k == lengths.first) && lengths.length >= minStaves;
    if (agreed) {
      final k = lengths.first;
      if (k == nominalPrinted) {
        override = null;
      } else {
        final ts = _plausibleBarLength(k);
        override = ts != null && ts != printed ? ts : null;
      }
    } else if (override != null) {
      final overLen = frac(override.$1 * 4, override.$2);
      final support = lengths.where((k) => k == overLen).length;
      final oppose = lengths.where((k) => k == nominalPrinted).length;
      if (oppose > support) override = null;
    }
    if (override == null) continue;
    for (final m in col) {
      if (m.timeSig != override) {
        m.warnings.add('time signature ${m.timeSig.$1}/${m.timeSig.$2} -> ${override.$1}/${override.$2}'
          ' (measure-length consensus of ${lengths.length} staff/staves)');
        m.timeSig = override; changed++;
      }
    }
  }
  _noteMeta(score)['consensus_time_changes'] = changed;
}

// ---------------------------------------------------------------- 2c. rhythm repair
bool _isPow2(int n) => n > 0 && (n & (n - 1)) == 0;
bool _isStraight(Frac d) => _isPow2(d.denominator);
bool _isPlainValue(Frac d) => (d.numerator == 1 && _isPow2(d.denominator)) || (d.denominator == 1 && _isPow2(d.numerator));
bool _isTupletValued(Frac d) => d.denominator % 3 == 0;
bool _isQuintupletValued(Frac d) => d.denominator % 5 == 0;

class RhythmRepair {
  RhythmRepair({required this.durations, required this.cost, List<String>? changes, List<Frac>? tupletBeats})
      : changes = changes ?? [], tupletBeats = tupletBeats ?? [];
  final List<Frac> durations;
  final double cost;
  final List<String> changes;
  final List<Frac> tupletBeats;
}

const _costTriplet = 1.0, _costTripletUneven = 1.25, _costSextuplet = 1.0, _costQuintuplet = 1.5,
    _costDuplet = 1.0, _costSwing = 1.25, _costStraighten = 1.0, _costRetuple = 1.5,
    _costRetupleSwing = 1.75, _costDot = 1.5, _costDouble = 2.0;
const _tupletKinds = {'triplet', 'sextuplet', 'quintuplet', 'duplet', 'swing', 'retuple-swing'};

typedef _Move = (int length, List<Frac> durations, double cost, String kind, String label);

List<_Move> _candidateMoves(List<Frac> durs, int i, bool short, bool compound) {
  final n = durs.length;
  final d0 = durs[i];
  final moves = <_Move>[(1, [d0], 0.0, 'identity', '')];
  if (!short && _isStraight(d0)) {
    moves.add((1, [d0 * frac(2)], _costDouble, 'single', '$d0 doubled'));
    moves.add((1, [d0 / frac(2)], _costDouble, 'single', '$d0 halved'));
    if (_isPlainValue(d0)) {
      moves.add((1, [d0 * frac(3, 2)], _costDot, 'single', '$d0 dotted'));
    } else if (d0.numerator == 3) {
      moves.add((1, [d0 * frac(2, 3)], _costDot, 'single', 'dotted $d0 undotted'));
    }
  }
  for (final l in const [2, 3, 4, 5, 6]) {
    if (i + l > n) break;
    final run = durs.sublist(i, i + l);
    if (!run.every(_isStraight)) break;
    final equal = run.every((d) => d == run.first);
    final total = run.fold(zeroFrac, (Frac s, d) => s + d);
    if (l == 3 && equal && _isPlainValue(total * frac(2, 3))) {
      moves.add((l, [for (final d in run) d * frac(2, 3)], _costTriplet, 'triplet', '3 x ${run.first} as triplet'));
    }
    if (l == 2 && (run[0] == run[1] * frac(2) || run[1] == run[0] * frac(2)) && _isPlainValue(total * frac(2, 3))) {
      moves.add((l, [for (final d in run) d * frac(2, 3)], _costTripletUneven, 'triplet', 'pair ${run[0]},${run[1]} as triplet'));
    }
    if (l == 2 && equal) {
      final d = run.first;
      moves.add((l, [d * frac(4, 3), d * frac(2, 3)], _costSwing, 'swing', 'pair $d,$d as triplet'));
      if (compound) moves.add((l, [for (final x in run) x * frac(3, 2)], _costDuplet, 'duplet', 'pair $d,$d as duplet'));
    }
    if (l == 5 && equal) {
      moves.add((l, [for (final d in run) d * frac(4, 5)], _costQuintuplet, 'quintuplet', '5 x ${run.first} as quintuplet'));
    }
    if (l == 6 && equal && run.first <= frac(1, 4)) {
      moves.add((l, [for (final d in run) d * frac(2, 3)], _costSextuplet, 'sextuplet', '6 x ${run.first} as sextuplet'));
    }
  }
  if (short && _isTupletValued(d0) && (i == 0 || !_isTupletValued(durs[i - 1]))) {
    var j = i;
    while (j < n && _isTupletValued(durs[j])) { j++; }
    final run = durs.sublist(i, j);
    moves.add((j - i, [for (final d in run) d * frac(3, 2)], _costStraighten, 'straighten', '${j - i} tuplet event(s) straightened'));
  }
  if (_isQuintupletValued(d0) && (i == 0 || !_isQuintupletValued(durs[i - 1]))) {
    var j = i;
    while (j < n && _isQuintupletValued(durs[j])) { j++; }
    final run = durs.sublist(i, j);
    moves.add((j - i, [for (final d in run) d * frac(5, 4)], _costRetuple, 'retuple', '${j - i} quintuplet event(s) straightened'));
    moves.add((j - i, [for (final d in run) d * frac(5, 6)], _costRetuple, 'retuple', '${j - i} quintuplet event(s) as triplets'));
    if (j - i >= 2 && durs[i] == durs[i + 1]) {
      final d = durs[i];
      moves.add((2, [d * frac(5, 6), d * frac(5, 12)], _costRetupleSwing, 'retuple-swing', 'quintuplet pair $d,$d as triplet'));
    }
  }
  return moves;
}

typedef _Cost = (double, int, int, int, int, int);

int _cmpCost(_Cost a, _Cost b) {
  var c = a.$1.compareTo(b.$1); if (c != 0) return c;
  c = a.$2.compareTo(b.$2); if (c != 0) return c;
  c = a.$3.compareTo(b.$3); if (c != 0) return c;
  c = a.$4.compareTo(b.$4); if (c != 0) return c;
  c = a.$5.compareTo(b.$5); if (c != 0) return c;
  return a.$6.compareTo(b.$6);
}

class _DpEntry {
  _DpEntry(this.cost, this.prevI, this.prevKey, this.move);
  final _Cost cost;
  final int prevI;
  final (Frac, int)? prevKey;
  final (int, List<Frac>, String, String)? move;
}

RhythmRepair? repairVoiceDurations(List<Frac> durations, Frac nominal, {(int, int) timeSig = (4, 4),
    List<bool>? isChord, Iterable<Frac> hintBeats = const [], double maxCost = 6.0, int maxEvents = 24}) {
  final durs = [...durations];
  final n = durs.length;
  if (n == 0 || n > maxEvents) return null;
  final total = durs.fold(zeroFrac, (Frac s, d) => s + d);
  if (total == nominal) return RhythmRepair(durations: durs, cost: 0);
  final short = total < nominal;
  final compound = timeSig.$2 == 8 && timeSig.$1 % 3 == 0 && timeSig.$1 >= 6;
  final chords = isChord ?? List.filled(n, false);
  final hints = hintBeats.toSet();
  const _Cost zero = (0.0, 0, 0, 0, 0, 0);
  final dp = [for (var i = 0; i <= n; i++) <(Frac, int), _DpEntry>{}];
  dp[0][(zeroFrac, 0)] = _DpEntry(zero, -1, null, null);
  for (var i = 0; i < n; i++) {
    if (dp[i].isEmpty) continue;
    final moves = _candidateMoves(durs, i, short, compound);
    for (final entry in dp[i].entries.toList()) {
      final (s, used) = entry.key;
      final c = entry.value.cost;
      for (final (l, newDurs, cost, kind, label) in moves) {
        final s2 = s + newDurs.fold(zeroFrac, (Frac a, d) => a + d);
        if (s2 > nominal) continue;
        var used2 = used;
        _Cost c2;
        if (kind == 'identity') {
          c2 = c;
        } else {
          if (kind == 'single') {
            if (used != 0) continue;
            used2 = 1;
          }
          final c0 = c.$1 + cost;
          if (c0 > maxCost) continue;
          final isTuplet = _tupletKinds.contains(kind);
          final groupLen = newDurs.fold(zeroFrac, (Frac a, d) => a + d);
          final hintMiss = isTuplet && hints.isNotEmpty && !hints.contains(s) ? 1 : 0;
          final offGrid = isTuplet && groupLen > zeroFrac && (s / groupLen).denominator != 1 ? 1 : 0;
          var chordIn = 0;
          if (isTuplet) { for (var k = i; k < i + l; k++) { if (chords[k]) chordIn++; } }
          final unbeamed = durs.sublist(i, i + l).any((d) => d > frac(1, 2)) ? 1 : 0;
          c2 = (c0, c.$2 + 1, c.$3 + hintMiss, c.$4 + offGrid, c.$5 + chordIn, c.$6 + unbeamed);
        }
        final j = i + l;
        final key2 = (s2, used2);
        final cur = dp[j][key2];
        if (cur == null || _cmpCost(c2, cur.cost) < 0) {
          dp[j][key2] = _DpEntry(c2, i, (s, used), (l, newDurs, kind, label));
        }
      }
    }
  }
  final finals = [for (final k in [(nominal, 0), (nominal, 1)]) if (dp[n].containsKey(k)) dp[n][k]!];
  if (finals.isEmpty) return null;
  var best = finals.first;
  for (final f in finals) { if (_cmpCost(f.cost, best.cost) < 0) best = f; }
  final out = <Frac>[];
  final changes = <String>[];
  final beats = <Frac>[];
  var j = n;
  (Frac, int) key = (nominal, identical(best, dp[n][(nominal, 0)]) ? 0 : 1);
  while (j > 0) {
    final e = dp[j][key]!;
    final (_, newDurs, kind, label) = e.move!;
    out.insertAll(0, newDurs);
    if (kind != 'identity') {
      changes.insert(0, '$label at ${e.prevKey!.$1}');
      if (_tupletKinds.contains(kind)) beats.insert(0, e.prevKey!.$1);
    }
    j = e.prevI;
    key = e.prevKey!;
  }
  return RhythmRepair(durations: out, cost: best.cost.$1, changes: changes, tupletBeats: beats);
}

void _sequentialize(List<NoteEvent> events) {
  var pos = zeroFrac;
  for (final e in events) { e.onset = pos; pos = e.end; }
}

bool _hasOverflowGaps(List<NoteEvent> events, Frac nominal) {
  if (events.isEmpty || events.first.onset != zeroFrac) return false;
  if (!events.every((e) => e.duration > zeroFrac)) return false;
  if (!(events.last.end > nominal)) return false;
  for (var i = 0; i + 1 < events.length; i++) { if (events[i].end > events[i + 1].onset) return false; }
  for (var i = 0; i + 1 < events.length; i++) {
    final a = events[i], b = events[i + 1];
    if (a.end < b.onset && !a.isRest && !b.isRest && _isStraight(a.duration) == _isStraight(b.duration) &&
        _isStraight(b.onset - a.end) != _isStraight(a.duration)) {
      return true;
    }
  }
  return false;
}

RhythmRepair? _voicePlan(Measure measure, int voice, Frac nominal, PostOptions options, [Iterable<Frac> hintBeats = const []]) {
  final main = [for (final e in _voiceEvents(measure, voice)) if (!e.grace) e];
  if (main.isEmpty || main.every((e) => e.isRest)) return null;
  final total = main.fold(zeroFrac, (Frac s, e) => s + e.duration);
  final sequential = _isSequential(main);
  if (sequential && total == nominal) return null;
  final overflowGaps = _hasOverflowGaps(main, nominal);
  if (total < nominal && !sequential && !overflowGaps) return null;
  final plan = repairVoiceDurations([for (final e in main) e.duration], nominal, timeSig: measure.timeSig,
    isChord: [for (final e in main) e.pitches.length > 1], hintBeats: hintBeats,
    maxCost: options.repairMaxCost, maxEvents: options.repairMaxEvents);
  if (plan == null && overflowGaps) return RhythmRepair(durations: [for (final e in main) e.duration], cost: 0);
  return plan;
}

String? _applyPlan(Measure measure, int voice, RhythmRepair plan) {
  final events = _voiceEvents(measure, voice);
  final main = [for (final e in events) if (!e.grace) e];
  final before = main.map((e) => e.end).reduce(Frac.max);
  final gapped = !_isSequential(main);
  final graces = [for (final e in events) if (e.grace) e];
  final follower = <NoteEvent, int?>{};
  for (final g in graces) {
    int? k;
    for (var i = 0; i < main.length; i++) { if (main[i].onset >= g.onset) { k = i; break; } }
    follower[g] = k;
  }
  for (var i = 0; i < main.length && i < plan.durations.length; i++) { main[i].duration = plan.durations[i]; }
  _sequentialize(main);
  for (final g in graces) {
    final k = follower[g];
    g.onset = k != null ? main[k].onset : main.last.end;
  }
  final parts = <String>[];
  if (plan.changes.isNotEmpty) parts.add(plan.changes.join('; '));
  if (gapped) parts.add('onsets recomputed from durations');
  if (parts.isEmpty) return null;
  return 'voice $voice: rhythm repair (${parts.join(', ')}; $before -> ${main.map((e) => e.end).reduce(Frac.max)} quarters)';
}

void repairRhythm(Score score, PostOptions options) {
  var nRepairs = 0, nReseq = 0;
  List<RhythmRepair> doMeasure(Measure m, [Map<int, List<Frac>>? hints]) {
    final plans = <RhythmRepair>[];
    final nominal = m.nominalLength();
    if (nominal <= zeroFrac || m.events.isEmpty) return plans;
    for (final voice in m.voices()) {
      final plan = _voicePlan(m, voice, nominal, options, hints?[voice] ?? const []);
      if (plan == null) continue;
      final msg = _applyPlan(m, voice, plan);
      if (msg != null) {
        m.warnings.add(msg);
        if (plan.changes.isNotEmpty) { nRepairs++; } else { nReseq++; }
      }
      plans.add(plan);
    }
    return plans;
  }
  List<Frac> beatsOf(Iterable<RhythmRepair> plans) {
    final set = {for (final p in plans) ...p.tupletBeats}.toList()..sort();
    return set;
  }
  final rhs = score.staves.where((s) => s.role == pianoRh).toList();
  final lhs = score.staves.where((s) => s.role == pianoLh).toList();
  final pairs = [for (var i = 0; i < rhs.length && i < lhs.length; i++) (rhs[i], lhs[i])];
  final paired = {for (final (a, b) in pairs) ...[a, b]};
  for (final staff in score.staves) {
    if (paired.contains(staff)) continue;
    for (final m in staff.measures) { doMeasure(m); }
  }
  for (final (rh, lh) in pairs) {
    for (var i = 0; i < rh.measures.length && i < lh.measures.length; i++) {
      final mr = rh.measures[i], ml = lh.measures[i];
      final br = beatsOf([for (final v in mr.voices()) _voicePlan(mr, v, mr.nominalLength(), options)].whereType<RhythmRepair>());
      final bl = beatsOf([for (final v in ml.voices()) _voicePlan(ml, v, ml.nominalLength(), options)].whereType<RhythmRepair>());
      final hintR = bl.isNotEmpty && br.isEmpty ? {for (final v in mr.voices()) v: bl} : null;
      final hintL = br.isNotEmpty ? {for (final v in ml.voices()) v: br} : null;
      doMeasure(mr, hintR);
      doMeasure(ml, hintL);
    }
    for (final m in [...rh.measures.skip(lh.measures.length), ...lh.measures.skip(rh.measures.length)]) { doMeasure(m); }
  }
  final meta = _noteMeta(score);
  meta['rhythm_repairs'] = nRepairs;
  meta['rhythm_resequenced'] = nReseq;
}

// ---------------------------------------------------------------- 3. lengths
List<String> _normalizeVoice(Measure measure, int voice, Frac nominal, Frac tolerance) {
  final fixes = <String>[];
  final events = _voiceEvents(measure, voice);
  var main = [for (final e in events) if (!e.grace) e];
  final graces = [for (final e in events) if (e.grace) e];
  final keep = [...events];
  for (final g in graces) {
    if (g.onset > nominal) g.onset = nominal;
    if (g.onset < zeroFrac) g.onset = zeroFrac;
  }
  Frac maxEnd(List<NoteEvent> list) => list.isEmpty ? zeroFrac : list.map((e) => e.end).reduce(Frac.max);
  var actual = maxEnd(main);
  if (actual > nominal) {
    final excess = actual - nominal;
    if (excess <= tolerance) {
      for (final e in main) {
        if (e.end > nominal) {
          final newDur = nominal - e.onset;
          if (newDur > zeroFrac) { e.duration = newDur; } else { keep.remove(e); }
        }
      }
      fixes.add('voice $voice: clipped $excess quarter(s) beyond bar end');
    } else if (actual / frac(2) == nominal) {
      for (final e in main) { e.onset = e.onset / frac(2); e.duration = e.duration / frac(2); }
      for (final g in graces) { g.onset = g.onset / frac(2); }
      fixes.add('voice $voice: halved all durations ($actual -> $nominal)');
    } else {
      for (final e in main) {
        if (e.onset >= nominal) {
          keep.remove(e);
        } else if (e.end > nominal) {
          e.duration = nominal - e.onset;
        }
      }
      fixes.add('voice $voice: truncated at bar end ($actual > $nominal)');
    }
    main = [for (final e in keep) if (!e.grace) e];
    actual = maxEnd(main);
  }
  for (final e in main) { if (e.end > nominal) e.duration = nominal - e.onset; }
  main = [for (final e in main) if (e.duration > zeroFrac) e];
  actual = maxEnd(main);
  if (actual < nominal) {
    keep.add(NoteEvent(onset: actual, duration: nominal - actual, voice: voice, source: 'postprocess:pad'));
    fixes.add(main.isNotEmpty ? 'voice $voice: padded ${nominal - actual} quarter(s) of rest'
        : 'voice $voice: no sounding events, filled with rest');
  }
  final others = [for (final e in measure.events) if (e.voice != voice) e];
  final kept = [for (final e in keep) if (e.grace || e.duration > zeroFrac) e];
  measure.events = [...others, ...kept];
  return fixes;
}

void normalizeMeasureLengths(Score score, PostOptions options) {
  var nFixes = 0;
  for (final staff in score.staves) {
    for (final m in staff.measures) {
      if (m.events.isEmpty) continue;
      var nominal = m.nominalLength();
      if (nominal <= zeroFrac) {
        m.warnings.add('invalid time signature ${m.timeSig}, using 4/4');
        m.timeSig = (4, 4);
        nominal = m.nominalLength();
      }
      for (final voice in m.voices()) {
        final fixes = _normalizeVoice(m, voice, nominal, options.tolerance);
        m.warnings.addAll(fixes);
        nFixes += fixes.length;
      }
      stableSort(m.events, (a, b) {
        var c = a.voice.compareTo(b.voice); if (c != 0) return c;
        c = a.onset.compareTo(b.onset); if (c != 0) return c;
        return (a.grace ? 0 : 1).compareTo(b.grace ? 0 : 1);
      });
    }
  }
  _noteMeta(score)['length_fixes'] = nFixes;
}

// ---------------------------------------------------------------- 4. octave
void applyOctaveShift(Score score, [PostOptions? options]) {
  final meta = _noteMeta(score);
  final applied = Map<String, dynamic>.from((meta['octave_shift_applied'] as Map?) ?? const {});
  for (final staff in score.staves) {
    final shift = staff.octaveShift;
    if (shift == 0 || applied[staff.id] == shift) continue;
    final semis = 12 * shift;
    var count = 0;
    for (final m in staff.measures) {
      for (final e in m.events) {
        if (e.pitches.isNotEmpty) {
          e.pitches = [for (final p in e.pitches) (p + semis).clamp(0, 127)];
          count += e.pitches.length;
        }
      }
      if (shift == -1 && m.clef == 'G') m.clef = 'G8vb';
    }
    if (shift == -1 && (staff.clef == 'G' || staff.clef.isEmpty)) staff.clef = 'G8vb';
    applied[staff.id] = shift;
    score.warnings.add('${staff.name.isNotEmpty ? staff.name : staff.id}: 実音として${shift > 0 ? '+' : ''}$shiftオクターブ移しました（$count音）');
  }
  meta['octave_shift_applied'] = applied;
}

// ---------------------------------------------------------------- 5. ties
List<(Measure, NoteEvent)> _staffVoiceSequence(Staff staff, int voice) => [
  for (final m in staff.measures) for (final e in _voiceEvents(m, voice)) if (!e.grace) (m, e),
];

bool _lastInVoice(Measure m, NoteEvent e) => !m.events.any((o) =>
    !identical(o, e) && o.voice == e.voice && !o.grace && !o.isRest && o.onset > e.onset);

Set<NoteEvent> _crossVoiceBarlineTies(Staff staff) {
  final keep = <NoteEvent>{};
  for (var mi = 1; mi < staff.measures.length; mi++) {
    final prev = staff.measures[mi - 1], cur = staff.measures[mi];
    final heads = [for (final f in cur.events) if (f.onset == zeroFrac && !f.isRest && !f.grace) f];
    final tails = [for (final e in prev.events) if (!e.isRest && !e.grace && _lastInVoice(prev, e)) e];
    for (final e in tails) {
      for (final f in heads) {
        if (f.voice == e.voice || !e.pitches.any(f.pitches.contains)) continue;
        if (e.tieStart || f.tieStop) {
          e.tieStart = true; f.tieStop = true;
          keep..add(e)..add(f);
          break;
        }
      }
    }
  }
  return keep;
}

void mergeTies(Score score, [PostOptions? options]) {
  var fixed = 0;
  for (final staff in score.staves) {
    final keep = _crossVoiceBarlineTies(staff);
    final voices = {for (final m in staff.measures) for (final e in m.events) e.voice}.toList()..sort();
    for (final voice in voices) {
      final seq = _staffVoiceSequence(staff, voice);
      for (var i = 0; i < seq.length; i++) {
        final (m, e) = seq[i];
        final nxt = i + 1 < seq.length ? seq[i + 1] : null;
        if (e.tieStart) {
          if (e.isRest) { e.tieStart = false; continue; }
          if (nxt == null || nxt.$2.isRest || !e.pitches.any(nxt.$2.pitches.contains)) {
            if (!keep.contains(e)) { e.tieStart = false; m.warnings.add('voice $voice: dangling tie start at ${e.onset} removed'); fixed++; }
          } else if (!nxt.$2.tieStop) {
            nxt.$2.tieStop = true; fixed++;
          }
        }
        if (e.tieStop) {
          final prv = i > 0 ? seq[i - 1] : null;
          if (e.isRest) { e.tieStop = false; continue; }
          if (prv == null || prv.$2.isRest || !e.pitches.any(prv.$2.pitches.contains)) {
            if (!keep.contains(e)) { e.tieStop = false; m.warnings.add('voice $voice: dangling tie stop at ${e.onset} removed'); fixed++; }
          } else if (!prv.$2.tieStart) {
            prv.$2.tieStart = true; fixed++;
          }
        }
      }
    }
  }
  _noteMeta(score)['tie_fixes'] = fixed;
}

// ---------------------------------------------------------------- 6. ranges
double _outsideFraction(List<int> pitches, (int, int) rng) {
  if (pitches.isEmpty) return 0;
  return pitches.where((p) => p < rng.$1 || p > rng.$2).length / pitches.length;
}

void clampVoiceRanges(Score score, PostOptions options) {
  final shifted = <String, int>{};
  for (final staff in score.staves) {
    if (staff.role != voiceRole) continue;
    final rng = options.rangeFor(staff.voiceType);
    if (rng == null) continue;
    final pitches = [for (final m in staff.measures) for (final e in m.notes()) ...e.pitches];
    if (pitches.isEmpty) continue;
    final outside = _outsideFraction(pitches, rng);
    if (outside <= options.clampOutsideFraction) continue;
    var bestShift = 0;
    var bestInside = 1.0 - outside;
    for (final shift in const [-12, 12]) {
      final inside = 1.0 - _outsideFraction([for (final p in pitches) p + shift], rng);
      if (inside > bestInside) { bestInside = inside; bestShift = shift; }
    }
    final label = staff.name.isNotEmpty ? staff.name : staff.id;
    if (bestShift != 0 && bestInside > options.clampFixedFraction) {
      for (final m in staff.measures) {
        for (final e in m.events) { if (e.pitches.isNotEmpty) e.pitches = [for (final p in e.pitches) (p + bestShift).clamp(0, 127)]; }
      }
      shifted[staff.id] = bestShift ~/ 12;
      score.warnings.add('$label: 音域外の音が${(outside * 100).round()}%あるため、全体を${bestShift ~/ 12}オクターブ移しました');
    } else {
      score.warnings.add('$label: 音域外の音が${(outside * 100).round()}%あります。原譜を確認してください');
    }
  }
  _noteMeta(score)['range_shifts'] = shifted;
}

// ---------------------------------------------------------------- 7. empty
void fillEmptyMeasures(Score score, [PostOptions? options]) {
  var filled = 0;
  for (final staff in score.staves) {
    for (final m in staff.measures) {
      if (m.events.isNotEmpty) continue;
      if (m.nominalLength() <= zeroFrac) m.timeSig = (4, 4);
      m.events.add(NoteEvent(onset: zeroFrac, duration: m.nominalLength(), source: 'postprocess:empty'));
      m.warnings.add('empty measure filled with a whole rest');
      filled++;
    }
  }
  _noteMeta(score)['empty_filled'] = filled;
}

/// Apply every step in order (in place) and return [score].
Score postprocessScore(Score score, [PostOptions? options]) {
  final o = options ?? PostOptions();
  final steps = <(bool, String, void Function(Score, PostOptions))>[
    (o.doVoteKey, 'vote_key_signature', voteKeySignature),
    (o.doVoteTime, 'vote_time_signature', voteTimeSignature),
    (o.doConsensusLengths, 'consensus_measure_lengths', consensusMeasureLengths),
    (o.doRhythmRepair, 'repair_rhythm', repairRhythm),
    (o.doNormalizeLengths, 'normalize_measure_lengths', normalizeMeasureLengths),
    (o.doOctaveShift, 'apply_octave_shift', applyOctaveShift),
    (o.doMergeTies, 'merge_ties', mergeTies),
    (o.doClampRanges, 'clamp_voice_ranges', clampVoiceRanges),
    (o.doFillEmpty, 'fill_empty_measures', fillEmptyMeasures),
  ];
  for (final (enabled, _, step) in steps) { if (enabled) step(score, o); }
  final problems = [for (final p in score.validate()) if (p.contains('ends at')) p];
  score.warnings.addAll(problems);
  _noteMeta(score)['steps'] = [for (final (enabled, name, _) in steps) if (enabled) name];
  return score;
}
