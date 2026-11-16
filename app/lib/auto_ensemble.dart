import 'dart:math' as math;
import 'omr_bridge.dart';
import 'omr_symbols.dart';
import 'omr_staff_assembler.dart';

class AutoEnsemble {
  const AutoEnsemble(this.pages, this.voiceNames, this.piano, this.warnings, this.evidence);
  final List<RecognizedPageSymbols> pages;
  final List<String> voiceNames, warnings;
  final bool piano;
  final String evidence;
}

class _Label {
  const _Label(this.type, this.ordinal);
  final String type;
  final int ordinal;
  String get key => '$type/$ordinal';
}

/// Part name of a printed staff label: (type, ordinal), e.g. `Tenor II` ->
/// ('tenor', 2); null when the text is not a part name.
(String, int)? parsePartLabel(String source) {
  final label = _label(source);
  return label == null ? null : (label.type, label.ordinal);
}

_Label? _label(String source) {
  var text = source.toLowerCase().replaceAll('ⅰ', 'i').replaceAll('ⅱ', 'ii')
      .replaceAll('ⅲ', 'iii').replaceAll('ⅳ', 'iv').replaceAll('１', '1').replaceAll('２', '2');
  const aliases = {
    'soprano': 'soprano', 'soprani': 'soprano', 'sopran': 'soprano', 'sop': 'soprano', 'ソプラノ': 'soprano',
    'alto': 'alto', 'alti': 'alto', 'alt': 'alto', 'アルト': 'alto',
    'tenori': 'tenor', 'tenore': 'tenor', 'tenor': 'tenor', 'ten': 'tenor', 'テノール': 'tenor', 'テナー': 'tenor',
    'baritoni': 'baritone', 'baritono': 'baritone', 'baritone': 'baritone', 'bari': 'baritone', 'bar': 'baritone', 'バリトン': 'baritone',
    'bassi': 'bass', 'basso': 'bass', 'bass': 'bass', 'bas': 'bass', 'バス': 'bass',
    'pianoforte': 'piano', 'piano': 'piano', 'pno': 'piano', 'pf': 'piano', 'ピアノ': 'piano',
    's': 'soprano', 'a': 'alto', 't': 'tenor', 'b': 'bass',
  };
  int ordinalOf(String suffix) =>
      switch (suffix) { '1' || 'i' || 'l' => 1, '2' || 'ii' || 'll' => 2, '3' || 'iii' => 3, '4' || 'iv' => 4, _ => 0 };
  // A separated ordinal decides first: "Tenor II" is tenor 2, not the
  // Italian plural "Tenori" + "I" (both are "tenorii" without spaces).
  final words = text.trim().split(RegExp(r'\s+'));
  if (words.length >= 2) {
    final name = words.first.replaceAll(RegExp(r'[.\-:,_()\[\]]'), '');
    final suffix = words.skip(1).join().replaceAll(RegExp(r'[.\-:,_()\[\]]'), '');
    if (aliases.containsKey(name) && RegExp(r'^[1234ivl]+$').hasMatch(suffix)) {
      return _Label(aliases[name]!, ordinalOf(suffix));
    }
  }
  text = text.replaceAll(RegExp(r'[\s.\-:,_()\[\]]'), '');
  for (final entry in aliases.entries) {
    if (!text.startsWith(entry.key)) continue;
    final suffix = text.substring(entry.key.length);
    if (!RegExp(r'^[1234ivl]*$').hasMatch(suffix)) continue;
    return _Label(entry.value, ordinalOf(suffix));
  }
  return null;
}

class _Staff {
  _Staff(this.source);
  final RecognizedStaffSymbols source;
  _Label? label;
  String get clef {
    for (final s in source.symbols) { if (s.rhythm.startsWith('clef_')) return s.rhythm.substring(5, 6); }
    return '';
  }
  double get y => source.centerY;
  double get height => math.max(1, source.staffHeight);
}

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

double _gap(_Staff a, _Staff b) => b.y - a.y - (a.height + b.height) / 2;

