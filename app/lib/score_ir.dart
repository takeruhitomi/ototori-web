/// Typed score model mirroring the PC pipeline's IR (`choir_omr/model.py`).
///
/// Structure inference and post-processing are ports of the PC/browser
/// back end and operate on these classes. [Score.toJson] produces the same
/// `score.json` layout as the PC `Score.to_dict()`.
library;

import 'omr_symbols.dart';

typedef Frac = BeatFraction;

const voiceRole = 'voice';
const pianoRh = 'piano_rh';
const pianoLh = 'piano_lh';
const unknownRole = 'unknown';
const gmChoirAahs = 52;
const gmAcousticGrand = 0;

Frac frac(int n, [int d = 1]) => BeatFraction(n, d);
final Frac zeroFrac = BeatFraction.zero;

class NoteEvent {
  NoteEvent({required this.onset, required this.duration, List<int>? pitches, this.voice = 0,
    this.tieStart = false, this.tieStop = false, this.grace = false, this.source = '',
    List<String>? slurStarts, List<String>? slurStops, this.inferredRest = false, this.place})
      : pitches = pitches ?? <int>[], slurStarts = slurStarts ?? <String>[], slurStops = slurStops ?? <String>[];
  Frac onset;
  Frac duration;
  List<int> pitches;
  int voice;
  bool tieStart, tieStop, grace;
  String source;
  List<String> slurStarts, slurStops;
  /// Synthetic rest (missing staff / piano-only system); Dart-only field.
  bool inferredRest;
  /// Position on the source page (Android, Dart-only): `{x, heads: [{pitch,
  /// x, y, confidence, snapped}]}` for notes, `{x, confidence, snapped}` for
  /// rests; page pixels of the measure's `page` (1920 wide).
  Map<String, dynamic>? place;

  bool get isRest => pitches.isEmpty;
  Frac get end => onset + duration;

  NoteEvent copy() => NoteEvent(onset: onset, duration: duration, pitches: [...pitches], voice: voice,
    tieStart: tieStart, tieStop: tieStop, grace: grace, source: source,
    slurStarts: [...slurStarts], slurStops: [...slurStops], inferredRest: inferredRest, place: place);

  Map<String, dynamic> toJson() => {
    'onset': onset.toString(), 'duration': duration.toString(), 'pitches': [...pitches], 'voice': voice,
    'tie_start': tieStart, 'tie_stop': tieStop, 'grace': grace, 'velocity': null, 'source': source,
    'slur_starts': [...slurStarts], 'slur_stops': [...slurStops], 'grace_index': null, 'grace_count': null,
    if (inferredRest) 'inferred_rest': true,
    if (place != null) 'place': place,
  };

  factory NoteEvent.fromJson(Map<dynamic, dynamic> d) => NoteEvent(
    onset: BeatFraction.parse(d['onset']), duration: BeatFraction.parse(d['duration']),
    pitches: [for (final p in d['pitches'] as List? ?? const []) p as int], voice: (d['voice'] as int?) ?? 0,
    tieStart: d['tie_start'] == true, tieStop: d['tie_stop'] == true, grace: d['grace'] == true,
    source: (d['source'] as String?) ?? '',
    slurStarts: [for (final s in d['slur_starts'] as List? ?? const []) '$s'],
    slurStops: [for (final s in d['slur_stops'] as List? ?? const []) '$s'],
    inferredRest: d['inferred_rest'] == true,
    place: (d['place'] as Map?)?.cast<String, dynamic>());
}

class Measure {
  Measure({required this.number, List<NoteEvent>? events, this.timeSig = const (4, 4), this.keyFifths = 0,
    this.clef = '', this.page, this.system, List<String>? warnings, this.repeatStart = false,
    this.repeatEnd = 0, List<int>? endingNumbers, this.bounds})
      : events = events ?? <NoteEvent>[], warnings = warnings ?? <String>[],
        endingNumbers = endingNumbers ?? <int>[];
  int number;
  List<NoteEvent> events;
  (int, int) timeSig;
  int keyFifths;
  String clef;
  int? page, system;
  List<String> warnings;
  bool repeatStart;
  int repeatEnd;
  List<int> endingNumbers;
  /// Position on the source page (Android, Dart-only): left/right barline x
  /// (`x0`/`x1`), the five staff line heights there (`lines0`/`lines1`, top
  /// to bottom) and how sure each end is (`confidence0/1`, `snapped0/1`).
  /// The right end is missing when the bar has no closing barline.
  Map<String, dynamic>? bounds;

  Frac nominalLength() => BeatFraction(timeSig.$1 * 4, timeSig.$2);
  Frac actualLength() {
    var best = zeroFrac;
    var any = false;
    for (final e in events) {
      if (e.grace) continue;
      if (!any || e.end > best) best = e.end;
      any = true;
    }
    return any ? best : zeroFrac;
  }
  List<int> voices() => ({for (final e in events) e.voice}.toList()..sort());
  Iterable<NoteEvent> notes() => events.where((e) => e.pitches.isNotEmpty);

  Map<String, dynamic> toJson() => {
    'number': number, 'events': [for (final e in events) e.toJson()],
    'time_sig': [timeSig.$1, timeSig.$2], 'key_fifths': keyFifths, 'clef': clef,
    'page': page, 'system': system, 'warnings': [...warnings], 'repeat_start': repeatStart,
    'repeat_end': repeatEnd, 'ending_numbers': [...endingNumbers], 'navigation': <String>[],
    if (bounds != null) 'bounds': bounds,
  };

