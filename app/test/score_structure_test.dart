import 'package:choir_mobile/browser_assembly.dart';
import 'package:choir_mobile/omr_bridge.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:choir_mobile/score_ir.dart';
import 'package:choir_mobile/score_postprocess.dart';
import 'package:choir_mobile/score_structure.dart';
import 'package:flutter_test/flutter_test.dart';

OmrSymbol s(String rhythm, [String pitch = '.', String position = 'upper']) =>
    OmrSymbol(rhythm: rhythm, pitch: pitch, lift: '_', position: position, articulation: '_', slur: '_');
const bar = OmrSymbol(rhythm: 'barline', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.');

/// One staff: clef + [measures] bars of four quarter notes on [pitch].
List<OmrSymbol> staffTokens(String clef, String pitch, {int measures = 2}) => [
  s(clef), OmrSymbol(rhythm: 'keySignature_0', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'),
  OmrSymbol(rhythm: 'timeSignature/4', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'),
  for (var m = 0; m < measures; m++) ...[for (var i = 0; i < 4; i++) s('note_4', pitch), bar],
];

Staff staff(String clef, String pitch, {int measures = 2, String id = 'S1'}) =>
    staffFromSymbols(staffTokens(clef, pitch, measures: measures), id: id);

List<Staff> choirAndPiano({int measures = 2}) => [
  staff('clef_G2', 'C5', measures: measures, id: 'S1'), staff('clef_G2', 'A4', measures: measures, id: 'S2'),
  staff('clef_F4', 'F3', measures: measures, id: 'S3'), staff('clef_F4', 'C3', measures: measures, id: 'S4'),
  staff('clef_G2', 'E5', measures: measures, id: 'S5'), staff('clef_F4', 'C3', measures: measures, id: 'S6'),
];

void main() {
  test('clefs G G F F + piano give TTBB and the tenors sound an octave lower', () {
    final score = assembleUnits([Unit(choirAndPiano(), page: 1, system: 0, pianoPair: (4, 5))]);
    expect(score.meta['ensemble'], 'TTBB');
    expect(score.staves.map((s) => s.name), ['Tenor I', 'Tenor II', 'Baritone', 'Bass', 'Piano RH', 'Piano LH']);
    expect(score.staves.take(2).map((s) => s.octaveShift), [-1, -1]);
    postprocessScore(score, PostOptions(ensemble: 'TTBB'));
    expect(score.staves[0].measures.first.events.first.pitches, [60]); // C5 written -> C4 sounding
    expect(score.staves[0].clef, 'G8vb');
    expect(score.staves[4].measures.first.events.first.pitches, [76]); // piano unchanged
  });

  test('a braced piano-only system gives the voices rest measures', () {
    final intro = [staff('clef_G2', 'E5', measures: 3, id: 'S1'), staff('clef_F4', 'C3', measures: 3, id: 'S2')];
    final score = assembleUnits([
      Unit(intro, page: 1, system: 0, pianoOnly: true, pianoPair: (0, 1)),
      Unit(choirAndPiano(), page: 1, system: 1, pianoPair: (4, 5)),
    ]);
    expect(score.measureCount(), 5);
    final tenor = score.staves.first;
    expect(tenor.measures.take(3).every((m) => m.events.single.isRest && m.events.single.inferredRest), isTrue);
    expect(tenor.measures[3].events.first.pitches, [72]);
    expect(score.staves[4].measures.first.events.first.pitches, [76]);
  });

  test('a brace over three staves merges the top piano staff into the right hand', () {
    final staves = [...choirAndPiano().take(4), staff('clef_G2', 'G5', id: 'S5'),
      staff('clef_G2', 'E5', id: 'S6'), staff('clef_F4', 'C3', id: 'S7')];
    final score = assembleUnits([Unit(staves, page: 1, system: 0, pianoPair: (5, 6), pianoExtra: 4)]);
    expect(score.meta['voice_count'], 4);
    final rhPitches = {for (final e in score.staves[4].measures.first.events) ...e.pitches};
    expect(rhPitches, {76, 79});
  });

  test('systems disagreeing on measure counts keep the majority and drop the fragment', () {
    final staves = choirAndPiano();
    // One staff split its last bar at a stray barline: a short extra measure.
    staves[2] = staffFromSymbols([...staffTokens('clef_F4', 'F3'), s('note_8', 'F3'), bar], id: 'S3');
    final score = assembleUnits([Unit(staves, page: 1, system: 0, pianoPair: (4, 5))]);
    expect(score.measureCount(), 2);
    expect(score.warnings.any((w) => w.contains('小節数が異なります')), isTrue);
  });

  test('rest-only staves that lost a barline do not decide the bar count', () {
    List<OmrSymbol> rests(String clef, int bars) => [s(clef), for (var m = 0; m < bars; m++) ...[s('rest_1', '_'), bar]];
    final staves = [
      staffFromSymbols(rests('clef_G2', 2), id: 'S1'), staffFromSymbols(rests('clef_G2', 2), id: 'S2'),
      staffFromSymbols(rests('clef_F4', 2), id: 'S3'), staff('clef_F4', 'C3', measures: 3, id: 'S4'),
      staff('clef_G2', 'E5', measures: 3, id: 'S5'), staff('clef_F4', 'C3', measures: 3, id: 'S6'),
    ];
    final score = assembleUnits([Unit(staves, page: 1, system: 0, pianoPair: (4, 5), imageLayout: true)]);
    expect(score.measureCount(), 3);
    expect(score.staves[4].measures.map((m) => m.events.first.pitches), everyElement([76]));
  });

  test('without a treble-bass brace an a cappella choir keeps all staves as voices', () {
    // SATB on four staves: the last two (G, F) must not become a piano.
    final staves = [staff('clef_G2', 'C5', id: 'S1'), staff('clef_G2', 'A4', id: 'S2'),
      staff('clef_G2', 'E4', id: 'S3'), staff('clef_F4', 'C3', id: 'S4')];
    final withImage = assembleUnits([Unit([for (final x in staves) x], page: 1, system: 0, imageLayout: true)]);
    expect(withImage.meta['piano'], isFalse);
    expect(withImage.meta['voice_count'], 4);
    final braced = assembleUnits([Unit(choirAndPiano(), page: 1, system: 0, pianoPair: (4, 5), imageLayout: true)]);
    expect(braced.meta['piano'], isTrue);
  });

  test('a multi-bar rest becomes one whole-bar rest per bar', () {
    final tokens = [s('clef_G2'), OmrSymbol(rhythm: 'timeSignature/4', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.'),
      s('rest_10m', '_'), bar, for (var i = 0; i < 3; i++) s('note_4', 'C5'), s('rest_4', '_'), bar];
    final staff = staffFromSymbols(tokens);
    expect(staff.measures, hasLength(11));
    expect(staff.measures.take(10).every((m) => m.events.single.isRest && m.events.single.duration == frac(4)), isTrue);
    expect(staff.measures.last.events.where((e) => e.pitches.isNotEmpty), hasLength(3));
  });

  test('empty ruled staves are left out of the ensemble', () {
    RecognizedStaffSymbols rs(double top, List<OmrSymbol> tokens) => RecognizedStaffSymbols(symbols: tokens, reachedEos: true,
      crop: [0, top.toInt() - 40, 1920, top.toInt() + 80], lines: [for (var i = 0; i < 5; i++) top + i * 10], left: 100, right: 1800);
    final music = [for (final st in [('clef_G2', 'C5'), ('clef_G2', 'A4'), ('clef_F4', 'F3'), ('clef_F4', 'C3')]) staffTokens(st.$1, st.$2)];
    final blank = [s('clef_G2'), s('rest_1', '_'), bar];
    final page = RecognizedPageSymbols(staves: [
      rs(100, blank), for (var i = 0; i < 4; i++) rs(300.0 + i * 90, music[i]), rs(900, blank),
    ], warnings: const [], width: 1920, height: 2700, pageNumber: 1, systems: const [
      SystemLayout([0]), SystemLayout([1, 2, 3, 4]), SystemLayout([5]),
    ]);
    final result = assembleLikeBrowser([page]);
    expect(result.score.meta['voice_count'], 4);
    expect(result.score.measureCount(), 2);
  });

  test('a staff with malformed chord markers does not stop the assembly', () {
    RecognizedStaffSymbols rs(double top, List<OmrSymbol> tokens) => RecognizedStaffSymbols(symbols: tokens, reachedEos: true,
      crop: [0, top.toInt() - 40, 1920, top.toInt() + 80], lines: [for (var i = 0; i < 5; i++) top + i * 10], left: 100, right: 1800);
    final music = [for (final st in [('clef_G2', 'C5'), ('clef_G2', 'A4'), ('clef_F4', 'F3'), ('clef_F4', 'C3'), ('clef_G2', 'E5'), ('clef_F4', 'C3')])
      staffTokens(st.$1, st.$2)];
    const chord = OmrSymbol(rhythm: 'chord', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.');
    music[5] = [chord, ...music[5]]; // marker before any note
    final page = RecognizedPageSymbols(staves: [for (var i = 0; i < 6; i++) rs(100.0 + i * 90, music[i])],
      warnings: const [], width: 1920, height: 2700, pageNumber: 1,
      systems: const [SystemLayout([0, 1, 2, 3, 4, 5], pianoPair: (4, 5), hasBrace: true)]);
    final result = assembleLikeBrowser([page]);
    expect(result.score.measureCount(), 2);
    expect(result.score.warnings.any((w) => w.contains('6本目') && w.contains('休符で補います')), isTrue);
  });

  test('rhythm repair reads three eighths in one beat as a triplet', () {
    final plan = repairVoiceDurations([frac(1, 2), frac(1, 2), frac(1, 2), frac(1), frac(1), frac(1)], frac(4));
    expect(plan, isNotNull);
    expect(plan!.durations.take(3), [frac(1, 3), frac(1, 3), frac(1, 3)]);
    expect(plan.tupletBeats, [frac(0)]);
  });

  test('pages without image layout fall back to the gap heuristic and skip empty pages', () {
    RecognizedStaffSymbols rs(double top, List<OmrSymbol> tokens) => RecognizedStaffSymbols(symbols: tokens, reachedEos: true,
      crop: [0, top.toInt() - 40, 1920, top.toInt() + 80], lines: [for (var i = 0; i < 5; i++) top + i * 10], left: 100, right: 1800);
    final tokens = [for (final st in [('clef_G2', 'C5'), ('clef_G2', 'A4'), ('clef_F4', 'F3'), ('clef_F4', 'C3')]) staffTokens(st.$1, st.$2)];
    final page = RecognizedPageSymbols(staves: [
      for (var i = 0; i < 4; i++) rs(100.0 + i * 90, tokens[i]),
      for (var i = 0; i < 4; i++) rs(800.0 + i * 90, tokens[i]),
    ], warnings: const [], width: 1920, height: 2700, pageNumber: 1);
    const blank = RecognizedPageSymbols(staves: [], warnings: [], width: 1920, height: 2700, pageNumber: 2);
    final result = assembleLikeBrowser([page, blank]);
    expect(result.score.meta['ensemble'], 'TTBB');
    expect(result.score.meta['piano'], isFalse);
    expect(result.score.measureCount(), 4);
    expect(result.score.warnings.any((w) => w.contains('2ページ: 五線がない')), isTrue);
    expect((result.json['meta']['layout']['pages'] as List).single['systems'], hasLength(2));
  });
}