class AutoEnsembleDetector {
  AutoEnsemble detect(List<RecognizedPageSymbols> pages) {
    if (pages.isEmpty) throw const FormatException('認識ページがありません。');
    final grouped = <List<List<_Staff>>>[];
    final warnings = <String>[];
    var male = false;
    for (var p = 0; p < pages.length; p++) {
      final page = pages[p];
      if (page.staves.isEmpty) throw FormatException('${page.pageNumber ?? p + 1}ページで五線を検出できません。表紙や空白ページは対象から外してください。');
      final staves = page.staves.map(_Staff.new).toList()..sort((a, b) => a.y.compareTo(b.y));
      male |= page.labels.any((l) => l.text.contains('男声') || l.text.toLowerCase().contains('male choir'));
      for (final text in page.labels) {
        final parsed = _label(text.text);
        if (parsed == null) continue;
        final cy = (text.bounds[1] + text.bounds[3]) / 2;
        final candidates = staves.where((s) {
          final left = s.source.left ?? s.source.crop[0];
          final beside = text.bounds[2] <= left + s.height * .65 &&
              (s.y - cy).abs() <= s.height * (parsed.type == 'piano' ? 2.8 : .95);
          final top = s.source.lines.length == 5 ? s.source.lines.first : s.y - s.height / 2;
          final above = text.bounds[0] >= left - s.height && text.bounds[2] <= left + s.height * 5 &&
              text.bounds[1] >= top - s.height * 1.2 && text.bounds[3] <= top + s.height * .1;
          return beside || above;
        }).toList()
          ..sort((a, b) => (a.y - cy).abs().compareTo((b.y - cy).abs()));
        if (candidates.isEmpty) continue;
        final nearest = candidates.first;
        if (nearest.label == null || (nearest.label!.ordinal == 0 && parsed.ordinal > 0)) nearest.label = parsed;
      }
      grouped.add(_systems(staves, confirmedPiano: staves.any((s) => s.label?.type == 'piano')));
    }
    final groups = grouped.expand((g) => g).toList();
    final confirmedPiano = groups.any((g) => g.length == 2 &&
        g.any((s) => s.label?.type == 'piano') && _piano(g));
    final usable = groups.where((g) => g.length <= 14).toList();
    if (usable.isEmpty) throw FormatException('段の区切りを自動判定できません。検出した五線数: ${pages.map((p) => p.staves.length).join(', ')}。手動設定で原譜の編成を指定してください。');
    // Prefer a full labelled system over a piano-only introduction.
    usable.sort((a, b) {
      final labelsA = a.where((s) => s.label != null && s.label!.type != 'piano').length;
      final labelsB = b.where((s) => s.label != null && s.label!.type != 'piano').length;
      final labels = labelsB.compareTo(labelsA);
      if (labels != 0) return labels;
      final pianoA = _piano(a, confirmedPiano: confirmedPiano), pianoB = _piano(b, confirmedPiano: confirmedPiano);
      if (pianoA != pianoB) return pianoB ? 1 : -1;
      return labelsA > 0 ? a.length.compareTo(b.length) : b.length.compareTo(a.length);
    });
    final template = usable.first;
    final piano = _piano(template, confirmedPiano: confirmedPiano);
    final voices = template.length - (piano ? 2 : 0);
    if (voices > 12 || voices == 0 && !piano) throw const FormatException('声部数を自動判定できません。手動設定で編成を指定してください。');
    final types = <String>[];
    final isMaleQuartet = male && voices == 4 && template.take(4).map((s) => s.clef).join() == 'GGFF';
    for (var i = 0; i < voices; i++) {
      final explicit = template[i].label;
      types.add(explicit != null && explicit.type != 'piano' ? explicit.type :
        isMaleQuartet ? const ['tenor', 'tenor', 'baritone', 'bass'][i] : 'unknown');
    }
    const names = {'soprano': 'Soprano', 'alto': 'Alto', 'tenor': 'Tenor', 'baritone': 'Baritone', 'bass': 'Bass'};
    final counts = <String, int>{};
    final voiceNames = <String>[];
    for (var i = 0; i < voices; i++) {
      final type = types[i];
      counts[type] = (counts[type] ?? 0) + 1;
      final base = names[type] ?? '声部 ${i + 1}';
      final duplicates = type != 'unknown' && types.where((v) => v == type).length > 1;
      voiceNames.add(duplicates ? '$base ${counts[type]}' : base);
    }
    if (types.contains('unknown')) warnings.add('一部の声部名を読み取れなかったため声部番号で保持しました。実音、とくにテノールのオクターブを確認してください。');
    final prepared = <RecognizedPageSymbols>[];
    for (var p = 0; p < pages.length; p++) {
      final flat = <RecognizedStaffSymbols>[];
      final systems = <List<_Staff>>[];
      final pageGroups = _withTemplate(grouped[p], template.length);
      for (final group in pageGroups) {
        if (group.length > template.length && group.length % template.length == 0) {
          for (var i = 0; i < group.length; i += template.length) { systems.add(group.sublist(i, i + template.length)); }
        } else { systems.add(group); }
      }
      for (final group in systems) {
        if (group.length == template.length) {
          for (var i = 0; i < voices; i++) {
            final label = group[i].label;
            if (label != null && label.type != 'piano' && types[i] != 'unknown' && label.type != types[i]) {
              throw FormatException('${pages[p].pageNumber ?? p + 1}ページで声部の並びが変わっています。原譜の省略・divisiを確認してください。');
            }
            final original = template[i].label;
            if (label != null && original != null && label.ordinal > 0 && original.ordinal > 0 && label.ordinal != original.ordinal) {
              throw FormatException('${pages[p].pageNumber ?? p + 1}ページで声部番号が変わっています。divisiや省略を原譜で確認してください。');
            }
          }
          flat.addAll(group.map((s) => s.source));
        } else if (piano && group.length == 2 && _piano(group)) {
          for (var i = 0; i < voices; i++) { flat.add(_silentStaff(group.first.source, template[i].clef)); }
          flat.addAll(group.map((s) => s.source));
          warnings.add('${pages[p].pageNumber ?? p + 1}ページ: ピアノだけの段に、省略された歌声部の休符を補いました。');
        } else {
          throw FormatException('${pages[p].pageNumber ?? p + 1}ページの段で${group.length}本の五線を検出しましたが、他の段からは$voices声${piano ? '＋ピアノ2段' : ''}を推定しました。省略された声部や検出漏れを原譜で確認してください。');
        }
      }
      final page = pages[p];
      prepared.add(RecognizedPageSymbols(staves: flat, warnings: page.warnings, width: page.width, height: page.height,
        labels: page.labels, pageNumber: page.pageNumber ?? p + 1));
    }
    warnings.add('編成を自動推定しました: ${voiceNames.join(', ')}${piano ? '＋ピアノ' : '（無伴奏）'}。原譜と照合してください。');
    return AutoEnsemble(prepared, voiceNames, piano, warnings, template.any((s) => s.label != null) ? 'ocr-and-layout' : 'layout-and-clefs');
  }

