/// Staff-role inference, unit merging and part naming.
///
/// Port of the PC/browser back end `choir_omr/structure.py` (SPEC §7) so that
/// Android assembles recognised systems exactly like the browser version.
/// Nothing here changes pitches: the tenor octave rule only flags staves
/// ([Staff.octaveShift] = -1); [applyOctaveShift] in the post-processor
/// applies it.
library;

import 'score_ir.dart';

const ensembleVoiceNames = <String, List<String>>{
  'TTBB': ['Tenor I', 'Tenor II', 'Baritone', 'Bass'],
  'TBB': ['Tenor', 'Baritone', 'Bass'],
  'SATB': ['Soprano', 'Alto', 'Tenor', 'Bass'],
  'SAB': ['Soprano', 'Alto', 'Baritone'],
  'SSA': ['Soprano I', 'Soprano II', 'Alto'],
  'SSAA': ['Soprano I', 'Soprano II', 'Alto I', 'Alto II'],
  'SSATBB': ['Soprano I', 'Soprano II', 'Alto', 'Tenor', 'Bass I', 'Bass II'],
  'SSAATTBB': ['Soprano I', 'Soprano II', 'Alto I', 'Alto II', 'Tenor I', 'Tenor II', 'Bass I', 'Bass II'],
  'TB': ['Tenor', 'Bass'],
  'SB': ['Soprano', 'Bass'],
  'SA': ['Soprano', 'Alto'],
};

const _voiceTypePrefixes = <(String, String)>[
  ('ソプラノ', 'soprano'), ('アルト', 'alto'), ('テノール', 'tenor'), ('テナー', 'tenor'),
  ('バリトン', 'baritone'), ('バス', 'bass'), ('mezzo', 'alto'), ('sop', 'soprano'), ('alt', 'alto'),
  ('ten', 'tenor'), ('bar', 'baritone'), ('bas', 'bass'), ('cantus', 'soprano'), ('contralto', 'alto'),
];

/// User hints about the ensemble (PC `Layout`).
class EnsembleLayout {
  EnsembleLayout({String ensemble = 'auto', List<String>? voiceNames, this.piano})
      : ensemble = _normEnsemble(ensemble),
        voiceNames = (voiceNames == null || voiceNames.every((n) => n.trim().isEmpty))
            ? null : [for (final n in voiceNames) if (n.trim().isNotEmpty) n.trim()];
  final String ensemble;
  final List<String>? voiceNames;
  /// `true`: last two staves are piano; `false`: no piano; `null`: auto.
  final bool? piano;

  static String _normEnsemble(String e) {
    final t = e.trim();
    if (t.isEmpty) return 'auto';
    final lower = t.toLowerCase();
    return lower == 'auto' || lower == 'custom' ? lower : t.toUpperCase();
  }

  int? get fixedVoiceCount => voiceNames != null ? voiceNames!.length
      : ensembleVoiceNames.containsKey(ensemble) ? ensembleVoiceNames[ensemble]!.length : null;
}

class PageSplit {
  PageSplit({required this.voices, List<Staff>? piano, List<String>? warnings})
      : piano = piano ?? <Staff>[], warnings = warnings ?? <String>[];
  List<Staff> voices;
  List<Staff> piano;
  List<String> warnings;
}

/// One recognition unit: a page or one system of a page.
class Unit {
  Unit(List<Staff> staves, {this.page, this.system, this.pianoOnly, String label = '', this.pianoPair,
    this.pianoExtra, this.imageLayout = false})
      : staves = [...staves], label = label.isNotEmpty ? label
            : page != null && system != null ? '$pageページ${system + 1}段目'
            : page != null ? '$pageページ' : '' {
    if (page != null) { for (final st in this.staves) { for (final m in st.measures) { m.page = page; } } }
    if (system != null) { for (final st in this.staves) { for (final m in st.measures) { m.system = system; } } }
  }
  final List<Staff> staves;
  final int? page, system;
  /// From the image: the system is exactly a braced piano pair.
  final bool? pianoOnly;
  /// Indices of the two braced staves in the image.
  final (int, int)? pianoPair;
  /// Index of the top staff of a three-staff piano (brace over three staves);
  /// merged into the right hand, as homr's grand-staff reading does.
  final int? pianoExtra;
  final String label;
  /// The system grouping and braces come from the page image analysis.
  final bool imageLayout;
}

String _baseClef(String clef) => clef.isEmpty ? '' : clef.substring(0, 1).toUpperCase();

String staffClef(Staff staff) {
  if (staff.clef.isNotEmpty) return staff.clef;
  return majority([for (final m in staff.measures) if (m.clef.isNotEmpty) m.clef]) ?? '';
}

