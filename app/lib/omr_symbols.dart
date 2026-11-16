/// Symbol-level building blocks for translating the homr 0.7 model output.
/// Vocabulary and duration semantics are based on homr (AGPL-3.0); see
/// android/app/../../../third_party/homr/NOTICE.md.
library;

class BeatFraction implements Comparable<BeatFraction> {
  factory BeatFraction(int numerator, int denominator) {
    if (denominator == 0) throw const FormatException('拍の分母がゼロです。');
    if (denominator < 0) { numerator = -numerator; denominator = -denominator; }
    final gcd = numerator.abs().gcd(denominator);
    return BeatFraction._(numerator ~/ gcd, denominator ~/ gcd);
  }
  const BeatFraction._(this.numerator, this.denominator);
  final int numerator;
  final int denominator;
  static final zero = BeatFraction(0, 1);
  BeatFraction operator +(BeatFraction other) => BeatFraction(numerator * other.denominator + other.numerator * denominator, denominator * other.denominator);
  BeatFraction operator *(BeatFraction other) => BeatFraction(numerator * other.numerator, denominator * other.denominator);
  BeatFraction operator -(BeatFraction other) => BeatFraction(numerator * other.denominator - other.numerator * denominator, denominator * other.denominator);
  BeatFraction operator /(BeatFraction other) => BeatFraction(numerator * other.denominator, denominator * other.numerator);
  BeatFraction operator -() => BeatFraction(-numerator, denominator);
  bool operator <(BeatFraction other) => compareTo(other) < 0;
  bool operator <=(BeatFraction other) => compareTo(other) <= 0;
  bool operator >(BeatFraction other) => compareTo(other) > 0;
  bool operator >=(BeatFraction other) => compareTo(other) >= 0;
  static BeatFraction of(int value) => BeatFraction(value, 1);
  /// Parses `"n/d"`, `"n"` or a JSON number (limited to 1/1024, as the PC IR).
  static BeatFraction parse(Object? value) {
    if (value is BeatFraction) return value;
    if (value is int) return BeatFraction(value, 1);
    if (value is num) return BeatFraction((value * 1024).round(), 1024);
    final pieces = '$value'.split('/');
    return BeatFraction(int.parse(pieces[0].trim()), pieces.length == 1 ? 1 : int.parse(pieces[1].trim()));
  }
  static BeatFraction max(BeatFraction a, BeatFraction b) => a >= b ? a : b;
  static BeatFraction min(BeatFraction a, BeatFraction b) => a <= b ? a : b;
  @override int compareTo(BeatFraction other) => (numerator * other.denominator).compareTo(other.numerator * denominator);
  @override bool operator ==(Object other) => other is BeatFraction && numerator == other.numerator && denominator == other.denominator;
  @override int get hashCode => Object.hash(numerator, denominator);
  @override String toString() => '$numerator/$denominator';
}

/// Articulation of a synthetic rest that only sets a chord's cursor advance.
const spacerArticulation = 'spacer';

/// Where a token sits on its page (1920-wide page pixels), from the native
/// snapping (`places`). [snapped]: x (and y for a note) was confirmed on the
/// image (barline / notehead found); otherwise it is the decoder's estimate.
/// [confidence] 0..1. [lines]: the five staff line heights (top to bottom)
/// at [x]; given for barlines and for the start of the staff.
class SymbolPlace {
  const SymbolPlace({required this.x, this.y, required this.confidence, required this.snapped, this.lines});
  final double x;
  final double? y;
  final double confidence;
  final bool snapped;
  final List<double>? lines;

  /// `[x, y|null, confidence, snapped, (five line heights)]`; null when malformed.
  static SymbolPlace? tryParse(Object? value) {
    if (value is! List || (value.length != 4 && value.length != 9)) return null;
    final x = value[0], y = value[1], c = value[2], s = value[3];
    if (x is! num || (y != null && y is! num) || c is! num || s is! bool) return null;
    if (!x.isFinite || !c.isFinite || (y is num && !y.isFinite)) return null;
    List<double>? lines;
    if (value.length == 9) {
      if (value.skip(4).any((v) => v is! num || !v.isFinite)) return null;
      lines = [for (final v in value.skip(4)) (v as num).toDouble()];
    }
    return SymbolPlace(x: x.toDouble(), y: (y as num?)?.toDouble(),
      confidence: c.toDouble().clamp(0.0, 1.0), snapped: s, lines: lines);
  }

  Map<String, dynamic> toJson() => {'x': x, if (y != null) 'y': y, 'confidence': confidence, 'snapped': snapped};
}