  List<List<_Staff>> _withTemplate(List<List<_Staff>> groups, int size) {
    if (groups.every((g) => g.length == size)) return groups;
    final staves = groups.expand((g) => g).toList();
    // A choir/piano gap can exceed the local system threshold. Use the
    // established full ensemble only when repeated, larger page gaps confirm
    // the same system size. Do not fill missing staves or guess single systems.
    if (size < 2 || staves.length < size * 2 || staves.length % size != 0) return groups;
    final inside = <double>[], boundaries = <double>[];
    for (var i = 1; i < staves.length; i++) {
      (i % size == 0 ? boundaries : inside).add(_gap(staves[i - 1], staves[i]));
    }
    final typical = _median(inside.where((g) => g > 0).toList());
    if (typical <= 0 || inside.any((g) => g > typical * 2.4) ||
        boundaries.any((g) => g <= typical * 1.35)) {
      return groups;
    }
    return [for (var i = 0; i < staves.length; i += size) staves.sublist(i, i + size)];
  }

  List<List<_Staff>> _systems(List<_Staff> staves, {bool confirmedPiano = false}) {
    if (staves.length == 1) return [staves];
    final gaps = [for (var i = 1; i < staves.length; i++) _gap(staves[i - 1], staves[i])];
    final median = _median(gaps.where((g) => g > 0).toList());
    final groups = <List<_Staff>>[];
    var current = <_Staff>[];
    for (var i = 0; i < staves.length; i++) {
      final pianoFollows = i + 1 < staves.length && current.length >= 3 && staves[i].clef == 'G' && staves[i + 1].clef == 'F' &&
          _gap(staves[i], staves[i + 1]) < median * (confirmedPiano ? 1.2 : .78) &&
          (i == 0 || gaps[i - 1] < median * 2.4) &&
          [staves[i], staves[i + 1]].every((s) => s.label == null || s.label!.type == 'piano');
      if (i > 0 && !pianoFollows && gaps[i - 1] > median * 1.35 && gaps[i - 1] > staves[i].height * 1.5) {
        groups.add(current); current = [];
      }
      current.add(staves[i]);
    }
    groups.add(current);
    final result = <List<_Staff>>[];
    for (final group in groups) {
      var period = group.length;
      for (var n = 1; n <= math.min(14, group.length ~/ 2); n++) {
        if (group.length % n != 0 || group.any((s) => s.label == null)) continue;
        if (group.take(n).map((s) => s.label!.key).toSet().length < 2 &&
            !(n == 1 && List.generate(group.length - 1, (i) => _gap(group[i], group[i + 1]) > group[i].height * 2).every((v) => v))) {
          continue;
        }
        if (List.generate(group.length, (i) => group[i].label!.key == group[i % n].label!.key).every((v) => v)) { period = n; break; }
      }
      for (var n = 2; n <= math.min(14, group.length ~/ 2); n++) {
        if (period != group.length) break;
        if (group.length % n != 0 || group.take(n).any((s) => s.clef.isEmpty) || group[n - 1].clef == group[0].clef) continue;
        if (!List.generate(group.length, (i) => group[i].clef == group[i % n].clef).every((v) => v)) continue;
        final boundaries = [for (var i = n; i < group.length; i += n) _gap(group[i - 1], group[i])];
        final inside = [for (var i = 1; i < group.length; i++) if (i % n != 0) _gap(group[i - 1], group[i])];
        if (boundaries.every((g) => g > _median(inside) * 1.12)) { period = n; break; }
      }
      for (var i = 0; i < group.length; i += period) { result.add(group.sublist(i, i + period)); }
    }
    return result;
  }