String voiceTypeFor(String name) {
  final n = name.trim().toLowerCase();
  if (n.isEmpty) return '';
  for (final (prefix, type) in _voiceTypePrefixes) { if (n.startsWith(prefix)) return type; }
  return '';
}

String detectEnsemble(List<String> clefs) {
  final bases = [for (final c in clefs) _baseClef(c)];
  if (bases.any((b) => b != 'G' && b != 'F')) return 'custom';
  final g = bases.where((b) => b == 'G').length, f = bases.where((b) => b == 'F').length;
  const table = {
    (2, 2): 'TTBB', (3, 1): 'SATB', (2, 1): 'SAB', (3, 0): 'SSA', (4, 0): 'SSAA', (1, 1): 'SB',
    (2, 0): 'SA', (0, 2): 'TB', (0, 3): 'TBB', (1, 2): 'TBB',
  };
  return table[(g, f)] ?? 'custom';
}

List<String> voiceNamesFor(String ensemble, int n) {
  final names = [...?ensembleVoiceNames[ensemble]];
  if (names.length > n) names.removeRange(n, names.length);
  while (names.length < n) { names.add('Voice ${names.length + 1}'); }
  return names;
}

PageSplit splitPage(List<Staff> input, EnsembleLayout layout, {String pageLabel = '', bool? pianoOnly,
    (int, int)? pianoPair, int? pianoExtra}) {
  final staves = [...input];
  final warnings = <String>[];
  final label = pageLabel.isNotEmpty ? '（$pageLabel）' : '';
  final declaredRh = staves.where((s) => s.role == pianoRh).toList();
  final declaredLh = staves.where((s) => s.role == pianoLh).toList();
  final declared = staves.where((s) => s.role == pianoRh || s.role == pianoLh).toList();

  if (layout.piano == false) {
    if (declared.isNotEmpty) warnings.add('ピアノなしの指定のため、ピアノと判定された${declared.length}段を声部として扱いました$label');
    return PageSplit(voices: staves, warnings: warnings);
  }
  var piano = <Staff>[];
  if (pianoOnly == true && staves.length == 2) {
    staves[0].role = pianoRh; staves[1].role = pianoLh;
    return PageSplit(voices: [], piano: [staves[0], staves[1]], warnings: warnings);
  }
  if (pianoPair != null) {
    final (i, j) = pianoPair;
    if (0 <= i && i < j && j < staves.length && j == i + 1) {
      final rh = staves[i], lh = staves[j];
      final clefs = [_baseClef(staffClef(rh)), _baseClef(staffClef(lh))];
      if (clefs[0] == 'G' && clefs[1] == 'G') warnings.add('ブレースで結ばれた${i + 1}・${j + 1}段目がどちらもト音記号ですが、ピアノとして扱いました$label');
      for (final s in staves) { if (s.role == pianoRh || s.role == pianoLh) s.role = unknownRole; }
      rh.role = pianoRh; lh.role = pianoLh;
      final excluded = {i, j};
      if (pianoExtra != null && pianoExtra == i - 1) {
        // Three-staff piano: the staff above the grand staff joins the RH.
        mergeStaffEvents(rh, staves[pianoExtra]);
        excluded.add(pianoExtra);
        warnings.add('3段のピアノ譜$label: 最上段を右手に統合しました');
      }
      final voices = [for (var k = 0; k < staves.length; k++) if (!excluded.contains(k)) staves[k]];
      return PageSplit(voices: voices, piano: [rh, lh], warnings: warnings);
    }
    warnings.add('画像のピアノ段の対応を無視しました$label');
  }
  if (declaredRh.isNotEmpty && declaredLh.isNotEmpty) {
    final (rh, lh) = _bottomPair(staves, declaredRh, declaredLh);
    piano = [rh, lh];
  }
  if (piano.isEmpty) {
    final minStaves = layout.piano == true ? 2 : 3;
    if (staves.length >= minStaves) {
      final lastTwo = staves.sublist(staves.length - 2);
      final clefs = [for (final s in lastTwo) _baseClef(staffClef(s))];
      if (clefs[0] == 'G' && clefs[1] == 'F') {
        piano = lastTwo;
      } else if (layout.piano == true) {
        piano = lastTwo;
        warnings.add('ピアノありの指定ですが、最後の2段の音部記号は$clefsです$label');
      }
    } else if (layout.piano == true) {
      warnings.add('ピアノありの指定ですが、五線が${staves.length}本しかありません$label');
    }
  }
  var absorbed = <Staff>[];
  if (piano.isNotEmpty) {
    (piano, absorbed) = _absorbThirdPianoStaff(staves, piano, warnings, label);
  }
  final pianoIds = {...piano, ...absorbed};
  return PageSplit(voices: [for (final s in staves) if (!pianoIds.contains(s)) s], piano: piano, warnings: warnings);
}

