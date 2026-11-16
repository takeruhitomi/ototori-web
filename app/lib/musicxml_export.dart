import 'omr_symbols.dart';
import 'dart:convert';
import 'repeat_plan.dart';

/// Written-order MusicXML; pitch values remain sounding MIDI values as in IR.
class MusicXmlExporter {
  String export(Map<String, dynamic> score) {
    final override = (score['meta'] as Map?)?['repeat_override'];
    if (override is List || (score['meta'] as Map?)?['repeats_enabled'] == false) {
      final plan = RepeatPlanner().build(score);
      if (!plan.valid) throw const FormatException('反復設定を確認してから MusicXML を書き出してください。');
      score = jsonDecode(jsonEncode(score)) as Map<String, dynamic>;
      for (final staff in score['staves'] as List) {
        for (final m in staff['measures'] as List) {
          m['repeat_start'] = false; m['repeat_end'] = 0; m['ending_numbers'] = <int>[];
        }
        if ((score['meta'] as Map?)?['repeats_enabled'] != false && override is List) {
          final measures = staff['measures'] as List;
          for (final r in override) {
            if ((r['end'] as int) > measures.length) continue;
            measures[(r['start'] as int) - 1]['repeat_start'] = true;
            measures[(r['end'] as int) - 1]['repeat_end'] = r['times'];
            for (final e in r['endings'] as List? ?? []) {
              for (var i = (e['start'] as int) - 1; i < (e['end'] as int) && i < measures.length; i++) {
                measures[i]['ending_numbers'] = List<int>.from(e['passes'] as List);
              }
            }
          }
        }
      }
    }
    final staves = (score['staves'] as List).cast<Map>();
    if (staves.isEmpty) throw const FormatException('声部がありません。');
    var divisions = 1;
    for (final s in staves) {
      for (final m in s['measures'] as List) {
        for (final e in m['events'] as List) {
          for (final key in ['onset', 'duration']) {
            final f = _fraction(e[key]);
            if (f.numerator < 0) throw const FormatException('拍位置・音価が不正です。');
            divisions = divisions ~/ divisions.gcd(f.denominator) * f.denominator;
            if (divisions > 1000000) throw const FormatException('音価の分母が複雑すぎます。');
          }
        }
      }
    }
    int ticks(dynamic value) {
      final f = _fraction(value);
      return f.numerator * divisions ~/ f.denominator;
    }
    final parts = <List<Map>>[];
    final piano = staves.where((s) => ['piano_rh', 'piano_lh'].contains(s['role'])).toList();
    for (final s in staves) {
      if (piano.contains(s)) {
        if (identical(s, piano.first)) parts.add(piano);
      } else { parts.add([s]); }
    }
    if (piano.length > 2) throw const FormatException('ピアノの段数が不正です。');
    final out = StringBuffer('<?xml version="1.0" encoding="utf-8"?><score-partwise version="4.0">');
    out.write('<work><work-title>${_xml(score['title'] ?? '')}</work-title></work><part-list>');
    for (var p = 0; p < parts.length; p++) {
      final isPiano = ['piano_rh', 'piano_lh'].contains(parts[p].first['role']);
      final program = isPiano ? 0 : (parts[p].first['midi_program'] as int? ?? 52);
      if (program < 0 || program > 127 || p >= 15) throw const FormatException('MusicXML の音色・パート数が不正です。');
      out.write('<score-part id="P${p + 1}"><part-name>${_xml(parts[p].first['name'] ?? '声部 ${p + 1}')}</part-name>');
      out.write('<score-instrument id="I${p + 1}"><instrument-name>${isPiano ? 'Piano' : 'Choir'}</instrument-name></score-instrument>');
      out.write('<midi-instrument id="I${p + 1}"><midi-channel>${p < 9 ? p + 1 : p + 2}</midi-channel><midi-program>${program + 1}</midi-program></midi-instrument></score-part>');
    }
    out.write('</part-list>');
    for (var p = 0; p < parts.length; p++) {
      final group = parts[p];
      final count = (group.first['measures'] as List).length;
      if (group.any((s) => (s['measures'] as List).length != count)) throw const FormatException('ピアノ上下段の小節数が一致しません。');
      // Allocate notation numbers by musical time, independently of the XML
      // serialization order of voices and the piano's two staves.
      final spans = <String, List<(int, int)?>>{};
      final slurStaff = <String, int>{};
      for (final staff in group) {
        for (var i = 0; i < count; i++) {
          for (final event in staff['measures'][i]['events'] as List) {
            for (final kind in ['starts', 'stops']) {
              for (final id in event['slur_$kind'] as List? ?? []) {
                spans.putIfAbsent('$id', () => [null, null])[kind == 'starts' ? 0 : 1] = (i, ticks(event['onset']));
                slurStaff['$id'] = group.indexOf(staff);
              }
            }
          }
        }
      }
      int compare((int, int) a, (int, int) b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2);
      final orderedSpans = spans.entries.where((e) => e.value[0] != null && e.value[1] != null).toList()
        ..sort((a, b) => compare(a.value[0]!, b.value[0]!));
      final active = <int, (int, int)>{};
      final slurs = <String, int>{};
      for (final span in orderedSpans) {
        active.removeWhere((_, end) => compare(end, span.value[0]!) <= 0);
        final range = 16 ~/ group.length;
        final base = slurStaff[span.key]! * range;
        var number = base + 1;
        while (active.containsKey(number)) { number++; }
        if (number > base + range) throw const FormatException('スラーの重なりが多すぎます。');
        slurs[span.key] = number; active[number] = span.value[1]!;
      }
      final tied = _tiedPitches(group, ticks);
      out.write('<part id="P${p + 1}">');
      for (var m = 0; m < count; m++) {
        final measures = group.map((s) => s['measures'][m] as Map).toList();
        final reference = measures.first;
        final time = reference['time_sig'] as List? ?? [4, 4];
        out.write('<measure number="${m + 1}"><attributes><divisions>$divisions</divisions>');
        for (var s = 0; s < group.length; s++) {
          out.write('<key number="${s + 1}"><fifths>${measures[s]['key_fifths'] ?? 0}</fifths></key>');
        }
        out.write('<time><beats>${time[0]}</beats><beat-type>${time[1]}</beat-type></time>');
        if (group.length > 1) out.write('<staves>${group.length}</staves>');
        for (var s = 0; s < group.length; s++) {
          final clef = '${measures[s]['clef'] ?? group[s]['clef'] ?? 'G'}';
          final sign = clef.startsWith('F') ? 'F' : clef.startsWith('C') ? 'C' : 'G';
          out.write('<clef number="${s + 1}"><sign>$sign</sign><line>${sign == 'F' ? 4 : sign == 'C' ? 3 : 2}</line>');
          if (clef.contains('8vb')) out.write('<clef-octave-change>-1</clef-octave-change>');
          if (clef.contains('8va')) out.write('<clef-octave-change>1</clef-octave-change>');
          out.write('</clef>');
        }
        out.write('</attributes>');
        if (m == 0) out.write('<direction><direction-type><words>Tempo</words></direction-type><sound tempo="${score['tempo_bpm'] ?? 80}"/></direction>');
        final ending = (reference['ending_numbers'] as List? ?? []).join(',');
        final previousEnding = m == 0 ? '' : ((group.first['measures'][m - 1]['ending_numbers'] as List?) ?? []).join(',');
        final nextEnding = m + 1 == count ? '' : ((group.first['measures'][m + 1]['ending_numbers'] as List?) ?? []).join(',');
        if (measures.any((v) => v['repeat_start'] == true) || (ending.isNotEmpty && ending != previousEnding)) {
          out.write('<barline location="left">');
          if (ending.isNotEmpty && ending != previousEnding) out.write('<ending number="${_xml(ending)}" type="start"/>');
          if (measures.any((v) => v['repeat_start'] == true)) out.write('<repeat direction="forward"/>');
          out.write('</barline>');
        }
        var cursor = 0;
        for (var s = 0; s < group.length; s++) {
          final events = (measures[s]['events'] as List).cast<Map>();
          final voices = events.map((e) => e['voice'] as int? ?? 0).toSet().toList()..sort();
          for (final voice in voices) {
            if (cursor > 0) out.write('<backup><duration>$cursor</duration></backup>');
            cursor = 0;
            final layer = events.where((e) => (e['voice'] ?? 0) == voice).toList()
              ..sort((a, b) {
                final position = ticks(a['onset']).compareTo(ticks(b['onset']));
                if (position != 0) return position;
                if ((a['grace'] == true) != (b['grace'] == true)) return a['grace'] == true ? -1 : 1;
                return (a['grace_index'] as int? ?? 0).compareTo(b['grace_index'] as int? ?? 0);
              });
            for (final event in layer) {
              final onset = ticks(event['onset']), duration = ticks(event['duration']);
              final grace = event['grace'] == true;
              if (!grace && duration <= 0) throw const FormatException('音価がゼロです。');
              if (onset < cursor) throw const FormatException('同じ声部の音符が重なっています。');
              if (onset > cursor) out.write('<forward><duration>${onset - cursor}</duration></forward>');
              cursor = onset;
              final pitches = (event['pitches'] as List).cast<int>();
              final slurTags = StringBuffer();
              for (final id in event['slur_stops'] as List? ?? []) {
                final number = slurs['$id'];
                if (number != null) slurTags.write('<slur type="stop" number="$number"/>');
              }
              for (final id in event['slur_starts'] as List? ?? []) {
                final number = slurs['$id'];
                if (number != null) slurTags.write('<slur type="start" number="$number"/>');
              }
              for (var i = 0; i < (pitches.isEmpty ? 1 : pitches.length); i++) {
                out.write('<note>');
                if (grace) out.write('<grace/>');
                if (i > 0) out.write('<chord/>');
                if (pitches.isEmpty) { out.write('<rest/>'); } else {
                  final pitch = pitches[i];
                  const steps = ['C', 'C', 'D', 'D', 'E', 'F', 'F', 'G', 'G', 'A', 'A', 'B'];
                  final sharp = [1, 3, 6, 8, 10].contains(pitch % 12);
                  out.write('<pitch><step>${steps[pitch % 12]}</step>${sharp ? '<alter>1</alter>' : ''}<octave>${pitch ~/ 12 - 1}</octave></pitch>');
                }
                if (!grace) out.write('<duration>$duration</duration>');
                // A chord tie covers only the pitches the two chords share.
                bool tie(String type) => event['tie_$type'] == true && pitches.isNotEmpty &&
                    (tied[event]?[type == 'start' ? 0 : 1]?.contains(pitches[i]) ?? true);
                for (final type in ['stop', 'start']) {
                  if (tie(type)) out.write('<tie type="$type"/>');
                }
                out.write('<voice>${s * 100 + voice + 1}</voice>${_noteType(grace && duration == 0 ? BeatFraction(1, 2) : _fraction(event['duration']))}<staff>${s + 1}</staff>');
                out.write('<notations>');
                for (final type in ['stop', 'start']) {
                  if (tie(type)) out.write('<tied type="$type"/>');
                }
                if (i == 0) out.write(slurTags);
                out.write('</notations></note>');
              }
              if (!grace) cursor += duration;
            }
          }
        }
        final repeat = measures.map((v) => v['repeat_end'] as int? ?? 0).fold(0, (int a, int b) => a > b ? a : b);
        if (repeat > 0 || (ending.isNotEmpty && ending != nextEnding)) {
          out.write('<barline location="right">');
          if (ending.isNotEmpty && ending != nextEnding) out.write('<ending number="${_xml(ending)}" type="${repeat > 0 ? 'stop' : 'discontinue'}"/>');
          if (repeat > 0) out.write('<repeat direction="backward" times="$repeat"/>');
          out.write('</barline>');
        }
        out.write('</measure>');
      }
      out.write('</part>');
    }
    out.write('</score-partwise>');
    return out.toString();
  }
}

