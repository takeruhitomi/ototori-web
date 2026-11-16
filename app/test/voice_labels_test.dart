import 'package:choir_mobile/auto_ensemble.dart';
import 'package:choir_mobile/browser_assembly.dart';
import 'package:choir_mobile/omr_bridge.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:choir_mobile/score_structure.dart';
import 'package:flutter_test/flutter_test.dart';

RecognizedStaffSymbols staff(String clef, int top) => RecognizedStaffSymbols(
  crop: [250, top - 40, 1800, top + 90], lines: [for (var i = 0; i < 5; i++) top + i * 10.0], left: 300, right: 1750,
  reachedEos: true, symbols: [
    OmrSymbol(rhythm: 'clef_${clef == 'G' ? 'G2' : 'F4'}', pitch: '.', lift: '.', position: 'upper', articulation: '.', slur: '.'),
    const OmrSymbol(rhythm: 'timeSignature/4', pitch: '.', lift: '.', position: 'upper', articulation: '.', slur: '.'),
    OmrSymbol(rhythm: 'note_1', pitch: clef == 'G' ? 'D4' : 'G2', lift: '.', position: 'upper', articulation: '.', slur: '.'),
    const OmrSymbol(rhythm: 'barline', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'),
  ],
);

/// Text left of the staves (part names) at [top].
RecognizedTextLabel beside(String text, int top) => RecognizedTextLabel(text, [80, top, 285, top + 22]);

/// 瑠璃色の地球 layout: two voice staves (Tenor I/II on one treble staff,
/// Baritone/Bass on one bass staff) above a braced piano.
RecognizedPageSymbols choirAndPiano(List<RecognizedTextLabel> labels, {int number = 2}) => RecognizedPageSymbols(
  staves: [staff('G', 400), staff('F', 560), staff('G', 760), staff('F', 920)],
  labels: labels, warnings: [], width: 1920, height: 2800, pageNumber: number,
  systems: const [SystemLayout([0, 1, 2, 3], pianoPair: (2, 3), hasBrace: true)]);

List<Map<String, dynamic>> voices(BrowserAssemblyResult r) =>
  [for (final s in r.json['staves'] as List) if (s['role'] == 'voice') s as Map<String, dynamic>];

void main() {
  test('part names separate a written ordinal from an Italian plural', () {
    expect(parsePartLabel('Tenor II'), ('tenor', 2));
    expect(parsePartLabel('Tenor I'), ('tenor', 1));
    expect(parsePartLabel('Tenori I'), ('tenor', 1));
    expect(parsePartLabel('Bassi'), ('bass', 0));
    expect(parsePartLabel('Tenori II E'), isNull);
  });

  test('printed part names rename the voices and give the treble staff the tenor octave', () {
    final result = assembleLikeBrowser([choirAndPiano([
      beside('Tenor I', 400), beside('Tenor II', 422), beside('Baritone', 560), beside('Bass', 582),
      beside('Piano', 840),
    ])]);
    final v = voices(result);
    expect([for (final s in v) s['name']], ['Tenor I・II', 'Baritone・Bass']);
    expect(v[0]['voice_type'], 'tenor');
    expect(v[0]['octave_shift'], -1);
    expect(v[1]['octave_shift'], 0);
    expect(result.json['meta']['voice_names'], ['Tenor I・II', 'Baritone・Bass']);
    expect((result.json['staves'] as List).where((s) => s['role'] != 'voice'), hasLength(2));
  });

  test('without names the clef table decides (treble + bass = soprano + bass)', () {
    final v = voices(assembleLikeBrowser([choirAndPiano([])]));
    expect([for (final s in v) s['name']], ['Soprano', 'Bass']);
    expect(v[0]['octave_shift'], 0);
  });

  test('a misread or missing name on one voice staff keeps the clef names', () {
    final v = voices(assembleLikeBrowser([choirAndPiano([beside('Tenor I', 400), beside('3ar.', 560)])]));
    expect([for (final s in v) s['name']], ['Soprano', 'Bass']);
  });

  test('a name that contradicts the clef is not used', () {
    final v = voices(assembleLikeBrowser([choirAndPiano([beside('Bass', 400), beside('Soprano', 560)])]));
    expect([for (final s in v) s['name']], ['Soprano', 'Bass']);
  });

  test('a male-choir title makes treble voices tenors when the staves carry no names', () {
    final cover = RecognizedPageSymbols(staves: const [], labels: const [RecognizedTextLabel('男声合唱ピース', [343, 432, 710, 485])],
      warnings: const [], width: 1920, height: 2800, pageNumber: 1);
    final v = voices(assembleLikeBrowser([cover, choirAndPiano([])]));
    expect([for (final s in v) s['name']], ['Tenor', 'Bass']);
    expect(v[0]['octave_shift'], -1);
  });

  test('staves of one part type are numbered when the numerals are lost', () {
    final page = RecognizedPageSymbols(
      staves: [staff('G', 400), staff('G', 560), staff('F', 720), staff('F', 880)],
      labels: [beside('Tenor I', 400), beside('Tenor', 560), beside('Baritone', 720), beside('Bass', 880)],
      warnings: const [], width: 1920, height: 2800, pageNumber: 1,
      systems: const [SystemLayout([0, 1, 2, 3])]);
    final v = voices(assembleLikeBrowser([page]));
    expect([for (final s in v) s['name']], ['Tenor I', 'Tenor II', 'Baritone', 'Bass']);
  });

  test('manual voice names are kept', () {
    final v = voices(assembleLikeBrowser([choirAndPiano([beside('Tenor I', 400), beside('Bass', 560)])],
      layout: EnsembleLayout(voiceNames: ['Alto', 'Bass'], piano: true)));
    expect([for (final s in v) s['name']], ['Alto', 'Bass']);
  });
}