(List<Staff>, List<Staff>) _absorbThirdPianoStaff(List<Staff> staves, List<Staff> piano, List<String> warnings, String label) {
  var rh = piano[0], lh = piano[1];
  final iRh = staves.indexOf(rh), iLh = staves.indexOf(lh);
  if (iLh != iRh + 1 || iLh + 1 != staves.length - 1) return (piano, []);
  final bottom = staves[iLh + 1];
  if (_baseClef(staffClef(lh)) != 'G' || _baseClef(staffClef(bottom)) != 'F') return (piano, []);
  if (bottom.role == pianoRh || bottom.role == pianoLh) return (piano, []);
  final extra = rh;
  rh = lh; lh = bottom;
  rh.role = pianoRh; lh.role = pianoLh;
  mergeStaffEvents(rh, extra);
  warnings.add('3段のピアノ譜$label: 最上段を右手に統合しました');
  return ([rh, lh], [extra]);
}

/// Append [extra]'s events to [target] measure by measure as additional voices.
void mergeStaffEvents(Staff target, Staff extra) {
  for (var i = 0; i < target.measures.length && i < extra.measures.length; i++) {
    final mt = target.measures[i], me = extra.measures[i];
    if (me.events.isEmpty) continue;
    final offset = mt.events.fold(-1, (int v, e) => e.voice > v ? e.voice : v) + 1;
    for (final e in me.events) { e.voice = e.voice + offset; mt.events.add(e); }
    _stableSort(mt.events, (a, b) { final c = a.onset.compareTo(b.onset); return c != 0 ? c : a.voice.compareTo(b.voice); });
    for (final w in me.warnings) { if (!mt.warnings.contains(w)) mt.warnings.add(w); }
  }
  extra.role = pianoRh;
}

(Staff, Staff) _bottomPair(List<Staff> staves, List<Staff> rhs, List<Staff> lhs) {
  final sortedLh = [...lhs]..sort((a, b) => staves.indexOf(b).compareTo(staves.indexOf(a)));
  for (final lh in sortedLh) {
    final above = rhs.where((r) => staves.indexOf(r) < staves.indexOf(lh)).toList();
    if (above.isNotEmpty) {
      final rh = above.reduce((a, b) => staves.indexOf(a) >= staves.indexOf(b) ? a : b);
      return (rh, lh);
    }
  }
  return (rhs.first, lhs.first);
}