  factory Measure.fromJson(Map<dynamic, dynamic> d) {
    final ts = (d['time_sig'] as List?)?.cast<int>() ?? const [4, 4];
    return Measure(number: (d['number'] as int?) ?? 0,
      events: [for (final e in d['events'] as List? ?? const []) NoteEvent.fromJson(e as Map)],
      timeSig: (ts[0], ts[1]), keyFifths: (d['key_fifths'] as int?) ?? 0, clef: (d['clef'] as String?) ?? '',
      page: d['page'] as int?, system: d['system'] as int?,
      warnings: [for (final w in d['warnings'] as List? ?? const []) '$w'],
      repeatStart: d['repeat_start'] == true, repeatEnd: (d['repeat_end'] as int?) ?? 0,
      endingNumbers: [for (final n in d['ending_numbers'] as List? ?? const []) n as int],
      bounds: (d['bounds'] as Map?)?.cast<String, dynamic>());
  }
}

class Staff {
  Staff({required this.id, this.role = unknownRole, this.name = '', List<Measure>? measures, this.clef = '',
    this.midiProgram = gmChoirAahs, this.octaveShift = 0, this.voiceType = '', List<String>? warnings})
      : measures = measures ?? <Measure>[], warnings = warnings ?? <String>[];
  String id, role, name, clef, voiceType;
  List<Measure> measures;
  int midiProgram, octaveShift;
  /// A part printed only in some systems (a solo added mid-piece); it rests
  /// elsewhere. Written to JSON only when true.
  bool added = false;
  /// Conversion warnings of this staff (not part of the PC JSON staff object).
  List<String> warnings;

  Map<String, dynamic> toJson() => {
    'id': id, 'role': role, 'name': name, 'clef': clef, 'midi_program': midiProgram,
    'octave_shift': octaveShift, 'voice_type': voiceType, if (added) 'added': true,
    'measures': [for (final m in measures) m.toJson()],
  };

  factory Staff.fromJson(Map<dynamic, dynamic> d) => Staff(id: '${d['id']}', role: (d['role'] as String?) ?? unknownRole,
    name: (d['name'] as String?) ?? '', clef: (d['clef'] as String?) ?? '',
    midiProgram: (d['midi_program'] as int?) ?? gmChoirAahs, octaveShift: (d['octave_shift'] as int?) ?? 0,
    voiceType: (d['voice_type'] as String?) ?? '',
    measures: [for (final m in d['measures'] as List? ?? const []) Measure.fromJson(m as Map)],
    warnings: [for (final w in d['warnings'] as List? ?? const []) '$w'])..added = d['added'] == true;
}

class Score {
  Score({List<Staff>? staves, this.tempoBpm = 80, this.title = '', List<String>? warnings, Map<String, dynamic>? meta})
      : staves = staves ?? <Staff>[], warnings = warnings ?? <String>[], meta = meta ?? <String, dynamic>{};
  List<Staff> staves;
  double tempoBpm;
  String title;
  List<String> warnings;
  Map<String, dynamic> meta;

  int measureCount() => staves.fold(0, (n, s) => s.measures.length > n ? s.measures.length : n);

  /// Problems (empty = consistent), as the PC `Score.validate()`.
  List<String> validate() {
    final problems = <String>[];
    final counts = {for (final s in staves) s.id: s.measures.length};
    if (counts.values.toSet().length > 1) problems.add('staves have different measure counts: $counts');
    for (final s in staves) {
      for (final m in s.measures) {
        for (final e in m.events) {
          if (e.duration <= zeroFrac && !e.grace) problems.add('${s.id} m${m.number}: non-positive duration');
          if (e.onset < zeroFrac) problems.add('${s.id} m${m.number}: negative onset');
          if (e.end > m.nominalLength() && !e.grace) {
            problems.add('${s.id} m${m.number}: event ends at ${e.end} > nominal ${m.nominalLength()}');
          }
        }
      }
    }
    return problems;
  }

  Map<String, dynamic> toJson() => {
    'tempo_bpm': tempoBpm, 'title': title, 'warnings': [...warnings], 'meta': meta,
    'staves': [for (final s in staves) s.toJson()],
  };

  factory Score.fromJson(Map<dynamic, dynamic> d) => Score(
    staves: [for (final s in d['staves'] as List? ?? const []) Staff.fromJson(s as Map)],
    tempoBpm: ((d['tempo_bpm'] as num?) ?? 80).toDouble(), title: (d['title'] as String?) ?? '',
    warnings: [for (final w in d['warnings'] as List? ?? const []) '$w'],
    meta: Map<String, dynamic>.from((d['meta'] as Map?) ?? const {}));
}

String midiToName(int midi) {
  const names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];
  return '${names[midi % 12]}${midi ~/ 12 - 1}';
}

/// Most common value; ties go to [prefer] when it is among the winners, else
/// to the first value seen (Python `Counter` insertion order).
T? majority<T>(Iterable<T> values, {T? prefer}) {
  final counts = <T, int>{};
  for (final v in values) { counts[v] = (counts[v] ?? 0) + 1; }
  if (counts.isEmpty) return null;
  final best = counts.values.reduce((a, b) => a > b ? a : b);
  final winners = [for (final e in counts.entries) if (e.value == best) e.key];
  if (prefer != null && winners.contains(prefer)) return prefer;
  return winners.first;
}
