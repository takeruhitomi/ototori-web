import 'package:choir_mobile/grand_staff_timing.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:flutter_test/flutter_test.dart';

OmrSymbol n(String rhythm, String pitch, double x) =>
    OmrSymbol(rhythm: rhythm, pitch: pitch, lift: '_', position: 'upper', articulation: '_', slur: '_', x: x);
OmrSymbol r(String rhythm, double x) => n(rhythm, '_', x);
const bar = OmrSymbol(rhythm: 'barline', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.');
const chord = OmrSymbol(rhythm: 'chord', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.');
final four = BeatFraction.of(4);

String show(List<OmrSymbol> s) => s.map((t) => t.rhythm == 'chord' ? '+' : t.rhythm).join(' ');

void main() {
  test('a cross-staff arpeggio is read across the hands', () {
    // Eight eighths: the first four in the left hand, the rest in the right.
    final lh = [for (var i = 0; i < 4; i++) n('note_8', 'A2', 250.0 + 40 * i), bar];
    final rh = [r('rest_1', 300), for (var i = 0; i < 4; i++) n('note_8', 'C4', 420.0 + 40 * i), bar];
    final t = alignGrandStaff(rh, lh, [four], 18)!;
    expect(t.changedBars, [0]);
    expect(show(t.right), 'rest_2 note_8 note_8 note_8 note_8 barline'); // whole rest was a misreading
    expect(show(t.left), 'note_8 note_8 note_8 note_8 barline');
  });

  test('a lost note shifts only the following notes of that hand', () {
    // RH quarters on every beat but the second one was not read.
    final rh = [n('note_4', 'C5', 100), n('note_4', 'E5', 300), n('note_4', 'G5', 400), bar];
    final lh = [for (var i = 0; i < 4; i++) n('note_4', 'C3', 100.0 + 100 * i), bar];
    final t = alignGrandStaff(rh, lh, [four], 18)!;
    expect(show(t.right), 'note_4 rest_4 note_4 note_4 barline');
    expect(t.left, lh);
  });

  test('bars that already fit and bars without x are left alone', () {
    final rh = [n('note_2', 'C5', 100), n('note_2', 'E5', 300), bar,
      const OmrSymbol(rhythm: 'note_4', pitch: 'C5', lift: '_', position: 'upper', articulation: '_', slur: '_'), bar];
    final lh = [n('note_1', 'C3', 100), bar, n('note_4', 'C3', 500), bar];
    expect(alignGrandStaff(rh, lh, [four, four], 18), isNull);
  });

  test('a joint reading that overruns the bar is rejected', () {
    final rh = [n('note_2', 'C5', 100), n('note_2', 'E5', 300), n('note_4', 'G5', 400), bar];
    final lh = [n('note_1', 'C3', 100), bar];
    expect(alignGrandStaff(rh, lh, [four], 18), isNull);
  });

  test('chords and graces keep their tokens', () {
    final rh = [n('note_8G', 'D5', 150), n('note_4', 'C5', 200), chord, n('note_4', 'E5', 200), n('note_2', 'G5', 300), bar];
    final lh = [n('note_4', 'C3', 100), n('note_4', 'E3', 200), n('note_4', 'G3', 300), n('note_4', 'C4', 400), bar];
    final t = alignGrandStaff(rh, lh, [four], 18)!;
    expect(show(t.right), 'rest_4 note_8G note_4 + note_4 note_2 barline');
  });

  test('a second voice under a long note is placed by x against the other hand', () {
    // RH: dotted half at beat 0, quarters on beats 1 and 2 under it, chord on 3.
    // Read serially that is 6 beats; the left hand (two halves) fills the bar.
    final rh = [n('note_2.', 'G5', 262), n('note_4', 'C5', 335), n('note_4', 'D5', 411), n('note_4', 'E5', 480), bar];
    final lh = [n('note_2', 'C3', 270), n('note_2', 'G2', 403), bar];
    final t = alignGrandStaff(rh, lh, [four], 18)!;
    expect(show(t.right), 'note_2. + rest_4 note_4 note_4 note_4 barline');
    expect(t.right[2].articulation, spacerArticulation);
    expect(t.left, lh);
  });

  test('bar sums skip multi-bar rests', () {
    final s = [r('rest_4m', 100), bar, n('note_2', 'C5', 100), n('note_4', 'C5', 200), bar];
    expect(barSums(s), [null, BeatFraction.of(3)]);
  });
}