Score assembleUnits(List<Unit?> units, [EnsembleLayout? layoutHint]) {
  var layout = layoutHint ?? EnsembleLayout();
  final scoreWarnings = <String>[];
  // Android addition (not in the PC structure.py): with image evidence, a
  // piano needs at least one brace joining a treble and a bass staff
  // somewhere in the piece. Otherwise the "last two staves are G and F" rule
  // turns the tenor and bass of an a cappella choir into a piano, and braces
  // grouping two treble voices (SSAA) are taken for a piano.
  if (layout.piano == null && units.any((u) => u != null && u.imageLayout)) {
    final pianoBrace = units.any((u) {
      final pair = u?.pianoPair;
      if (u == null || pair == null || pair.$2 >= u.staves.length) return false;
      return _baseClef(staffClef(u.staves[pair.$1])) == 'G' && _baseClef(staffClef(u.staves[pair.$2])) == 'F';
    });
    if (!pianoBrace) {
      layout = EnsembleLayout(ensemble: layout.ensemble, voiceNames: layout.voiceNames, piano: false);
      units = [for (final u in units) u == null ? null : Unit(u.staves, page: u.page, system: u.system, label: u.label,
        imageLayout: u.imageLayout)];
      scoreWarnings.add('ト音記号とヘ音記号を結ぶブレースが見つからないため、ピアノなしの合唱として組み立てました');
    }
  }
  final splits = <PageSplit?>[];
  final pageNumbers = <int>[];
  final labels = <String>[];
  for (var idx = 0; idx < units.length; idx++) {
    final unit = units[idx];
    final pno = _pageNumber(idx, unit);
    pageNumbers.add(pno);
    final label = unit != null && unit.label.isNotEmpty ? unit.label : '$pnoページ';
    labels.add(label);
    if (unit == null || unit.staves.isEmpty) {
      scoreWarnings.add('$label: 認識結果がないため省略しました');
      splits.add(null);
      continue;
    }
    final split = splitPage(unit.staves, layout, pageLabel: label, pianoOnly: unit.pianoOnly,
      pianoPair: unit.pianoPair, pianoExtra: unit.pianoExtra);
    scoreWarnings.addAll(split.warnings);
    splits.add(split);
  }
  final good = [for (final s in splits) if (s != null) s];
  if (good.isEmpty) {
    return Score(warnings: [...scoreWarnings, '五線を含むページがありません'],
      meta: {'ensemble': layout.ensemble, 'pages': pageNumbers.toSet().length, 'units': units.length, 'piano': false});
  }
  final voicedAll = [for (final s in good) if (s.voices.isNotEmpty) s];
  final voiced = voicedAll.isNotEmpty ? voicedAll : good;
  final counts = <int, int>{};
  for (final s in voiced) { counts[s.voices.length] = (counts[s.voices.length] ?? 0) + 1; }
  final fixed = layout.fixedVoiceCount;
  final nVoices = fixed ?? _majorityVoiceCount(voiced, counts);
  if (counts.length > 1) {
    final sorted = (counts.keys.toList()..sort()).map((k) => '$k段: ${counts[k]}').join('、');
    scoreWarnings.add('段ごとの声部数が一致しません（$sorted）。$nVoices声部として組み立てました');
  }
  final hasPiano = layout.piano != false && good.any((s) => s.piano.isNotEmpty);
  if (layout.piano == true && !hasPiano) scoreWarnings.add('ピアノありの指定ですが、ピアノの段が見つかりません');

  if (hasPiano && nVoices > 2) {
    for (var i = 0; i < splits.length; i++) {
      final split = splits[i];
      if (split == null || split.piano.isNotEmpty || split.voices.length != 2) continue;
      final clefs = [for (final v in split.voices) _baseClef(staffClef(v))];
      if (clefs[0] == 'G' && clefs[1] == 'F') {
        final rh = split.voices[0], lh = split.voices[1];
        rh.role = pianoRh; lh.role = pianoLh;
        splits[i] = PageSplit(voices: [], piano: [rh, lh], warnings: split.warnings);
      }
    }
  }

  final goodNow = [for (final s in splits) if (s != null) s];
  final reference = goodNow.firstWhere((s) => s.voices.length == nVoices, orElse: () => goodNow.first);
  final refClefs = [for (final s in reference.voices.take(nVoices)) staffClef(s)];
  final threeStaffPiano = goodNow.any((sp) => sp.warnings.any((w) => w.contains('3段のピアノ譜')));

  // Systems with more voice staves than the piece. The window matching the
  // reference clefs holds the voices. With an automatic ensemble, a surplus
  // staff with notes becomes an added part (a solo above the choir, ...):
  // it is keyed by its side of the window, distance and clef, so the same
  // part in later systems joins it, and it rests in the other systems.
  // Other surplus staves are dropped as before.
  final extrasByUnit = <int, Map<String, Staff>>{};
  final extraKeys = <String>[];
  final extraUnits = <String, List<Map<String, dynamic>>>{};
  for (var idx = 0; idx < splits.length; idx++) {
    final split = splits[idx];
    if (split == null) continue;
    final label = labels[idx];
    if (threeStaffPiano && split.piano.isNotEmpty && split.voices.length == nVoices + 1) {
      final extra = split.voices.last;
      final base = _baseClef(staffClef(extra));
      if (base == 'G' || base.isEmpty) {
        mergeStaffEvents(split.piano[0], extra);
        split.voices.removeLast();
        scoreWarnings.add('$label: 3段のピアノ譜として、大譜表の上の段を右手に統合しました');
      }
    }
    final pianoOnly = split.piano.isNotEmpty && split.voices.isEmpty && nVoices > 0;
    if (split.voices.length <= nVoices || pianoOnly) continue;
    final first = _selectVoiceWindow(split.voices, nVoices, refClefs);
    // A piece with a piano where this system's brace was missed and the
    // left hand is in treble clef (so the G+F rule did not apply): the two
    // staves below the choir are that piano, not added parts.
    if (hasPiano && split.piano.isEmpty && first == 0 && split.voices.length == nVoices + 2) {
      final rh = split.voices[nVoices], lh = split.voices[nVoices + 1];
      rh.role = pianoRh; lh.role = pianoLh;
      split.piano = [rh, lh];
      split.voices = split.voices.sublist(0, nVoices);
      scoreWarnings.add('$label: ブレースが見つからないため、合唱の下の2段をピアノとしました');
      continue;
    }
    final extras = <String, Staff>{};
    var dropped = 0;
    for (var k = 0; k < split.voices.length; k++) {
      if (k >= first && k < first + nVoices) continue;
      final staff = split.voices[k];
      final key = '${k < first ? 'above${first - k}' : 'below${k - first - nVoices + 1}'}:${_baseClef(staffClef(staff))}';
      if (fixed == null && _soundingEvents(staff) > 2 && !extras.containsKey(key)) {
        extras[key] = staff;
        if (!extraKeys.contains(key)) extraKeys.add(key);
        final unit = units[idx];
        (extraUnits[key] ??= []).add({'page': pageNumbers[idx], 'system': unit?.system,
          'staff': unit == null ? k : unit.staves.indexOf(staff), 'label': label});
      } else {
        dropped++;
      }
    }
    split.voices = split.voices.sublist(first, first + nVoices);
    if (extras.isNotEmpty) {
      extrasByUnit[idx] = extras;
      scoreWarnings.add('$label: ${nVoices + extras.length + dropped}段の声部のうち、${first + 1}～${first + nVoices}段目を'
          '$nVoices声部とし、残る${extras.length}段を追加のパートとしました'
          '${dropped > 0 ? '（音符のない$dropped段は除外）' : ''}');
    } else {
      scoreWarnings.add('$label: ${nVoices + dropped}段の声部を検出しましたが$nVoices声部のため、'
          '${first + 1}～${first + nVoices}段目を使い$dropped段を除外しました');
    }
  }
  // Score order: parts above the choir (farthest first), the voices, parts
  // below the choir (nearest first), then the piano.
  int distance(String key) => int.parse(RegExp(r'\d+').firstMatch(key)!.group(0)!);
  final above = [for (final k in extraKeys) if (k.startsWith('above')) k]
    ..sort((a, b) => distance(b).compareTo(distance(a)));
  final below = [for (final k in extraKeys) if (k.startsWith('below')) k]
    ..sort((a, b) => distance(a).compareTo(distance(b)));
  final extraOrder = [...above, ...below];
  final extraMeasures = {for (final k in extraOrder) k: <Measure>[]};
  final extraClefVotes = {for (final k in extraOrder) k: <String>[]};
  final extraAttrs = {for (final k in extraOrder) k: ((4, 4), 0, '')};
  String ensemble;
  List<String> names;
  if (layout.voiceNames != null) {
    names = [...layout.voiceNames!];
    ensemble = layout.ensemble != 'auto' ? layout.ensemble : 'custom';
  } else if (ensembleVoiceNames.containsKey(layout.ensemble)) {
    ensemble = layout.ensemble;
    names = voiceNamesFor(ensemble, nVoices);
  } else if (layout.ensemble == 'custom') {
    ensemble = 'custom';
    names = voiceNamesFor('custom', nVoices);
  } else {
    ensemble = detectEnsemble(refClefs);
    names = voiceNamesFor(ensemble, nVoices);
  }
  names = [...names, for (var i = names.length; i < nVoices; i++) 'Voice ${i + 1}'].take(nVoices).toList();

  final voiceMeasures = [for (var i = 0; i < nVoices; i++) <Measure>[]];
  final rhMeasures = <Measure>[], lhMeasures = <Measure>[];
  final voiceClefVotes = [for (var i = 0; i < nVoices; i++) <String>[]];
  final pageStats = <Map<String, dynamic>>[];
  final lastAttrs = List<((int, int), int, String)>.filled(nVoices + 2, ((4, 4), 0, ''));
  var pianoOnlyUnits = 0;
  for (var idx = 0; idx < splits.length; idx++) {
    final split = splits[idx];
    if (split == null) continue;
    final pno = pageNumbers[idx];
    final label = labels[idx];
    final unit = units[idx];
    final systemTag = unit?.system;
    final int pageTag = pno;
    final pianoOnly = split.piano.isNotEmpty && split.voices.isEmpty && nVoices > 0;
    final extras = extrasByUnit[idx] ?? const <String, Staff>{};
    final allStaves = [...split.voices, ...extras.values, ...split.piano];
    final lengths = [for (final s in allStaves) s.measures.length];
    // Android addition (not in the PC structure.py): a staff holding only
    // rests often loses a barline (multi-bar rests, a final barline read as
    // part of the rest), so it does not vote on the bar count when at least
    // two staves with notes are present and a strict majority (>= 2) of them
    // agree on the count.
    final informative = [for (final s in allStaves) if (_soundingEvents(s) > 2) s];
    final informativeCounts = <int, int>{};
    for (final s in informative) { informativeCounts[s.measures.length] = (informativeCounts[s.measures.length] ?? 0) + 1; }
    final informativeTop = informativeCounts.values.fold(0, (a, b) => a > b ? a : b);
    final voters = informative.length >= 2 && informative.length < allStaves.length &&
            informativeTop >= 2 && informativeTop * 2 > informative.length ? informative : allStaves;
    final nMeas = _preferLowerCount(voters, _targetMeasureCount([for (final s in voters) s.measures.length]));
    if (lengths.toSet().length > 1) {
      scoreWarnings.add('$label: 段ごとの小節数が異なります（${lengths.join(', ')}）。$nMeas小節として扱いました');
      for (final st in allStaves) {
        if (st.measures.length > nMeas) scoreWarnings.add(_trimSurplusMeasures(st, nMeas, label));
      }
    }
    if (pianoOnly) {
      pianoOnlyUnits++;
      scoreWarnings.add('$label: ピアノだけの段（$nMeas小節）。歌声部は休符で補いました');
    } else if (split.voices.length != nVoices) {
      scoreWarnings.add('$label: 声部の段が${split.voices.length}本（全体は$nVoices声部）。上から順に対応付けました');
    }
    if (hasPiano && split.piano.isEmpty) scoreWarnings.add('$label: ピアノの段が見つからないため休符で補いました');

    Staff? refStaff;
    for (final s in allStaves) { if (refStaff == null || s.measures.length > refStaff.measures.length) refStaff = s; }

    final outputs = <(int, Staff?, List<Measure>)>[
      for (var vi = 0; vi < nVoices; vi++) (vi, vi < split.voices.length ? split.voices[vi] : null, voiceMeasures[vi]),
      if (hasPiano) (nVoices, split.piano.isNotEmpty ? split.piano[0] : null, rhMeasures),
      if (hasPiano) (nVoices + 1, split.piano.isNotEmpty ? split.piano[1] : null, lhMeasures),
    ];
    for (final key in extraOrder) {
      final src = extras[key];
      final target = extraMeasures[key]!;
      if (src != null) {
        for (final m in src.measures) {
          extraAttrs[key] = (m.timeSig, m.keyFifths, m.clef.isNotEmpty ? m.clef : extraAttrs[key]!.$3);
          if (m.clef.isNotEmpty) extraClefVotes[key]!.add(m.clef);
        }
        if (src.clef.isNotEmpty) extraClefVotes[key]!.add(src.clef);
      }
      for (var mi = 0; mi < nMeas; mi++) {
        if (src != null && mi < src.measures.length) {
          final m = src.measures[mi];
          m.page = pageTag;
          target.add(m);
          continue;
        }
        final refM = refStaff != null && mi < refStaff.measures.length ? refStaff.measures[mi] : null;
        var (ts, kf, cl) = extraAttrs[key]!;
        if (refM != null) { ts = refM.timeSig; kf = refM.keyFifths; }
        // Clef of the part where it is printed; before its first system the
        // key's clef letter (G/F) stands in.
        if (cl.isEmpty) cl = key.split(':').last == 'F' ? 'F4' : 'G2';
        final rest = restMeasure(ts, kf, cl, pageTag,
            src == null ? 'added part not printed on $label' : 'missing measure ${mi + 1} on $label');
        if (refM != null) rest.system = refM.system;
        if (systemTag != null) rest.system = systemTag;
        target.add(rest);
      }
    }
    for (final (outIdx, src, target) in outputs) {
      if (src != null && src.measures.isNotEmpty) {
        for (final m in src.measures) {
          lastAttrs[outIdx] = (m.timeSig, m.keyFifths, m.clef.isNotEmpty ? m.clef : lastAttrs[outIdx].$3);
          if (outIdx < nVoices && m.clef.isNotEmpty) voiceClefVotes[outIdx].add(m.clef);
        }
      }
      if (src != null && src.clef.isNotEmpty && outIdx < nVoices) voiceClefVotes[outIdx].add(src.clef);
      for (var mi = 0; mi < nMeas; mi++) {
        if (src != null && mi < src.measures.length) {
          final m = src.measures[mi];
          m.page = pageTag;
          target.add(m);
          continue;
        }
        final refM = refStaff != null && mi < refStaff.measures.length ? refStaff.measures[mi] : null;
        var (ts, kf, cl) = lastAttrs[outIdx];
        if (refM != null) { ts = refM.timeSig; kf = refM.keyFifths; }
        final reason = src == null && pianoOnly ? 'piano-only system on $label'
            : src == null ? 'missing staff on $label' : 'missing measure ${mi + 1} on $label';
        final rest = restMeasure(ts, kf, cl, pageTag, reason);
        if (refM != null) rest.system = refM.system;
        if (systemTag != null) rest.system = systemTag;
        target.add(rest);
      }
    }
    pageStats.add({'page': pno, 'system': systemTag, 'label': label, 'voice_staves': split.voices.length,
      'piano': split.piano.isNotEmpty, 'piano_only': pianoOnly, 'measures': nMeas, 'measure_counts': lengths,
      if (extras.isNotEmpty) 'added_parts': extras.length});
  }

  final staves = <Staff>[];
  final keyOf = <Staff, String>{};
  Staff extraStaff(String key, int number) {
    final staff = Staff(id: '', role: voiceRole, name: extraOrder.length == 1 ? 'Solo' : 'Solo $number',
        measures: extraMeasures[key]!, clef: majority(extraClefVotes[key]!) ?? '', midiProgram: gmChoirAahs)
      ..added = true;
    keyOf[staff] = key;
    return staff;
  }
  for (var e = 0; e < above.length; e++) { staves.add(extraStaff(above[e], e + 1)); }
  for (var vi = 0; vi < nVoices; vi++) {
    final name = names[vi];
    final vtype = voiceTypeFor(name);
    final clef = majority(voiceClefVotes[vi]) ?? '';
    final staff = Staff(id: '', role: voiceRole, name: name, measures: voiceMeasures[vi], clef: clef,
      midiProgram: gmChoirAahs, voiceType: vtype);
    if (vtype == 'tenor' && clef == 'G') staff.octaveShift = -1;
    staves.add(staff);
  }
  for (var e = 0; e < below.length; e++) { staves.add(extraStaff(below[e], above.length + e + 1)); }
  if (hasPiano) {
    staves.add(Staff(id: '', role: pianoRh, name: 'Piano RH', measures: rhMeasures,
      clef: _firstClef(rhMeasures).isNotEmpty ? _firstClef(rhMeasures) : 'G', midiProgram: gmAcousticGrand));
    staves.add(Staff(id: '', role: pianoLh, name: 'Piano LH', measures: lhMeasures,
      clef: _firstClef(lhMeasures).isNotEmpty ? _firstClef(lhMeasures) : 'F', midiProgram: gmAcousticGrand));
  }
  for (var i = 0; i < staves.length; i++) { staves[i].id = 'S${i + 1}'; }
  for (final s in staves) { for (var i = 0; i < s.measures.length; i++) { s.measures[i].number = i + 1; } }
  final addedParts = [
    for (final s in staves)
      if (keyOf[s] case final key?) {'id': s.id, 'position': key.split(':').first, 'systems': extraUnits[key]},
  ];
  return Score(staves: staves, warnings: scoreWarnings, meta: {
    'ensemble': ensemble, 'voice_names': names, 'voice_count': nVoices, 'piano': hasPiano,
    if (addedParts.isNotEmpty) 'added_parts': addedParts,
    'pages': pageNumbers.toSet().length, 'units': units.length,
    'pages_used': {for (var i = 0; i < splits.length; i++) if (splits[i] != null) pageNumbers[i]}.length,
    'units_used': splits.where((s) => s != null).length, 'piano_only_units': pianoOnlyUnits,
    'page_stats': pageStats, 'measure_count': staves.isEmpty ? 0 : staves.first.measures.length,
  });
}

