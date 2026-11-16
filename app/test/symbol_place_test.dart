import 'package:choir_mobile/browser_assembly.dart';
import 'package:choir_mobile/omr_bridge.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:flutter_test/flutter_test.dart';

OmrSymbol t(String rhythm, [String pitch = '.']) =>
  OmrSymbol(rhythm: rhythm, pitch: pitch, lift: '.', position: 'upper', articulation: '.', slur: '.');

const lines0 = [100.0, 112.0, 124.0, 136.0, 148.0];
const lines1 = [103.0, 115.0, 127.0, 139.0, 151.0];
const lines2 = [106.0, 118.0, 130.0, 142.0, 154.0];

void main() {
  test('parses native places and rejects malformed ones', () {
    final bar = SymbolPlace.tryParse([450.5, null, 1.0, true, ...lines1])!;
    expect(bar.lines, lines1);
    expect(bar.snapped, isTrue);
    expect(SymbolPlace.tryParse([300.0, 136.0, 0.42, false])!.y, 136.0);
    expect(SymbolPlace.tryParse([300.0, 136.0, 0.42]), isNull);
    expect(SymbolPlace.tryParse(['x', 1, 1, true]), isNull);
    expect(SymbolPlace.tryParse([double.nan, 1, 1, true]), isNull);
  });

  test('bars carry both ends with their staff lines; notes carry their heads', () {
    final symbols = [
      t('clef_G2'), t('timeSignature/4'), t('note_2', 'G4'), t('note_2', 'B4'), t('barline'),
      t('note_1', 'C5'), t('barline'),
    ];
    final places = [
      [50.0, null, 1.0, true, ...lines0], null, [120.0, 136.0, 0.95, true], [260.0, 124.0, 0.3, false],
      [450.5, null, 1.0, true, ...lines1], [600.0, 118.0, 0.9, true], [850.0, null, 0.6, true, ...lines2],
    ];
    final staff = withPlaces([RecognizedStaffSymbols(symbols: symbols, reachedEos: true, crop: const [0, 0, 900, 200])],
      [places]).single;
    final s = staffFromSymbols(staff.symbols);
    expect(s.measures, hasLength(2));
    final b1 = s.measures[0].bounds!;
    expect([b1['x0'], b1['x1']], [50.0, 450.5]);
    expect([b1['lines0'], b1['lines1']], [lines0, lines1]);
    final b2 = s.measures[1].bounds!;
    expect([b2['x0'], b2['x1'], b2['confidence1']], [450.5, 850.0, 0.6]);
    final first = s.measures[0].events.first.place!;
    expect(first['x'], 120.0);
    expect((first['heads'] as List).single, {'pitch': 67, 'x': 120.0, 'y': 136.0, 'confidence': 0.95, 'snapped': true});
    final second = s.measures[0].events[1].place!;
    expect((second['heads'] as List).single['snapped'], isFalse);
    // Positions reach the score JSON.
    final json = s.measures[1].toJson();
    expect(json['bounds']['x1'], 850.0);
    expect((json['events'] as List).single['place']['heads'][0]['y'], 118.0);
  });

  test('staves without places assemble as before', () {
    final s = staffFromSymbols([t('clef_G2'), t('note_1', 'C5'), t('barline')]);
    expect(s.measures.single.bounds, isNull);
    expect(s.measures.single.events.single.place, isNull);
    expect(s.measures.single.toJson().containsKey('bounds'), isFalse);
  });
}
