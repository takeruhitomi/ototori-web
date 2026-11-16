import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/musicxml_export.dart';
import 'package:choir_mobile/omr_staff_assembler.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports notation reference scores for independent MusicXML import', () {
    final cases = jsonDecode(File('test/fixtures/homr_staff.json').readAsStringSync()) as Map;
    final target = Directory('.dart_tool/musicxml-export-check')..createSync(recursive: true);
    for (final entry in cases.entries) {
      final staff = OmrStaffAssembler().assemble((entry.value['symbols'] as List).map((s) => OmrSymbol.fromList(s)).toList());
      final score = <String, dynamic>{'title': 'Test & <title>', 'tempo_bpm': 80, 'staves': [staff]};
      final xml = MusicXmlExporter().export(score);
      expect(xml, contains('Test &amp; &lt;title&gt;'));
      File('${target.path}/${entry.key}.musicxml').writeAsStringSync(xml);
      File('${target.path}/${entry.key}.json').writeAsStringSync(jsonEncode(score));
      if (entry.key == 'mixed_duration_chord') {
        final repeated = jsonDecode(jsonEncode(staff)) as Map<String, dynamic>;
        final original = (repeated['measures'] as List).single;
        repeated['measures'] = List.generate(3, (i) => {
          ...jsonDecode(jsonEncode(original)) as Map<String, dynamic>,
          'number': i + 1, 'repeat_start': i == 0, 'repeat_end': i == 1 ? 2 : 0,
          'ending_numbers': i == 0 ? <int>[] : [i],
        });
        final endings = <String, dynamic>{'title': 'Endings', 'tempo_bpm': 80, 'staves': [repeated]};
        File('${target.path}/endings.musicxml').writeAsStringSync(MusicXmlExporter().export(endings));
        File('${target.path}/endings.json').writeAsStringSync(jsonEncode(endings));
      }
    }
  });
}