  bool _piano(List<_Staff> group, {bool confirmedPiano = false}) {
    if (group.length < 2) return false;
    final upper = group[group.length - 2], lower = group.last;
    if ([upper, lower].any((s) => s.label != null && s.label!.type != 'piano')) return false;
    if (upper.clef != 'G' || lower.clef != 'F') return false;
    if ([upper, lower].any((s) => s.label?.type == 'piano')) return true;
    if (confirmedPiano && group.length > 2 &&
        group.take(group.length - 2).every((s) => s.label != null && s.label!.type != 'piano')) {
      return true;
    }
    final gap = _gap(upper, lower);
    if (group.length > 2) {
      final other = [for (var i = 1; i < group.length - 1; i++) _gap(group[i - 1], group[i])];
      return gap < _median(other) * .78;
    }
    final chord = groupOmrChords(upper.source.symbols).any((g) => g.where((s) => s.isTimed && s.pitch != '_' && s.pitch != '.').length > 1);
    return chord && gap < (upper.height + lower.height);
  }

  RecognizedStaffSymbols _silentStaff(RecognizedStaffSymbols reference, String clef) {
    final filtered = <OmrSymbol>[];
    for (final group in groupOmrChords(reference.symbols)) {
      final upper = group.where((s) => s.position != 'lower').toList();
      for (var i = 0; i < upper.length; i++) {
        if (i > 0) filtered.add(const OmrSymbol(rhythm: 'chord', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'));
        filtered.add(upper[i]);
      }
    }
    final decoded = OmrStaffAssembler().assemble(filtered);
    final symbols = <OmrSymbol>[];
    void add(String rhythm) => symbols.add(OmrSymbol(rhythm: rhythm, pitch: '.', lift: '.', position: 'upper', articulation: '.', slur: '.'));
    add('placeholderStart');
    if (clef == 'G' || clef == 'F') add('clef_${clef == 'G' ? 'G2' : 'F4'}');
    for (final measure in decoded['measures'] as List) {
      final time = (measure['time_sig'] as List).cast<int>();
      add('keySignature_${measure['key_fifths']}'); add('timeSignature/${time[1]}');
      // A denominator beat is represented exactly; final meter alignment uses
      // the sounding staves rather than these synthetic rests as voters.
      for (var i = 0; i < time[0]; i++) { add('rest_${time[1]}'); }
      add('barline');
    }
    add('placeholderEnd');
    return RecognizedStaffSymbols(symbols: symbols, reachedEos: true, crop: reference.crop, lines: reference.lines, left: reference.left, right: reference.right);
  }
}
