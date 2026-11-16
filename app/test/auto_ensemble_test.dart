import 'package:choir_mobile/auto_ensemble.dart';
import 'package:choir_mobile/omr_bridge.dart';
import 'package:choir_mobile/omr_page_assembler.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:flutter_test/flutter_test.dart';

RecognizedStaffSymbols physical(String clef, int top, {String pitch = 'C5', bool chord = false}) => RecognizedStaffSymbols(
  crop: [250, top - 40, 1800, top + 90], lines: [for (var i = 0; i < 5; i++) top + i * 10.0], left: 300, right: 1750,
  reachedEos: true, symbols: [
    OmrSymbol(rhythm: 'clef_${clef == 'G' ? 'G2' : 'F4'}', pitch: '.', lift: '.', position: 'upper', articulation: '.', slur: '.'),
    const OmrSymbol(rhythm: 'timeSignature/4', pitch: '.', lift: '.', position: 'upper', articulation: '.', slur: '.'),
    OmrSymbol(rhythm: 'note_1', pitch: pitch, lift: '.', position: 'upper', articulation: '.', slur: '.'),
    if (chord) ...[
      const OmrSymbol(rhythm: 'chord', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'),
      const OmrSymbol(rhythm: 'note_1', pitch: 'E5', lift: '.', position: 'upper', articulation: '.', slur: '.'),
    ],
    const OmrSymbol(rhythm: 'barline', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'),
  ],
);
RecognizedTextLabel label(String text, int top) => RecognizedTextLabel(text, [80, top + 5, 285, top + 35]);
RecognizedPageSymbols page(List<RecognizedStaffSymbols> staves, List<RecognizedTextLabel> labels, int number) =>
  RecognizedPageSymbols(staves: staves, labels: labels, warnings: [], width: 1920, height: 2800, pageNumber: number);

void main() {
  test('detects a scanned TTBB quartet with no piano and different systems per page', () {
    final first = page([physical('G', 1600), physical('G', 1770), physical('F', 1940), physical('F', 2110)],
      [label('Tenori I', 1600), label('Tenori II', 1770), label('Baritoni', 1940), label('Bassi', 2110)], 1);
    final next = page([for (final base in [200, 1050, 1900]) ...[
      physical('G', base), physical('G', base + 170), physical('F', base + 340), physical('F', base + 510),
    ]], [], 2);
    final layout = AutoEnsembleDetector().detect([first, next]);
    expect(layout.voiceNames, ['Tenor 1', 'Tenor 2', 'Baritone', 'Bass']);
    expect(layout.piano, false);
    final score = OmrPageAssembler().assemblePages(layout.pages, voiceNames: layout.voiceNames, piano: layout.piano);
    expect(score['staves'], hasLength(4));
    expect(score['staves'][0]['measures'], hasLength(4));
    expect(score['staves'][0]['measures'][0]['events'][0]['pitches'], [60]);
    expect(score['staves'][0]['measures'][1]['page'], 2);
  });
  test('uses repeated voice labels to split evenly spaced female-voice systems', () {
    final staves = [for (var i = 0; i < 6; i++) physical('G', 200 + i * 170)];
    final labels = [for (var i = 0; i < 6; i++) label(i.isEven ? 'S.' : 'A.', 200 + i * 170)];
    final layout = AutoEnsembleDetector().detect([page(staves, labels, 1)]);
    expect(layout.voiceNames, ['Soprano', 'Alto']);
    expect(layout.piano, false);
  });
  test('reads Japanese labels and does not mistake a vocal treble/bass pair for piano', () {
    final layout = AutoEnsembleDetector().detect([page([physical('G', 200), physical('F', 350)],
      [label('テノール', 200), label('バス', 350)], 1)]);
    expect(layout.voiceNames, ['Tenor', 'Bass']); expect(layout.piano, false);
  });
  test('detects four choir voices plus piano despite a large choir/piano gap', () {
    final staves = [physical('G', 200), physical('G', 380), physical('G', 560), physical('F', 740),
      physical('G', 980, chord: true), physical('F', 1080)];
    final layout = AutoEnsembleDetector().detect([page(staves, [label('Soprano', 200), label('Alto', 380),
      label('Tenor', 560), label('Bass', 740), label('Pf.', 980)], 1)]);
    expect(layout.voiceNames, ['Soprano', 'Alto', 'Tenor', 'Bass']); expect(layout.piano, true);
  });
  test('pads a piano-only introduction without reclassifying the piano as voices', () {
    final intro = page([physical('G', 300, chord: true), physical('F', 400)], [label('Piano', 300)], 1);
    final full = page([physical('G', 200), physical('G', 380), physical('G', 560), physical('F', 740),
      physical('G', 980, chord: true), physical('F', 1080)], [label('Soprano', 200), label('Alto', 380),
      label('Tenor', 560), label('Bass', 740), label('Piano', 980)], 2);
    final layout = AutoEnsembleDetector().detect([intro, full]);
    final score = OmrPageAssembler().assemblePages(layout.pages, voiceNames: layout.voiceNames, piano: layout.piano);
    expect(score['staves'], hasLength(6));
    expect(score['staves'][0]['measures'][0]['events'][0]['inferred_rest'], true);
    expect(score['staves'][0]['measures'][0]['events'][0]['pitches'], isEmpty);
    expect(score['staves'][2]['measures'][1]['events'][0]['pitches'], [60]);
    expect(score['staves'][4]['measures'][0]['events'][0]['pitches'], [72, 76]);
  });
  test('keeps unknown voice identity and sounding pitch instead of guessing a tenor octave', () {
    final layout = AutoEnsembleDetector().detect([page([physical('G', 200), physical('G', 380),
      physical('G', 560), physical('F', 740)], [], 1)]);
    expect(layout.voiceNames, ['声部 1', '声部 2', '声部 3', '声部 4']);
    final score = OmrPageAssembler().assemblePages(layout.pages, voiceNames: layout.voiceNames, piano: false);
    expect(score['staves'][2]['measures'][0]['events'][0]['pitches'], [72]);
  });
  test('does not invent a staff when physical detection is missing one', () {
    final full = page([physical('G', 200), physical('G', 380), physical('F', 560), physical('F', 740)],
      [label('Tenori I', 200), label('Tenori II', 380), label('Baritoni', 560), label('Bassi', 740)], 1);
    final missing = page([physical('G', 200), physical('F', 560), physical('F', 740)], [], 2);
    expect(() => AutoEnsembleDetector().detect([full, missing]), throwsFormatException);
  });
  test('uses confirmed ensemble and page gaps when choir and piano are split apart', () {
    final full = page([physical('G', 200), physical('G', 380), physical('F', 560), physical('F', 740),
      physical('G', 980, chord: true), physical('F', 1080)], [label('Tenor I', 200),
      label('Tenor II', 380), label('Baritone', 560), label('Bass', 740), label('Piano', 980)], 1);
    // Rounded geometry from a scanned page: piano staves are not significantly
    // closer together, and one vocal bass clef was decoded as treble.
    final next = page([
      for (final item in [('G', 280), ('G', 457), ('F', 632), ('F', 799),
        ('G', 1024), ('F', 1189), ('G', 1547), ('G', 1721), ('F', 1896),
        ('G', 2049), ('G', 2279), ('F', 2429)]) physical(item.$1, item.$2),
    ], [], 2);
    final layout = AutoEnsembleDetector().detect([full, next]);
    expect(layout.voiceNames, ['Tenor 1', 'Tenor 2', 'Baritone', 'Bass']);
    expect(layout.piano, true);
    expect(layout.pages[1].staves, hasLength(12));
    final score = OmrPageAssembler().assemblePages(layout.pages, voiceNames: layout.voiceNames, piano: true);
    expect(score['staves'], hasLength(6));
    expect(score['staves'][0]['measures'], hasLength(3));
  });
  test('does not merge genuinely separate abbreviated systems to match ensemble', () {
    final full = page([physical('G', 200), physical('G', 380), physical('F', 560), physical('F', 740),
      physical('G', 980, chord: true), physical('F', 1080)], [label('Tenor I', 200),
      label('Tenor II', 380), label('Baritone', 560), label('Bass', 740), label('Piano', 980)], 1);
    final abbreviated = page([for (final base in [100, 1100, 2100, 3100]) ...[
      physical('G', base), physical('G', base + 170), physical('F', base + 340),
    ]], [], 2);
    expect(() => AutoEnsembleDetector().detect([full, abbreviated]), throwsFormatException);
  });
  test('reads voice names above staves after a labelled piano introduction', () {
    final input = page([
      physical('G', 200, chord: true), physical('F', 310),
      physical('G', 800), physical('G', 920), physical('F', 1040), physical('F', 1160),
      physical('G', 1310, chord: true), physical('F', 1420),
    ], [
      label('Piano', 200),
      for (final item in [('Tenor I', 800), ('Tenor II', 920), ('Baritone', 1040), ('Bass', 1160)])
        RecognizedTextLabel(item.$1, [400, item.$2 - 26, 470, item.$2 - 4]),
    ], 1);
    final layout = AutoEnsembleDetector().detect([input]);
    expect(layout.voiceNames, ['Tenor 1', 'Tenor 2', 'Baritone', 'Bass']);
    expect(layout.piano, true);
    expect(layout.pages.first.staves, hasLength(12));
  });
}
