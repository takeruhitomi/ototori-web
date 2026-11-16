import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/omr_staff_assembler.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('supported staff symbols match homr MusicXML and PC score import', () {
    final cases = jsonDecode(File('test/fixtures/homr_staff.json').readAsStringSync()) as Map<String, dynamic>;
    expect(cases, isNotEmpty);
    for (final entry in cases.entries) {
      final source = (entry.value['symbols'] as List).map((s) => OmrSymbol.fromList(s as List)).toList();
      final result = OmrStaffAssembler().assemble(source);
      final expected = entry.value['measures'] as List;
      final actual = result['measures'] as List;
      expect(actual.length, expected.length, reason: entry.key);
      for (var i = 0; i < expected.length; i++) {
        for (final key in ['time_sig', 'key_fifths', 'clef', 'repeat_start', 'repeat_end']) {
          expect(actual[i][key], expected[i][key], reason: '${entry.key} measure $i $key');
        }
        final events = actual[i]['events'] as List;
        final reference = expected[i]['events'] as List;
        expect(events.length, reference.length, reason: '${entry.key} measure $i');
        for (var j = 0; j < reference.length; j++) {
          for (final key in ['onset', 'duration', 'pitches', 'grace', 'tie_start', 'tie_stop', 'voice']) {
            expect(events[j][key], reference[j][key], reason: '${entry.key} measure $i event $j $key');
          }
        }
      }
    }
  });

  test('unsupported numbered ending notation is rejected', () {
    const note = OmrSymbol(rhythm: 'note_4', pitch: 'C4', lift: '_', position: 'upper', articulation: '_', slur: '_');
    const ending = OmrSymbol(rhythm: 'voltaStart', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.');
    expect(() => OmrStaffAssembler().assemble([note, ending]), throwsFormatException);
  });

  test('simultaneous pitched note and rest retain separate voices and timing', () {
    final symbols = [
      ['note_8', 'C4', '#', 'upper', '_', '_'],
      ['chord', '.', '.', '.', '.', '.'],
      ['rest_8', '_', '_', 'upper', '_', '_'],
      ['note_8', 'D4', '_', 'upper', '_', '_'],
    ].map(OmrSymbol.fromList).toList();
    final result = OmrStaffAssembler().assemble(symbols);
    final events = result['measures'][0]['events'] as List;
    expect(events, hasLength(3));
    expect(events[0]['pitches'], [61]);
    expect(events[1]['pitches'], isEmpty);
    expect(events[0]['onset'], '0/1');
    expect(events[1]['onset'], '0/1');
    expect(events[0]['duration'], '1/2');
    expect(events[1]['duration'], '1/2');
    expect(events[0]['voice'], isNot(events[1]['voice']));
    expect(events[2]['onset'], '1/2');
    expect(events[2]['pitches'], [62]);
    expect(result['warnings'], isNotEmpty);
  });

  test('duplicate slur starts retain the first endpoint without inventing a tie', () {
    OmrSymbol note(String pitch, String slur) => OmrSymbol(rhythm: 'note_4', pitch: pitch, lift: '_', position: 'upper', articulation: '_', slur: slur);
    final result = OmrStaffAssembler().assemble([note('C4', 'slurStart'), note('D4', 'slurStart'), note('E4', 'slurStop')]);
    expect(result['warnings'], isNotEmpty);
    final events = result['measures'][0]['events'] as List;
    expect(events.first['slur_starts'], hasLength(1));
    expect(events.first['tie_start'], false);
    expect(events[1]['slur_starts'], isEmpty);
    expect(events.first['slur_starts'], events[2]['slur_stops']);
  });
}
