import 'package:choir_mobile/omr_bridge.dart';
import 'package:choir_mobile/omr_page_assembler.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:flutter_test/flutter_test.dart';

OmrSymbol note(String pitch) => OmrSymbol(rhythm: 'note_4', pitch: pitch, lift: '_', position: 'upper', articulation: '_', slur: '_');
const bar = OmrSymbol(rhythm: 'barline', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.');
RecognizedStaffSymbols staff(List<OmrSymbol> symbols, {bool eos = true}) => RecognizedStaffSymbols(symbols: symbols, reachedEos: eos, crop: const [0, 0, 100, 50]);
RecognizedPageSymbols page(List<RecognizedStaffSymbols> staves) => RecognizedPageSymbols(staves: staves, warnings: const [], width: 1920, height: 2400);

void main() {
  test('aligns a longer bar across the ensemble without shifting the next bar early', () {
    final data = page([for (final pitch in ['C4', 'E4'])
      staff([...List.generate(5, (_) => note(pitch)), bar, ...List.generate(4, (_) => note(pitch)), bar])]);
    final result = OmrPageAssembler().assemble(data, pageNumber: 1, voiceNames: ['Soprano', 'Alto'], piano: false);
    for (final staff in result['staves']) {
      expect(staff['measures'][0]['time_sig'], [5, 4]);
      expect(staff['measures'][1]['time_sig'], [4, 4]);
    }
    expect((result['warnings'] as List).any((w) => '$w'.contains('5/4')), true);
  });
  test('assembles pages continuously with page origins and carried key and clef', () {
    const clef = OmrSymbol(rhythm: 'clef_G2', pitch: '.', lift: '.', position: 'upper', articulation: '.', slur: '.');
    const key = OmrSymbol(rhythm: 'keySignature_2', pitch: '.', lift: '.', position: 'upper', articulation: '.', slur: '.');
    final first = page([staff([clef, key, note('C4'), bar])]);
    final second = page([staff([note('D4'), bar])]);
    final result = OmrPageAssembler().assemblePages([first, second], voiceNames: ['Tenor'], piano: false);
    final measures = result['staves'][0]['measures'] as List;
    expect(measures.map((m) => m['number']), [1, 2]);
    expect(measures.map((m) => m['page']), [1, 2]);
    expect(measures.map((m) => m['key_fifths']), [2, 2]);
    expect(measures[1]['clef'], 'G8vb');
    expect(measures[1]['events'][0]['pitches'], [50]);
    expect(result['meta']['pages'], [1, 2]);
    expect(measures.map((m) => m['system']), [0, 0]);
    expect(result['meta']['layout']['pages'][1]['page'], 2);
    expect(result['meta']['layout']['pages'][0]['systems'][0]['x1'], 100);
  });
  test('keeps each page system and its physical bounds for source tap seeking', () {
    final result = OmrPageAssembler().assemblePages([page([
      const RecognizedStaffSymbols(symbols: [
        OmrSymbol(rhythm: 'note_4', pitch: 'C4', lift: '_', position: 'upper', articulation: '_', slur: '_'),
        bar,
      ], reachedEos: true, crop: [10, 20, 100, 60], left: 15, right: 95),
      const RecognizedStaffSymbols(symbols: [
        OmrSymbol(rhythm: 'note_4', pitch: 'D4', lift: '_', position: 'upper', articulation: '_', slur: '_'),
        bar,
      ], reachedEos: true, crop: [10, 120, 100, 160], left: 15, right: 95),
    ])], voiceNames: ['Soprano'], piano: false);
    expect((result['staves'][0]['measures'] as List).map((m) => m['system']), [0, 1]);
    expect(result['meta']['layout']['pages'][0]['systems'][1],
      {'index': 1, 'x0': 15, 'x1': 95, 'y0': 120, 'y1': 160});
  });

  test('rejects a page with a missing part even if total staff count fits', () {
    expect(() => OmrPageAssembler().assemblePages([
      page([staff([note('C4')])]), page([staff([note('D4')])]),
    ], voiceNames: ['Soprano', 'Alto'], piano: false), throwsFormatException);
  });

  test('preserves a tie spanning a page boundary', () {
    OmrSymbol tied(String slur) => OmrSymbol(rhythm: 'note_1', pitch: 'C4', lift: '_', position: 'upper', articulation: '_', slur: slur);
    final result = OmrPageAssembler().assemblePages([
      page([staff([tied('slurStart'), bar])]),
      page([staff([tied('slurStop'), bar])]),
    ], voiceNames: ['Soprano'], piano: false);
    final measures = result['staves'][0]['measures'] as List;
    expect(measures[0]['events'][0]['tie_start'], true);
    expect(measures[1]['events'][0]['tie_stop'], true);
  });

  test('rejects shifted page alignment despite matching total measure counts', () {
    expect(() => OmrPageAssembler().assemblePages([
      page([staff([note('C4'), bar, note('D4'), bar]), staff([note('E4'), bar])]),
      page([staff([note('C4'), bar]), staff([note('E4'), bar, note('F4'), bar])]),
    ], voiceNames: ['Soprano', 'Alto'], piano: false), throwsFormatException);
  });

  test('rejects shifted systems on the same page despite equal totals', () {
    final data = page([
      staff([note('C4'), bar, note('D4'), bar]), staff([note('E4'), bar]),
      staff([note('C4'), bar]), staff([note('E4'), bar, note('F4'), bar]),
    ]);
    for (final continuous in [false, true]) {
      expect(() => continuous
        ? OmrPageAssembler().assemblePages([data], voiceNames: ['Soprano', 'Alto'], piano: false)
        : OmrPageAssembler().assemble(data, pageNumber: 6, voiceNames: ['Soprano', 'Alto'], piano: false),
        throwsA(isA<FormatException>().having((e) => e.message, 'diagnostic',
          allOf(contains('1段目'), contains('Soprano 2小節'), contains('Alto 1小節')))));
    }
  });

  test('aligns fixed ensemble systems and preserves both piano staves', () {
    final result = OmrPageAssembler().assemble(page([
      staff([note('C4'), bar]), staff([note('E4'), bar]), staff([note('C5'), bar]), staff([note('C3'), bar]),
      staff([note('D4'), bar]), staff([note('F4'), bar]), staff([note('D5'), bar]), staff([note('D3'), bar]),
    ]), pageNumber: 2, voiceNames: ['Soprano', 'Alto'], piano: true);
    final staves = result['staves'] as List;
    expect(staves.map((s) => s['role']).toList(), ['voice', 'voice', 'piano_rh', 'piano_lh']);
    expect((staves[0]['measures'] as List).length, 2);
    expect(staves[0]['measures'][1]['events'][0]['pitches'], [62]);
    expect(staves[2]['measures'][0]['events'][0]['pitches'], [72]);
    expect(staves[3]['measures'][0]['events'][0]['pitches'], [48]);
    expect(staves[0]['measures'][0]['page'], 2);
  });

  test('rejects mismatched layout and truncated decoder results', () {
    expect(() => OmrPageAssembler().assemble(page([staff([note('C4')])]), pageNumber: 1, voiceNames: ['A', 'B'], piano: false), throwsFormatException);
    expect(() => OmrPageAssembler().assemble(page([staff([note('C4')], eos: false)]), pageNumber: 1, voiceNames: ['A'], piano: false), throwsFormatException);
  });

  test('rejects mismatched measure counts rather than inventing bars', () {
    final data = page([staff([note('C4'), bar, note('D4')]), staff([note('E4')])]);
    expect(() => OmrPageAssembler().assemble(data, pageNumber: 1, voiceNames: ['A', 'B'], piano: false), throwsFormatException);
  });

  test('transposes a tenor in treble clef once and records the applied shift', () {
    const clef = OmrSymbol(rhythm: 'clef_G2', pitch: '.', lift: '.', position: 'upper', articulation: '.', slur: '.');
    final result = OmrPageAssembler().assemble(page([staff([clef, note('C4'), bar])]), pageNumber: 1, voiceNames: ['Tenor I'], piano: false);
    final staffResult = (result['staves'] as List).single;
    expect(staffResult['measures'][0]['events'][0]['pitches'], [48]);
    expect(staffResult['clef'], 'G8vb');
    expect(result['meta']['postprocess']['octave_shift_applied'], {'S1': -1});
  });
}
