import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/omr_staff_assembler.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:flutter_test/flutter_test.dart';

// Differential check against the PC path homr MusicXML -> choir_omr import.
// Fixtures stay outside git: MOBILE_PARITY_FIXTURES=<dir with <song>.json>.
void main() {
  final dir = Platform.environment['MOBILE_PARITY_FIXTURES'];
  test('per-system staff conversion matches the PC importer', () {
    var total = 0, bad = 0;
    final report = <String>[];
    for (final file in Directory(dir!).listSync().whereType<File>().where((f) => f.path.endsWith('.json'))) {
      final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final unit in data['units'] as List) {
        for (final (i, entry) in (unit['staves'] as List).indexed) {
          total++;
          final tokens = [for (final t in entry['tokens'] as List) OmrSymbol.fromList(t as List)];
          final upper = <OmrSymbol>[];
          for (final group in groupOmrChords(tokens)) {
            final kept = group.where((s) => s.position != 'lower').toList();
            for (var k = 0; k < kept.length; k++) {
              if (k > 0) upper.add(const OmrSymbol(rhythm: 'chord', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'));
              upper.add(kept[k]);
            }
          }
          final label = '${file.uri.pathSegments.last} p${unit['page']} s${unit['system']} staff $i';
          Map<String, dynamic> mine;
          try {
            mine = OmrStaffAssembler().assemble(upper);
          } catch (e) {
            bad++; report.add('$label: dart error $e'); continue;
          }
          final py = entry['staff'] as Map<String, dynamic>;
          final diff = _diff(mine, py);
          if (diff != null) { bad++; report.add('$label: $diff'); }
        }
      }
    }
    File('$dir/staff-conversion-report.txt').writeAsStringSync('$bad/$total differ\n${report.join('\n')}\n');
    // ignore: avoid_print
    print('$bad/$total staves differ');
  }, skip: dir == null ? 'Set MOBILE_PARITY_FIXTURES' : false);
}

String? _diff(Map<String, dynamic> a, Map<String, dynamic> b) {
  final ma = a['measures'] as List, mb = b['measures'] as List;
  if (ma.length != mb.length) return 'measures ${ma.length} vs ${mb.length}';
  for (var i = 0; i < ma.length; i++) {
    for (final key in ['time_sig', 'key_fifths', 'clef', 'repeat_start', 'repeat_end']) {
      if (jsonEncode(ma[i][key]) != jsonEncode(mb[i][key])) return 'm${i + 1} $key ${ma[i][key]} vs ${mb[i][key]}';
    }
    String key(dynamic e) => '${_frac(e['onset'])}|${_frac(e['duration'])}|${(e['pitches'] as List).join(',')}|${e['voice']}|${e['grace']}|${e['tie_start']}|${e['tie_stop']}';
    final ea = [for (final e in ma[i]['events'] as List) key(e)]..sort();
    final eb = [for (final e in mb[i]['events'] as List) key(e)]..sort();
    if (ea.join(';') != eb.join(';')) return 'm${i + 1} events\n   dart ${ea.join(' ; ')}\n   py   ${eb.join(' ; ')}';
  }
  return null;
}

String _frac(dynamic v) {
  final p = '$v'.split('/');
  final f = BeatFraction(int.parse(p[0]), p.length > 1 ? int.parse(p[1]) : 1);
  return f.toString();
}
