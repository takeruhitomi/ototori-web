import 'package:choir_mobile/omr_bridge.dart';
import 'package:choir_mobile/tempo_marks.dart';
import 'package:flutter_test/flutter_test.dart';

RecognizedPageSymbols page(List<(String, int)> labels, {int number = 1}) => RecognizedPageSymbols(
  staves: [RecognizedStaffSymbols(symbols: const [], reachedEos: true, crop: const [100, 500, 1800, 700],
    lines: const [550, 570, 590, 610, 630])],
  warnings: const [], width: 1920, height: 2700, pageNumber: number,
  labels: [for (final (t, y) in labels) RecognizedTextLabel(t, [400, y, 700, y + 40])]);

void main() {
  test('reads the OCR forms of real metronome marks', () {
    // Strings as ML Kit returned them for the six evaluation pieces.
    expect(parseTempoText('J- ca. 92')?.$1, 92);
    expect(parseTempoText('J ca, 108')?.$1, 108);
    expect(parseTempoText('Cn、108'), (108, false, false));
    expect(parseTempoText('Con grande emotione, tempo di moderato =ca.72'), (72, false, false));
    expect(parseTempoText('J=ca. 120 (t*Tk)')?.$1, 120);
    expect(parseTempoText('ca. 120 (快活に)')?.$1, 120);
    expect(parseTempoText('J- ca. 52')?.$1, 52);
    expect(parseTempoText('Con grande emotione, tempo di moderato =ca.72')?.$1, 72);
    expect(parseTempoText('Con grande emotione, tempo di moderatoJ=ca.72')?.$1, 72);
    expect(parseTempoText('J.=76'), (76, true, true));
    expect(parseTempoText('.-76'), (76, false, true)); // ヒスイ: ♩.=76
    expect(parseTempoText('la la. - 45'), isNull);
    expect(parseTempoText('♩＝８８')?.$1, 88);
  });

  test('ignores page numbers, measure numbers and other text', () {
    for (final text in ['800', '27', 'a tempo', '.a tempo lBs', '静謐に', 'Tenor I', 'J 12',
        '© 2012 by NHK Publishing Ltd.', 'Andante d', 'ca. 900']) {
      expect(parseTempoText(text), isNull, reason: text);
    }
  });

  test('takes the topmost mark on the first page with staves', () {
    final mark = tempoFromLabels([page([('d=ca. 60', 480), ('J- ca. 52', 430)])], (4, 4))!;
    expect(mark.bpm, 52);
    expect(mark.unit, 'quarter');
  });

  test('marks below the music (copyright lines) do not count', () {
    expect(tempoFromLabels([page([('Copyright 1986 =ca.90', 2600)])], (4, 4)), isNull);
  });

  test('compound time reads the beat as a dotted quarter', () {
    final dotted = tempoFromLabels([page([('J.=76', 430)])], (6, 8))!;
    expect(dotted.bpm, 114);
    expect(dotted.assumedUnit, isFalse);
    final lost = tempoFromLabels([page([('J=76', 430)])], (6, 8))!;
    expect(lost.unit, 'dotted-quarter');
    expect(lost.bpm, 114);
    expect(lost.assumedUnit, isTrue);
    expect(tempoFromLabels([page([('J=176', 430)])], (6, 8))!.bpm, 88);
  });

  test('reads "≒" and "≈" as "="', () {
    // MuseScore export of うたをうたうのはわすれても: "♩ ≒ 96".
    expect(parseTempoText('♩ ≒ 96'), (96, true, false));
    expect(parseTempoText('♩≈72')?.$1, 72);
  });

  test('an eighth or half note glyph from the PDF text layer sets the unit', () {
    // MuseScore exports of Tempestoso and たましいのスケジュール: "♪ = 88" is 44 quarters.
    final eighth = tempoFromLabels([page([('♪ = 88', 430)])], (4, 4))!;
    expect((eighth.unit, eighth.bpm, eighth.printed, eighth.assumedUnit), ('eighth', 44.0, 88, false));
    expect(tempoFromLabels([page([('♪ = 106', 430)])], (6, 8))!.bpm, 53);
    expect(tempoFromLabels([page([('♪. = 80', 430)])], (4, 4))!.bpm, 60);
    final half = tempoFromLabels([page([('\u{1D15E} = 60', 430)])], (2, 2))!;
    expect((half.unit, half.bpm), ('half', 120.0));
    expect(tempoFromLabels([page([('\u{1D15E}. = 40', 430)])], (6, 4))!.bpm, 120);
    expect(tempoUnitSymbol('eighth'), '♪');
  });

  test('no mark gives null', () {
    expect(tempoFromLabels([page([('静謐に', 430)])], (4, 4)), isNull);
  });
}