int _pageNumber(int idx, Unit? unit) {
  if (unit != null) {
    if (unit.page != null) return unit.page!;
    for (final s in unit.staves) { for (final m in s.measures) { if (m.page != null) return m.page!; } }
  }
  return idx + 1;
}

int _selectVoiceWindow(List<Staff> voices, int n, List<String> refClefs) {
  final m = voices.length;
  if (n <= 0 || m <= n) return 0;
  final want = [for (final c in refClefs.take(n)) _baseClef(c)];
  final have = [for (final v in voices) _baseClef(staffClef(v))];
  var bestFirst = 0, bestScore = -1;
  for (var first = 0; first <= m - n; first++) {
    var score = 0;
    for (var k = 0; k < n; k++) {
      if (k < want.length && want[k].isNotEmpty && have[first + k] == want[k]) score++;
    }
    if (score >= bestScore) { bestFirst = first; bestScore = score; }
  }
  return bestFirst;
}

int _targetMeasureCount(List<int> lengths) {
  if (lengths.isEmpty) return 0;
  final counts = <int, int>{};
  for (final l in lengths) { counts[l] = (counts[l] ?? 0) + 1; }
  final top = counts.values.reduce((a, b) => a > b ? a : b);
  final modes = [for (final e in counts.entries) if (e.value == top) e.key];
  if (modes.length == 1 && top >= 2) return modes.first;
  final ordered = [...lengths]..sort();
  return ordered[ordered.length ~/ 2];
}

