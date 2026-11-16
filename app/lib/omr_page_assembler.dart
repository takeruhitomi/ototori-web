import 'omr_bridge.dart';
import 'omr_staff_assembler.dart';
import 'omr_symbols.dart';
import 'ensemble_meter.dart';

/// Initial, strict assembly for pages with a fixed number of visible staves
/// per system. Ambiguous layouts are rejected rather than padded silently.
class OmrPageAssembler {
  Map<String, dynamic> assemblePages(List<RecognizedPageSymbols> pages, {
    required List<String> voiceNames, required bool piano, double tempo = 80,
  }) {
    if (pages.isEmpty) throw const FormatException('認識ページがありません。');
    final parts = voiceNames.length + (piano ? 2 : 0);
    if (parts == 0) throw const FormatException('声部を指定してください。');
    final staves = <RecognizedStaffSymbols>[];
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      final originalPage = page.pageNumber ?? i + 1;
      if (page.staves.isEmpty || page.staves.length % parts != 0) {
        throw FormatException('$originalPageページで${page.staves.length}本の五線を検出しました。指定は${voiceNames.length}声${piano ? '＋ピアノ2段' : ''}です。編成の自動判定を使うか、原譜の編成に合わせてください。');
      }
      for (var j = 0; j < page.staves.length; j++) {
        final staff = page.staves[j];
        staves.add(RecognizedStaffSymbols(symbols: [
          if (j < parts) OmrSymbol(rhythm: 'pageBoundary/$originalPage', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'),
          OmrSymbol(rhythm: 'systemBoundary/${j ~/ parts}', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'),
          ...staff.symbols,
        ], reachedEos: staff.reachedEos, crop: staff.crop, lines: staff.lines, left: staff.left, right: staff.right));
      }
    }
    final result = assemble(RecognizedPageSymbols(staves: staves,
      warnings: [for (var i = 0; i < pages.length; i++) for (final w in pages[i].warnings) '${i + 1}ページ: $w'],
      width: pages.first.width, height: pages.first.height), pageNumber: 1,
      voiceNames: voiceNames, piano: piano, tempo: tempo, preservePageNumbers: true);
    result['meta']['pages'] = [for (var i = 0; i < pages.length; i++) pages[i].pageNumber ?? i + 1];
    result['meta']['layout'] = {'pages': [for (var p = 0; p < pages.length; p++) {
      'page': pages[p].pageNumber ?? p + 1, 'width': pages[p].width, 'height': pages[p].height,
      'systems': [for (var s = 0; s < pages[p].staves.length ~/ parts; s++) {
        'index': s,
        'x0': pages[p].staves.skip(s * parts).take(parts).map((v) => v.left ?? v.crop[0]).reduce((a, b) => a < b ? a : b),
        'x1': pages[p].staves.skip(s * parts).take(parts).map((v) => v.right ?? v.crop[2]).reduce((a, b) => a > b ? a : b),
        'y0': pages[p].staves[s * parts].crop[1],
        'y1': pages[p].staves[(s + 1) * parts - 1].crop[3],
      }],
    }]};
    return result;
  }

  Map<String, dynamic> assemble(RecognizedPageSymbols page, {
    required int pageNumber,
    required List<String> voiceNames,
    required bool piano,
    double tempo = 80,
    bool preservePageNumbers = false,
  }) {
    if (pageNumber < 1 || (voiceNames.isEmpty && !piano) || voiceNames.length > 12 ||
        voiceNames.any((name) => name.trim().isEmpty) || !tempo.isFinite || tempo <= 0) {
      throw const FormatException('編成またはページ設定が不正です。');
    }
    final parts = voiceNames.length + (piano ? 2 : 0);
    if (page.staves.isEmpty || page.staves.length % parts != 0) {
      throw const FormatException('五線数が指定された編成と一致しません。原譜を確認してください。');
    }
    if (page.staves.any((s) => !s.reachedEos)) {
      throw const FormatException('認識が途中で終わった五線があります。');
    }
    final all = <Map<String, dynamic>>[];
    final octaveApplied = <String, int>{};
    final pageWarnings = <String>[];
    var discardedLowerSymbols = false;
    final systems = page.staves.length ~/ parts;
    for (var part = 0; part < parts; part++) {
      final symbols = <OmrSymbol>[];
      for (var system = 0; system < systems; system++) {
        if (!preservePageNumbers) {
          symbols.add(OmrSymbol(rhythm: 'systemBoundary/$system', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'));
        }
        // Physical staves are currently inferred separately. Filter spurious
        // lower-position tokens as homr does for a single staff.
        final groups = groupOmrChords(page.staves[system * parts + part].symbols);
        for (final group in groups) {
          if (group.any((s) => s.position == 'lower')) discardedLowerSymbols = true;
          final upper = group.where((s) => s.position != 'lower').toList();
          for (var i = 0; i < upper.length; i++) {
            if (i > 0) symbols.add(const OmrSymbol(rhythm: 'chord', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'));
            symbols.add(upper[i]);
          }
        }
      }
      final staff = OmrStaffAssembler().assemble(symbols, staffId: 'S${part + 1}', detectTies: false);
      final role = part < voiceNames.length ? 'voice' : (part == voiceNames.length ? 'piano_rh' : 'piano_lh');
      staff['role'] = role;
      staff['name'] = role == 'voice' ? voiceNames[part].trim() : 'ピアノ';
      staff['midi_program'] = role == 'voice' ? 52 : 0;
      final voiceType = role == 'voice' ? _voiceType(staff['name'] as String) : '';
      staff['voice_type'] = voiceType;
      if (voiceType == 'tenor' && staff['clef'] == 'G') {
        var changed = 0;
        for (final measure in staff['measures'] as List) {
          if (measure['clef'] == 'G') measure['clef'] = 'G8vb';
          for (final event in measure['events'] as List) {
            final pitches = event['pitches'] as List;
            for (var i = 0; i < pitches.length; i++) {
              final shifted = (pitches[i] as int) - 12;
              if (shifted < 0) throw const FormatException('テノールの実音が MIDI の範囲外です。');
              pitches[i] = shifted;
              changed++;
            }
          }
        }
        staff['clef'] = 'G8vb';
        staff['octave_shift'] = -1;
        octaveApplied[staff['id'] as String] = -1;
        if (changed > 0) pageWarnings.add('${staff['name']}: 実音として1オクターブ下げました。');
      }
      if (!preservePageNumbers) {
        for (final measure in staff['measures'] as List) { measure['page'] = pageNumber; }
      }
      all.add(staff);
    }
    if (discardedLowerSymbols) {
      pageWarnings.add('下段と判定された記号を除外しました。複数声部の五線では音符が欠ける可能性があります。原譜を確認してください。');
    }
    final count = (all.first['measures'] as List).length;
    final countsBySystem = <Map<String, int>>[];
    final locations = <String>{};
    for (final staff in all) {
      final counts = <String, int>{};
      for (final measure in staff['measures'] as List) {
        final location = '${measure['page']}/${measure['system']}';
        counts.update(location, (value) => value + 1, ifAbsent: () => 1);
        locations.add(location);
      }
      countsBySystem.add(counts);
    }
    for (final location in locations) {
      final expected = countsBySystem.first[location] ?? 0;
      if (countsBySystem.any((counts) => (counts[location] ?? 0) != expected)) {
        final partsAtLocation = location.split('/');
        final details = [for (var part = 0; part < parts; part++)
          '${all[part]['role'] == 'piano_rh' ? 'ピアノ右手' : all[part]['role'] == 'piano_lh' ? 'ピアノ左手' : all[part]['name']} ${countsBySystem[part][location] ?? 0}小節'].join('、');
        throw FormatException('${partsAtLocation[0]}ページ・${int.parse(partsAtLocation[1]) + 1}段目で声部間の小節数が一致しません（$details）。原譜を確認して再認識してください。');
      }
    }
    final meterWarnings = inferEnsembleMeters(all);
    if (meterWarnings.isNotEmpty) {
      pageWarnings.addAll(meterWarnings);
    }
    for (final staff in all) { OmrStaffAssembler.resolveTies(staff); }
    for (var i = 0; i < count; i++) {
      if (preservePageNumbers && all.any((s) => (s['measures'] as List)[i]['page'] != (all.first['measures'] as List)[i]['page'])) {
        throw FormatException('${i + 1}小節のページ対応が声部間で一致しません。');
      }
      final expected = ((all.first['measures'] as List)[i]['time_sig'] as List).join('/');
      if (all.any((s) => ((s['measures'] as List)[i]['time_sig'] as List).join('/') != expected)) {
        throw FormatException('${i + 1}小節の拍子が声部間で一致しません。');
      }
    }
    return {
      'title': '', 'tempo_bpm': tempo, 'staves': all,
      'warnings': [...page.warnings, ...pageWarnings, for (final staff in all) ...((staff['warnings'] as List).map((w) => '${staff['name']}: $w')),
        '声部・段の配置は指定された編成に基づきます。原譜で確認してください。'],
      'meta': {'voice_count': voiceNames.length, 'piano': piano, 'pages': [pageNumber], 'experimental_omr': true,
        'postprocess': {'octave_shift_applied': octaveApplied}},
    };
  }
}

String _voiceType(String name) {
  final normalized = name.trim().toLowerCase();
  const prefixes = <String, String>{'ソプラノ': 'soprano', 'アルト': 'alto', 'テノール': 'tenor',
    'テナー': 'tenor', 'バリトン': 'baritone', 'バス': 'bass', 'mezzo': 'alto',
    'sop': 'soprano', 'alt': 'alto', 'ten': 'tenor', 'bar': 'baritone', 'bas': 'bass',
    'cantus': 'soprano', 'contralto': 'alto'};
  for (final entry in prefixes.entries) { if (normalized.startsWith(entry.key)) return entry.value; }
  return '';
}
