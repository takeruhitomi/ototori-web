import 'package:choir_mobile/browser_assembly.dart';
import 'package:choir_mobile/omr_bridge.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:choir_mobile/score_structure.dart';
import 'package:choir_mobile/voice_labels.dart';
import 'package:flutter_test/flutter_test.dart';

OmrSymbol sym(String rhythm, [String pitch = '.']) =>
    OmrSymbol(rhythm: rhythm, pitch: pitch, lift: '.', position: 'upper', articulation: '.', slur: '.');

/// A staff of three 4/4 bars, one whole note each ([notes] = false: rests).
RecognizedStaffSymbols staff(String clef, int top, {bool notes = true}) => RecognizedStaffSymbols(
  crop: [250, top - 40, 1800, top + 90], lines: [for (var i = 0; i < 5; i++) top + i * 10.0], left: 300, right: 1750,
  reachedEos: true, symbols: [
    sym(clef == 'G' ? 'clef_G2' : 'clef_F4'), sym('timeSignature/4'),
    for (var b = 0; b < 3; b++) ...[
      notes ? sym('note_1', clef == 'G' ? 'D4' : 'G2') : sym('rest_1'),
      sym('barline'),
    ],
  ],
);

/// TTBB system (treble, treble, bass, bass) with an optional staff on top.
RecognizedPageSymbols page(int number, {String? solo, List<RecognizedTextLabel> labels = const [], bool soloNotes = true}) {
  final staves = [
    if (solo != null) staff(solo, 200, notes: soloNotes),
    staff('G', 400), staff('G', 560), staff('F', 720), staff('F', 880),
  ];
  return RecognizedPageSymbols(staves: staves, labels: labels, warnings: const [], width: 1920, height: 2800,
    pageNumber: number, systems: [SystemLayout([for (var i = 0; i < staves.length; i++) i])]);
}

List<Map<String, dynamic>> staves(BrowserAssemblyResult r) => (r.json['staves'] as List).cast<Map<String, dynamic>>();

bool sounding(Map m) => (m['events'] as List).any((e) => (e['pitches'] as List).isNotEmpty);

void main() {
  test('a solo staff joining mid-piece becomes its own part, resting elsewhere', () {
    final result = assembleLikeBrowser([
      page(1), page(2),
      page(3, solo: 'G', labels: const [RecognizedTextLabel('Ten. solo (or soli)', [300, 150, 520, 180])]),
      page(4),
    ]);
    final parts = staves(result);
    expect(parts, hasLength(5));
    final solo = parts.first;
    expect(solo['added'], isTrue);
    expect(solo['name'], 'Tenor Solo');
    expect(solo['voice_type'], 'tenor');
    expect(solo['octave_shift'], -1);
    final bars = solo['measures'] as List;
    expect(bars, hasLength(12));
    expect([for (final m in bars) sounding(m as Map)], [
      false, false, false, false, false, false, true, true, true, false, false, false]);
    expect([for (final p in parts.skip(1)) p['added']], everyElement(isNull));
    expect(result.json['meta']['voice_count'], 4);
    final added = (result.json['meta']['added_parts'] as List).single as Map;
    expect(added['id'], 'S1');
    expect(added['name_source'], 'labels');
    expect((added['systems'] as List).single['page'], 3);
  });

  test('without a label a treble solo in a male choir is a tenor', () {
    final result = assembleLikeBrowser([page(1), page(2, solo: 'G')]);
    final solo = staves(result).first;
    expect(solo['name'], 'Tenor Solo');
    expect(solo['octave_shift'], -1);
    expect((result.json['meta']['added_parts'] as List).single['name_source'], 'choir');
  });

  test('a surplus staff without notes is still dropped', () {
    final result = assembleLikeBrowser([page(1), page(2, solo: 'G', soloNotes: false)]);
    expect(staves(result), hasLength(4));
    expect(result.json['meta']['added_parts'], isNull);
  });

  test('manual voice names keep the old behaviour (surplus staves dropped)', () {
    final result = assembleLikeBrowser([page(1), page(2, solo: 'G')],
      layout: EnsembleLayout(voiceNames: ['Tenor I', 'Tenor II', 'Baritone', 'Bass'], piano: false));
    expect(staves(result), hasLength(4));
  });

  test('in a piano piece, two unbraced staves below the choir are the piano, not added parts', () {
    RecognizedPageSymbols withPiano(int number, {required bool brace, String lh = 'F'}) {
      final staves = [staff('G', 300), staff('G', 460), staff('G', 620), staff('F', 780), staff('G', 980), staff(lh, 1140)];
      return RecognizedPageSymbols(staves: staves, warnings: const [], width: 1920, height: 2800, pageNumber: number,
        systems: [SystemLayout(const [0, 1, 2, 3, 4, 5], pianoPair: brace ? (4, 5) : null, hasBrace: brace)]);
    }
    // Page 2: brace missed and the left hand in treble clef.
    final result = assembleLikeBrowser([withPiano(1, brace: true), withPiano(2, brace: false, lh: 'G')]);
    final parts = staves(result);
    expect([for (final p in parts) p['role']], ['voice', 'voice', 'voice', 'voice', 'piano_rh', 'piano_lh']);
    expect(result.json['meta']['added_parts'], isNull);
    final rh = parts[4]['measures'] as List;
    expect([for (final m in rh) sounding(m as Map)], everyElement(isTrue));
  });

  test('added-part labels', () {
    expect(parseAddedPartLabel('Ten. solo (or soli)'), ('tenor', true));
    expect(parseAddedPartLabel('Soprano Solo'), ('soprano', true));
    expect(parseAddedPartLabel('Soloist：バックコーラス風に'), ('', true));
    expect(parseAddedPartLabel('ソロ'), ('', true));
    expect(parseAddedPartLabel('A'), isNull);
    expect(parseAddedPartLabel('85'), isNull);
  });
}
