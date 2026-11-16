import 'dart:convert';
import 'package:choir_mobile/browser_assembly.dart';
import 'package:choir_mobile/musicxml_export.dart';
import 'package:choir_mobile/omr_bridge.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:choir_mobile/score_structure.dart';
import 'package:flutter_test/flutter_test.dart';

const _chord = OmrSymbol(rhythm: 'chord', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.');
OmrSymbol note(String rhythm, String pitch, [String slur = '_']) =>
    OmrSymbol(rhythm: rhythm, pitch: pitch, lift: '_', position: 'upper', articulation: '_', slur: slur);
OmrSymbol token(String rhythm) => OmrSymbol(rhythm: rhythm, pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.');

List<(bool, bool)> ties(Iterable events) => [for (final e in events) (e.tieStart as bool, e.tieStop as bool)];

void main() {
  test('a slur between chords sharing a pitch is a tie (piano)', () {
    final staff = staffFromSymbols([
      token('clef_G2'), token('timeSignature/4'),
      note('note_1', 'C4', 'slurStart'), _chord, note('note_1', 'E4'), token('barline'),
      note('note_1', 'C4', 'slurStop'), _chord, note('note_1', 'G4'), token('barline'),
    ]);
    expect(ties(staff.measures.expand((m) => m.events)), [(true, false), (false, true)]);
    expect(staff.measures.first.events.single.slurStarts, isEmpty);
  });

  test('MusicXML ties only the pitches two tied chords share', () {
    final staff = staffFromSymbols([
      token('clef_G2'), token('timeSignature/4'),
      note('note_1', 'C4', 'slurStart'), _chord, note('note_1', 'E4'), token('barline'),
      note('note_1', 'C4', 'slurStop'), _chord, note('note_1', 'G4'), token('barline'),
    ]);
    final xml = MusicXmlExporter().export({'title': 't', 'tempo_bpm': 80, 'staves': [staff.toJson()..['role'] = 'voice']});
    expect('<tie type="start"/>'.allMatches(xml), hasLength(1));
    expect('<tie type="stop"/>'.allMatches(xml), hasLength(1));
  });

  test('a barline tie in a system without a time signature (2/4)', () {
    // No time signature token: the bar is read as 4/4, but its notes fill 2/4.
    final staff = staffFromSymbols([
      token('clef_G2'),
      note('note_2', 'A4', 'slurStart'), token('barline'),
      note('note_2', 'A4', 'slurStop'), token('barline'),
    ]);
    expect(ties(staff.measures.expand((m) => m.events)), [(true, false), (false, true)]);
  });

  RecognizedPageSymbols page(int number, List<OmrSymbol> symbols) => RecognizedPageSymbols(
    staves: [RecognizedStaffSymbols(crop: const [250, 360, 1800, 490], lines: [for (var i = 0; i < 5; i++) 400 + i * 10.0],
      left: 300, right: 1750, reachedEos: true, symbols: [token('clef_G2'), token('timeSignature/4'), ...symbols])],
    warnings: const [], width: 1920, height: 2800, pageNumber: number, systems: const [SystemLayout([0])]);

  Map<String, dynamic> assemble(String nextPitch) => assembleLikeBrowser([
    page(1, [note('note_1', 'C5'), token('barline'), note('note_1', 'C5', 'slurStart'), token('barline')]),
    page(2, [note('note_1', nextPitch, 'slurStop'), token('barline'), note('note_1', 'D5'), token('barline')]),
  ], layout: EnsembleLayout(voiceNames: ['Soprano'], piano: false)).json;

  List<(bool, bool)> jsonTies(Map<String, dynamic> score) => [
    for (final m in (score['staves'] as List).first['measures'] as List)
      for (final e in m['events'] as List) (e['tie_start'] == true, e['tie_stop'] == true)];

  test('a tie across a system break is joined', () {
    final score = assemble('C5');
    expect(jsonTies(score), [(false, false), (true, false), (false, true), (false, false)]);
    expect(jsonEncode(score), isNot(contains('~open')));
  });

  test('an open slur onto a different pitch stays a (dropped) slur end', () {
    final score = assemble('E5');
    expect(jsonTies(score), everyElement((false, false)));
    expect(jsonEncode(score), isNot(contains('~open')));
  });
}
