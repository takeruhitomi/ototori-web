import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/browser_assembly.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:choir_mobile/score_ir.dart';
import 'package:choir_mobile/score_postprocess.dart';
import 'package:choir_mobile/score_structure.dart';
import 'package:flutter_test/flutter_test.dart';

// Differential check of the Dart structure/postprocess ports against the PC
// back end on identical per-system tokens. Fixtures stay outside git:
// MOBILE_PARITY_FIXTURES=<dir with <song>.json from work/parity-exp/dump_fixtures.py>.
void main() {
  final dir = Platform.environment['MOBILE_PARITY_FIXTURES'];
  test('structure and postprocess match the PC back end', () {
    final lines = <String>[];
    for (final file in Directory(dir!).listSync().whereType<File>().where((f) => f.path.endsWith('.json') && !f.path.contains('.dart-'))) {
      final name = file.uri.pathSegments.last.replaceAll('.json', '');
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final units = <Unit?>[];
      for (final u in data['units'] as List) {
        final staves = <Staff>[];
        for (final (j, entry) in (u['staves'] as List).indexed) {
          final tokens = [for (final t in entry['tokens'] as List) OmrSymbol.fromList(t as List)];
          try {
            staves.add(staffFromSymbols(tokens, id: 'S${j + 1}'));
          } on FormatException {
            staves.add(Staff(id: 'S${j + 1}'));
          }
        }
        final pair = u['piano_pair'] as List?;
        final hasBrace = u['has_brace'] == true;
        final n = u['n'] as int;
        units.add(Unit(staves, page: u['page'] as int, system: u['system'] as int,
          pianoOnly: n == 2 && hasBrace ? true : null,
          pianoPair: hasBrace && pair != null && staves.length == n ? (pair[0] as int, pair[1] as int) : null));
      }
      final score = assembleUnits(units);
      final pyAssembled = Score.fromJson(data['assembled'] as Map);
      lines.add('$name assembled: dart ${score.meta['ensemble']} ${score.measureCount()} measures '
        '${score.staves.map((s) => s.name).join('/')} | py ${pyAssembled.meta['ensemble']} ${pyAssembled.measureCount()}');
      lines.add('   assembled diff: ${_diff(score, pyAssembled)}');
      final ens = '${score.meta['ensemble']}';
      postprocessScore(score, PostOptions(ensemble: ens == 'auto' || ens == 'custom' ? '' : ens));
      final pyPost = Score.fromJson(data['post'] as Map);
      lines.add('   post diff: ${_diff(score, pyPost)}  meta dart ${jsonEncode(_metaCounts(score))} py ${jsonEncode(_metaCounts(pyPost))}');
      File('${file.parent.path}/$name.dart-post.json').writeAsStringSync(jsonEncode(score.toJson()));
    }
    File('$dir/backend-report.txt').writeAsStringSync('${lines.join('\n')}\n');
    // ignore: avoid_print
    print(lines.join('\n'));
  }, skip: dir == null ? 'Set MOBILE_PARITY_FIXTURES' : false);
}

Map<String, dynamic> _metaCounts(Score s) {
  final m = Map<String, dynamic>.from((s.meta['postprocess'] as Map?) ?? {});
  m.remove('steps');
  return m;
}

String _diff(Score a, Score b) {
  if (a.staves.length != b.staves.length) return 'staves ${a.staves.length} vs ${b.staves.length}';
  var differing = 0, total = 0;
  final examples = <String>[];
  for (var s = 0; s < a.staves.length; s++) {
    final ma = a.staves[s].measures, mb = b.staves[s].measures;
    if (ma.length != mb.length) return 'staff ${s + 1} measures ${ma.length} vs ${mb.length}';
    for (var i = 0; i < ma.length; i++) {
      total++;
      String key(NoteEvent e) => '${e.onset}|${e.duration}|${e.pitches.join(',')}|${e.grace}';
      final ea = [for (final e in ma[i].events) key(e)]..sort();
      final eb = [for (final e in mb[i].events) key(e)]..sort();
      final same = ea.join(';') == eb.join(';') && ma[i].timeSig == mb[i].timeSig && ma[i].keyFifths == mb[i].keyFifths;
      if (!same) {
        differing++;
        if (examples.length < 3) examples.add('S${s + 1} m${i + 1} ts ${ma[i].timeSig}/${mb[i].timeSig}\n      d ${ea.join(' ; ')}\n      p ${eb.join(' ; ')}');
      }
    }
  }
  return '$differing/$total measures differ${examples.isEmpty ? '' : '\n    ${examples.join('\n    ')}'}';
}