int _soundingEvents(Staff s) =>
    s.measures.fold(0, (n, m) => n + m.events.where((e) => e.pitches.isNotEmpty && !e.grace).length);

int _measureNotes(Measure m) => m.events.fold(0, (n, e) => n + e.pitches.length);

const fragmentMaxNotes = 6;

bool _isFragment(Staff staff, int i, [int maxNotes = fragmentMaxNotes]) {
  final m = staff.measures[i];
  if (_measureNotes(m) > maxNotes) return false;
  final nominal = m.nominalLength();
  if (nominal <= zeroFrac || m.actualLength() * frac(2) < nominal) return true;
  if (i == 0) return false;
  final prev = staff.measures[i - 1];
  final changed = m.keyFifths != prev.keyFifths || m.timeSig != prev.timeSig;
  final pitched = m.events.where((e) => e.pitches.isNotEmpty && !e.grace).length;
  return changed && pitched <= 1;
}

int _preferLowerCount(List<Staff> staves, int target, [int maxNotes = fragmentMaxNotes]) {
  final lower = {for (final st in staves) if (st.measures.isNotEmpty && st.measures.length < target) st.measures.length}.toList()..sort();
  if (lower.isEmpty) return target;
  final c = lower.last;
  for (final st in staves) {
    final extra = st.measures.length - c;
    if (extra <= 0) continue;
    for (var i = c; i < st.measures.length; i++) { if (!_isFragment(st, i, maxNotes)) return target; }
  }
  return c;
}