class OmrSymbol {
  const OmrSymbol({required this.rhythm, required this.pitch, required this.lift,
    required this.position, required this.articulation, required this.slur, this.x, this.place});
  final String rhythm, pitch, lift, position, articulation, slur;
  /// Horizontal page position (pixels) from the decoder's attention, when the
  /// recognition recorded it. Approximate: a few pixels of noise are normal.
  final double? x;
  /// Position confirmed against the page image (see [SymbolPlace]).
  final SymbolPlace? place;

  OmrSymbol withPlace(SymbolPlace? place) => OmrSymbol(rhythm: rhythm, pitch: pitch, lift: lift,
    position: position, articulation: articulation, slur: slur, x: x, place: place);

  /// Six token strings, optionally followed by the attention x (a number).
  factory OmrSymbol.fromList(List<dynamic> values) {
    final shapeOk = (values.length == 6 || (values.length == 7 && (values[6] == null || values[6] is num))) &&
        values.take(6).every((v) => v is String);
    if (!shapeOk) throw const FormatException('認識記号の形式が不正です。');
    return OmrSymbol(rhythm: values[0] as String, pitch: values[1] as String,
      lift: values[2] as String, position: values[3] as String,
      articulation: values[4] as String, slur: values[5] as String,
      x: values.length == 7 ? (values[6] as num?)?.toDouble() : null);
  }


  bool get isTimed => rhythm.startsWith('note_') || rhythm.startsWith('rest_');
  bool get isGrace => isTimed && rhythm.contains('G');

  /// The model emits written pitch plus an explicit chromatic alteration.
  /// A missing pitch is represented as a rest, as in homr's MusicXML output.
  int? get midiPitch {
    if (!isTimed) throw const FormatException('音符または休符ではありません。');
    if (pitch == '_' || pitch == '.') return null;
    final match = RegExp(r'^([A-G])(\d)$').firstMatch(pitch);
    if (match == null) throw FormatException('音高を解釈できません: $pitch');
    const semitones = {'C': 0, 'D': 2, 'E': 4, 'F': 5, 'G': 7, 'A': 9, 'B': 11};
    const alterations = {'_': 0, '.': 0, 'N': 0, '#': 1, '##': 2, 'b': -1, 'bb': -2};
    final alteration = alterations[lift];
    if (alteration == null) throw FormatException('臨時記号を解釈できません: $lift');
    final value = (int.parse(match.group(2)!) + 1) * 12 + semitones[match.group(1)!]! + alteration;
    if (value < 0 || value > 127) throw const FormatException('MIDI音高の範囲外です。');
    return value;
  }

  /// Duration in quarter-note beats, including dots and tuplets.
  /// Multi-measure rests require measure expansion and are handled separately.
  BeatFraction get duration {
    if (!isTimed) throw const FormatException('音符または休符ではありません。');
    final code = rhythm.substring(rhythm.indexOf('_') + 1);
    if (RegExp(r'^\d+m$').hasMatch(code)) throw const FormatException('複数小節休符は別途展開が必要です。');
    final match = RegExp(r'^(\d+)(G?)(\.{0,2})$').firstMatch(code);
    if (match == null) throw FormatException('音価を解釈できません: $rhythm');
    if (match.group(2) == 'G') return BeatFraction.zero;
    final base = int.parse(match.group(1)!);
    var duration = BeatFraction(4, base == 0 ? 1 : base);
    var increment = duration;
    for (var i = 0; i < match.group(3)!.length; i++) {
      increment = increment * BeatFraction(1, 2);
      duration = duration + increment;
    }
    return duration;
  }
}

/// The `chord` marker joins the next symbol to the immediately prior group.
/// Reject malformed markers instead of inventing timing for corrupted input.
List<List<OmrSymbol>> groupOmrChords(List<OmrSymbol> symbols) {
  final groups = <List<OmrSymbol>>[];
  var waitingForChord = false;
  for (final symbol in symbols) {
    if (symbol.rhythm == 'chord') {
      if (waitingForChord || groups.isEmpty) throw const FormatException('和音マーカーの位置が不正です。');
      waitingForChord = true;
    } else if (waitingForChord) {
      groups.last.add(symbol);
      waitingForChord = false;
    } else {
      groups.add([symbol]);
    }
  }
  if (waitingForChord) throw const FormatException('和音マーカーの後に音がありません。');
  return groups;
}

/// Cursor advance for a group of simultaneous symbols. Individual chord
/// members keep their own duration; grace notes do not advance the cursor.
BeatFraction chordAdvance(List<OmrSymbol> chord) {
  BeatFraction? shortest;
  for (final symbol in chord.where((s) => s.isTimed)) {
    final duration = symbol.duration;
    if (duration.compareTo(BeatFraction.zero) > 0 && (shortest == null || duration.compareTo(shortest) < 0)) {
      shortest = duration;
    }
  }
  return shortest ?? BeatFraction.zero;
}