String _xml(Object value) => '$value'.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&apos;');
BeatFraction _fraction(dynamic value) {
  final parts = '$value'.split('/');
  if (parts.length == 1) return BeatFraction(int.parse(parts[0]), 1);
  if (parts.length == 2) return BeatFraction(int.parse(parts[0]), int.parse(parts[1]));
  throw const FormatException('音価の形式が不正です。');
}
/// For each tied event pair (consecutive notes of one voice, the first with
/// tie_start, the second with tie_stop): the shared pitches, as
/// [start pitches, stop pitches]. Unpaired tie flags are not listed.
Map<Map, List<Set<int>?>> _tiedPitches(List<Map> group, int Function(Object?) ticks) {
  final out = Map<Map, List<Set<int>?>>.identity();
  for (final staff in group) {
    final byVoice = <int, List<Map>>{};
    for (final measure in staff['measures'] as List) {
      final events = [for (final e in (measure as Map)['events'] as List) if (e['grace'] != true && (e['pitches'] as List).isNotEmpty) e as Map]
        ..sort((a, b) => ticks(a['onset']).compareTo(ticks(b['onset'])));
      for (final e in events) { byVoice.putIfAbsent(e['voice'] as int? ?? 0, () => []).add(e); }
    }
    for (final seq in byVoice.values) {
      for (var i = 0; i + 1 < seq.length; i++) {
        final a = seq[i], b = seq[i + 1];
        if (a['tie_start'] != true || b['tie_stop'] != true) continue;
        final shared = (a['pitches'] as List).cast<int>().toSet().intersection((b['pitches'] as List).cast<int>().toSet());
        out.putIfAbsent(a, () => [null, null])[0] = shared;
        out.putIfAbsent(b, () => [null, null])[1] = shared;
      }
    }
  }
  return out;
}

String _noteType(BeatFraction duration) {
  const types = ['whole', 'half', 'quarter', 'eighth', '16th', '32nd', '64th', '128th'];
  for (var i = 0; i < types.length; i++) {
    final base = BeatFraction(4, 1 << i);
    for (var dots = 0; dots <= 2; dots++) {
      if (duration == base * BeatFraction((1 << (dots + 1)) - 1, 1 << dots)) {
        return '<type>${types[i]}</type>${List.filled(dots, '<dot/>').join()}';
      }
    }
  }
  return '<type>quarter</type><time-modification><actual-notes>${duration.denominator}</actual-notes><normal-notes>${duration.numerator}</normal-notes></time-modification>';
}
