/// Staff positions for drawing and editing notes on the original page.
///
/// A diatonic step is `octave * 7 + letter` (C4 = 28, E4 = 30), as in the
/// recognizer. Pitches are written MIDI numbers spelled in the key.
library;

const _naturals = [0, 2, 4, 5, 7, 9, 11];
const _sharpOrder = [3, 0, 4, 1, 5, 2, 6]; // F C G D A E B (letter indexes)
const _flatOrder = [6, 2, 5, 1, 4, 0, 3]; // B E A D G C F

/// Alteration of [letter] (0 = C … 6 = B) in a key with [fifths].
int keyAlteration(int letter, int fifths) {
  if (fifths > 0) return _sharpOrder.take(fifths.clamp(0, 7)).contains(letter) ? 1 : 0;
  if (fifths < 0) return _flatOrder.take((-fifths).clamp(0, 7)).contains(letter) ? -1 : 0;
  return 0;
}

/// ({letter, alter, octave}) of a written pitch, preferring the key's notes.
({int letter, int alter, int octave}) spell(int midi, int fifths) {
  final pc = midi % 12;
  for (var l = 0; l < 7; l++) {
    final alter = keyAlteration(l, fifths);
    if ((_naturals[l] + alter) % 12 == pc) return (letter: l, alter: alter, octave: (midi - alter) ~/ 12 - 1);
  }
  final natural = _naturals.indexOf(pc);
  if (natural >= 0) return (letter: natural, alter: 0, octave: midi ~/ 12 - 1);
  final alter = fifths < 0 ? -1 : 1;
  final letter = _naturals.indexOf((pc - alter) % 12);
  return (letter: letter, alter: alter, octave: (midi - alter) ~/ 12 - 1);
}

int stepOf(int midi, int fifths) {
  final s = spell(midi, fifths);
  return s.octave * 7 + s.letter;
}

/// The key's pitch on a step.
int pitchAtStep(int step, int fifths) {
  final letter = step % 7, octave = step ~/ 7;
  return (octave + 1) * 12 + _naturals[letter] + keyAlteration(letter, fifths);
}

/// '♯', '♭', '♮' when [midi] needs an accidental in the key, else ''.
String accidental(int midi, int fifths) {
  final s = spell(midi, fifths);
  if (s.alter == keyAlteration(s.letter, fifths)) return '';
  return switch (s.alter) { 1 => '♯', -1 => '♭', 2 => '𝄪', -2 => '𝄫', _ => '♮' };
}

/// Step of the bottom line for a clef letter (G2, F4, C3).
int clefBottom(String? clef) => switch (clef) { 'F' => 18, 'C' => 24, _ => 30 };

/// A note name such as C4 or F♯3, spelled in the key.
String spelledName(int midi, int fifths) {
  final s = spell(midi, fifths);
  const letters = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
  final mark = switch (s.alter) { 1 => '♯', -1 => '♭', 2 => '𝄪', -2 => '𝄫', _ => '' };
  return '${letters[s.letter]}$mark${s.octave}';
}

/// The five lines of one staff across one bar on the page, interpolated
/// linearly between the bar's two ends (1920-wide page pixels).
class StaffLines {
  StaffLines(this.x0, this.lines0, this.x1, this.lines1);
  final double x0, x1;
  final List<double> lines0, lines1;

  /// From a measure's `bounds`; null when the lines are missing.
  static StaffLines? of(Object? bounds) {
    if (bounds is! Map) return null;
    List<double>? lines(Object? v) => v is List && v.length == 5 && v.every((e) => e is num) ? [for (final e in v) (e as num).toDouble()] : null;
    final l0 = lines(bounds['lines0']), l1 = lines(bounds['lines1']);
    final x0 = (bounds['x0'] as num?)?.toDouble(), x1 = (bounds['x1'] as num?)?.toDouble();
    if (l0 == null && l1 == null) return null;
    final left = x0 ?? (x1 ?? 0) - 400, right = x1 ?? left + 400;
    return StaffLines(left, l0 ?? l1!, right <= left ? left + 1 : right, l1 ?? l0!);
  }

  double _t(double x) => ((x - x0) / (x1 - x0)).clamp(-0.5, 1.5);
  double line(int i, double x) => lines0[i] + (lines1[i] - lines0[i]) * _t(x);
  /// Half the distance between two lines at [x].
  double half(double x) => (line(4, x) - line(0, x)) / 8;
  double top(double x) => line(0, x);
  double bottom(double x) => line(4, x);
  /// Page y of [step] at [x] for a staff whose bottom line is [bottomStep].
  double yOf(int step, double x, int bottomStep) => bottom(x) - (step - bottomStep) * half(x);
  /// Nearest step at page y.
  int stepAt(double y, double x, int bottomStep) => bottomStep + ((bottom(x) - y) / half(x)).round();
}