String _trimSurplusMeasures(Staff staff, int target, String label) {
  final surplus = staff.measures.length - target;
  if (surplus <= 0) return '';
  (int, int, int) rank(int i) => (_isFragment(staff, i) ? 0 : 1, _measureNotes(staff.measures[i]), -i);
  final ranked = List.generate(staff.measures.length, (i) => i)..sort((a, b) {
    final ra = rank(a), rb = rank(b);
    if (ra.$1 != rb.$1) return ra.$1.compareTo(rb.$1);
    if (ra.$2 != rb.$2) return ra.$2.compareTo(rb.$2);
    return ra.$3.compareTo(rb.$3);
  });
  final drop = ranked.take(surplus).toSet();
  final notes = drop.fold(0, (n, i) => n + _measureNotes(staff.measures[i]));
  staff.measures = [for (var i = 0; i < staff.measures.length; i++) if (!drop.contains(i)) staff.measures[i]];
  final dropped = (drop.toList()..sort()).map((i) => i + 1).join(', ');
  return '$label: ${staff.id}の${target + surplus}小節を$target小節に合わせ、$dropped小節目（音符$notes個）を除外しました';
}

int _majorityVoiceCount(List<PageSplit> splits, Map<int, int> counts) {
  final top = counts.values.reduce((a, b) => a > b ? a : b);
  final candidates = [for (final e in counts.entries) if (e.value == top) e.key]..sort((a, b) => b.compareTo(a));
  if (candidates.length == 1) return candidates.first;
  for (final n in candidates) {
    final page = splits.firstWhere((s) => s.voices.length == n);
    if (detectEnsemble([for (final v in page.voices) staffClef(v)]) != 'custom') return n;
  }
  return candidates.first;
}

String _firstClef(List<Measure> measures) {
  for (final m in measures) { if (m.clef.isNotEmpty) return m.clef; }
  return '';
}

Measure restMeasure((int, int) timeSig, int keyFifths, String clef, int? page, String reason) {
  final m = Measure(number: 0, timeSig: timeSig, keyFifths: keyFifths, clef: clef, page: page, warnings: [reason]);
  m.events.add(NoteEvent(onset: zeroFrac, duration: m.nominalLength(), source: 'structure:pad', inferredRest: true));
  return m;
}

/// Stable in-place sort (Dart's List.sort is not guaranteed stable).
void _stableSort<T>(List<T> list, int Function(T, T) compare) {
  final indexed = [for (var i = 0; i < list.length; i++) (i, list[i])];
  indexed.sort((a, b) { final c = compare(a.$2, b.$2); return c != 0 ? c : a.$1.compareTo(b.$1); });
  for (var i = 0; i < list.length; i++) { list[i] = indexed[i].$2; }
}

void stableSort<T>(List<T> list, int Function(T, T) compare) => _stableSort(list, compare);
