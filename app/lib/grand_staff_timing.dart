/// Grand-staff timing from the decoder's attention x.
///
/// Each piano staff is decoded on its own, so a bar whose notes are shared
/// between the hands (a cross-staff arpeggio, a melody handed over to the
/// other hand) or whose reading lost a note comes back too short, and the
/// rest that fills it is placed at the bar end. The PC version reads such
/// bars with homr's grand-staff cursor; this does the same with the x the
/// decoder attended to: attacks of both hands at about the same x sound
/// together, and the cursor advances to the next pending release
/// (homr_timing.py). Only bars that the independent reading cannot fit are
/// touched, and only when the joint reading fills the bar exactly.
library;

import 'omr_symbols.dart';

class _Group {
  _Group(this.tokens, this.x, this.advance, this.wholeRest);
  final List<OmrSymbol> tokens; // original tokens (graces before it, chord markers)
  final double x;
  final BeatFraction advance;
  final bool wholeRest;
  BeatFraction onset = BeatFraction.zero;
}

class _Bar {
  final raw = <OmrSymbol>[]; // every token of the bar, closing barline included
  final lead = <OmrSymbol>[]; // clef / key / time before the first note
  final groups = <_Group>[];
  final close = <OmrSymbol>[]; // closing barline
  bool alignable = true; // false: mid-bar clef, multi-bar rest, missing x ...
  BeatFraction get sum => groups.fold(BeatFraction.zero, (a, g) => a + g.advance);
}

const _chordMarker = OmrSymbol(rhythm: 'chord', pitch: '.', lift: '.', position: '.', articulation: '.', slur: '.');

bool _isBarline(OmrSymbol s) => s.rhythm == 'barline' || s.rhythm.startsWith('repeat');
final _multiRest = RegExp(r'_\d+m$');

List<OmrSymbol> _withMarkers(List<OmrSymbol> group) => [
  for (var i = 0; i < group.length; i++) ...[
    if (i > 0) _chordMarker,
    group[i],
  ],
];

/// Tokens of one staff split at barlines.
List<_Bar> _bars(List<OmrSymbol> symbols) {
  final bars = <_Bar>[];
  var bar = _Bar();
  var graces = <OmrSymbol>[];
  for (final group in groupOmrChords(symbols)) {
    final tokens = _withMarkers(group);
    bar.raw.addAll(tokens);
    if (_isBarline(group.first)) {
      if (graces.isNotEmpty) bar.alignable = false;
      bar.close.addAll(tokens);
      bars.add(bar);
      bar = _Bar();
      graces = [];
      continue;
    }
    final timed = group.where((s) => s.isTimed).toList();
    if (timed.isEmpty) {
      if (bar.groups.isNotEmpty || graces.isNotEmpty) bar.alignable = false;
      bar.lead.addAll(tokens);
      continue;
    }
    if (group.length != timed.length || timed.any((s) => _multiRest.hasMatch(s.rhythm))) {
      bar.alignable = false;
      continue;
    }
    if (timed.every((s) => s.isGrace)) { graces.addAll(tokens); continue; }
    final xs = [for (final s in timed) if (!s.isGrace && s.x != null) s.x!];
    final advance = chordAdvance(group);
    if (xs.isEmpty || advance <= BeatFraction.zero) { bar.alignable = false; continue; }
    final wholeRest = timed.length == 1 && timed.first.rhythm == 'rest_1';
    bar.groups.add(_Group([...graces, ...tokens], xs.reduce((a, b) => a + b) / xs.length, advance, wholeRest));
    graces = [];
  }
  if (graces.isNotEmpty) bar.alignable = false;
  if (bar.raw.isNotEmpty) bars.add(bar);
  return bars;
}

/// homr's grand-staff cursor over both hands' groups merged by x.
/// Returns false when a hand overruns [length] or no hand fills the bar.
bool _jointTiming(List<List<_Group>> hands, BeatFraction length, double tolerance) {
  // Attention x is noisy; keep each hand in reading order.
  final xs = <List<double>>[];
  for (final hand in hands) {
    var last = double.negativeInfinity;
    xs.add([for (final g in hand) last = g.x > last ? g.x : last]);
  }
  final next = List.filled(hands.length, 0);
  final ends = List.filled(hands.length, BeatFraction.zero);
  BeatFraction? previous;
  while (true) {
    var first = -1;
    for (var h = 0; h < hands.length; h++) {
      if (next[h] < hands[h].length && (first < 0 || xs[h][next[h]] < xs[first][next[first]])) first = h;
    }
    if (first < 0) break;
    final x0 = xs[first][next[first]];
    final column = [for (var h = 0; h < hands.length; h++)
      if (next[h] < hands[h].length && xs[h][next[h]] - x0 <= tolerance) h];
    var t = BeatFraction.zero;
    if (previous != null) {
      // Advance to the next release after the previous attack.
      BeatFraction? release;
      for (final e in ends) {
        if (e > previous && (release == null || e < release)) release = e;
      }
      t = release ?? previous;
    }
    for (final h in column) { t = BeatFraction.max(t, ends[h]); }
    for (final h in column) {
      final g = hands[h][next[h]++];
      g.onset = t;
      ends[h] = t + g.advance;
      if (ends[h] > length) return false;
    }
    previous = t;
  }
  return ends.any((e) => e == length);
}

/// Rest tokens filling [gap] (greedy over plain and triplet values).
List<OmrSymbol>? _rests(BeatFraction gap) {
  const values = [('rest_1', 4, 1), ('rest_2', 2, 1), ('rest_4', 1, 1), ('rest_8', 1, 2), ('rest_16', 1, 4),
    ('rest_32', 1, 8), ('rest_6', 2, 3), ('rest_12', 1, 3), ('rest_24', 1, 6)];
  final out = <OmrSymbol>[];
  var left = gap;
  for (final (rhythm, n, d) in values) {
    final v = BeatFraction(n, d);
    while (left >= v) {
      out.add(OmrSymbol(rhythm: rhythm, pitch: '_', lift: '_', position: 'upper', articulation: '_', slur: '_'));
      left = left - v;
    }
  }
  return left == BeatFraction.zero ? out : null;
}

/// The bar re-timed: rests fill the gaps before groups that start later.
List<OmrSymbol>? _emitTimed(_Bar bar, List<_Group> groups) {
  final out = <OmrSymbol>[...bar.lead];
  var cursor = BeatFraction.zero;
  for (final g in groups) {
    if (g.onset > cursor) {
      final rests = _rests(g.onset - cursor);
      if (rests == null) return null;
      out.addAll(rests);
    }
    out.addAll(g.tokens);
    cursor = g.onset + g.advance;
  }
  out.addAll(bar.close);
  return out;
}

List<double> _monotoneX(List<_Group> groups) {
  var last = double.negativeInfinity;
  return [for (final g in groups) last = g.x > last ? g.x : last];
}

/// Onsets of [broken]'s groups read off the x positions of [anchor], a hand
/// that fills the bar on its own: an attack at about an anchor's x shares
/// its onset, others are interpolated between the anchors and rounded to
/// the bar's finest note value. Onsets may overlap (a second voice under a
/// long note). False when the result does not stay inside the bar.
bool _interpolatedTiming(List<_Group> anchor, List<_Group> broken, BeatFraction length, double tolerance) {
  if (anchor.length < 2) return false;
  final ax = _monotoneX(anchor);
  final at = <BeatFraction>[];
  var t = BeatFraction.zero;
  for (final g in anchor) { at.add(t); g.onset = t; t = t + g.advance; }
  final span = ax.last - ax.first;
  final beats = (at.last - at.first);
  if (span <= 0 || beats <= BeatFraction.zero) return false;
  final pxPerBeat = span / (beats.numerator / beats.denominator);
  var step = [...anchor, ...broken].map((g) => g.advance).reduce(BeatFraction.min);
  if (step > BeatFraction(1, 2)) step = BeatFraction(1, 2);
  double value(BeatFraction f) => f.numerator / f.denominator;
  BeatFraction snap(double beat) {
    final n = (beat / value(step)).round();
    return step * BeatFraction.of(n < 0 ? 0 : n);
  }
  final bx = _monotoneX(broken);
  BeatFraction? previous;
  double? previousX;
  for (var i = 0; i < broken.length; i++) {
    final x = bx[i];
    BeatFraction onset;
    var nearest = 0;
    for (var j = 1; j < ax.length; j++) {
      if ((ax[j] - x).abs() < (ax[nearest] - x).abs()) nearest = j;
    }
    if ((ax[nearest] - x).abs() <= tolerance) {
      onset = at[nearest];
    } else {
      double beat;
      if (x <= ax.first) {
        beat = value(at.first) - (ax.first - x) / pxPerBeat;
      } else if (x >= ax.last) {
        beat = value(at.last) + (x - ax.last) / pxPerBeat;
      } else {
        var j = 0;
        while (ax[j + 1] < x) { j++; }
        final f = (x - ax[j]) / (ax[j + 1] - ax[j]);
        beat = value(at[j]) + f * (value(at[j + 1]) - value(at[j]));
      }
      onset = snap(beat);
    }
    if (previous != null) {
      // Reading order: never earlier than the previous attack, and a later
      // attack at a clearly different x does not share its onset.
      if (onset < previous) onset = previous;
      if (onset == previous && x - previousX! > tolerance) onset = previous + step;
    }
    if (onset + broken[i].advance > length) return false;
    broken[i].onset = onset;
    previous = onset;
    previousX = x;
  }
  return true;
}

OmrSymbol _restToken(String rhythm, {bool spacer = false}) => OmrSymbol(rhythm: rhythm, pitch: '_', lift: '_',
  position: 'upper', articulation: spacer ? spacerArticulation : '_', slur: '_');

/// Single (possibly dotted) rest token of exactly [d] beats, or null.
String? _restRhythm(BeatFraction d) {
  for (final base in [1, 2, 4, 8, 16, 32, 6, 12, 24]) {
    for (final dots in ['', '.', '..']) {
      final rhythm = 'rest_$base$dots';
      if (_restToken(rhythm).duration == d) return rhythm;
    }
  }
  return null;
}

/// The bar with groups that may overlap: groups starting together become one
/// chord, and a spacer rest makes a chord advance only to the next onset.
List<OmrSymbol>? _emitColumns(_Bar bar, List<_Group> groups, BeatFraction length) {
  final out = <OmrSymbol>[...bar.lead];
  final onsets = groups.map((g) => g.onset).toSet().toList()..sort();
  var cursor = BeatFraction.zero;
  for (var c = 0; c < onsets.length; c++) {
    final t = onsets[c];
    if (t > cursor) {
      final rests = _rests(t - cursor);
      if (rests == null) return null;
      out.addAll(rests);
    }
    final column = groups.where((g) => g.onset == t).toList();
    final next = c + 1 < onsets.length ? onsets[c + 1] : null;
    final shortest = column.map((g) => g.advance).reduce(BeatFraction.min);
    for (var i = 0; i < column.length; i++) {
      // Graces of a later group would split the chord.
      if (i > 0) {
        if (column[i].tokens.first.isGrace) return null;
        out.add(_chordMarker);
      }
      out.addAll(column[i].tokens);
    }
    var advance = shortest;
    if (next != null && shortest > next - t) {
      final spacer = _restRhythm(next - t);
      if (spacer == null) return null;
      out..add(_chordMarker)..add(_restToken(spacer, spacer: true));
      advance = next - t;
    }
    cursor = t + advance;
  }
  if (cursor > length) return null;
  out.addAll(bar.close);
  return out;
}

/// Diagnostics hook (evaluation only): receives why a bar was left alone.
void Function(String reason)? grandStaffDebug;

class GrandStaffTiming {
  GrandStaffTiming(this.right, this.left, this.changedBars);
  final List<OmrSymbol> right, left;
  final List<int> changedBars;
}

/// Re-times the bars of a grand staff ([right], [left] upper-position token
/// lists) whose hands do not fill [barLengths] (null = unknown, left alone).
/// [tolerance] is the x distance (pixels) within which attacks of the two
/// hands count as simultaneous. Returns null when nothing changed.
GrandStaffTiming? alignGrandStaff(List<OmrSymbol> right, List<OmrSymbol> left,
    List<BeatFraction?> barLengths, double tolerance) {
  final List<_Bar> rb, lb;
  try {
    rb = _bars(right); lb = _bars(left);
  } on FormatException {
    return null;
  }
  if (rb.length != lb.length) return null;
  final changed = <int>[];
  final outR = <OmrSymbol>[], outL = <OmrSymbol>[];
  for (var k = 0; k < rb.length; k++) {
    final r = rb[k], l = lb[k];
    final length = k < barLengths.length ? barLengths[k] : null;
    List<OmrSymbol>? newR, newL;
    final broken = length != null && (r.sum != length || l.sum != length);
    if (broken && !(r.alignable && l.alignable && r.groups.isNotEmpty && l.groups.isNotEmpty)) {
      grandStaffDebug?.call('not alignable');
    }
    var why = 'joint overrun/unfilled';
    if (broken && r.alignable && l.alignable && r.groups.isNotEmpty && l.groups.isNotEmpty) {
      // A whole-bar rest next to notes of the same hand is a misreading.
      for (final dropRests in [false, true]) {
        List<_Group> keep(_Bar b) => dropRests && b.groups.length > 1 ? b.groups.where((g) => !g.wholeRest).toList() : b.groups;
        final hands = [keep(r), keep(l)];
        if (dropRests && hands[0].length == r.groups.length && hands[1].length == l.groups.length) continue;
        if (!_jointTiming(hands, length, tolerance)) continue;
        // A hand that already filled the bar on its own keeps its timing.
        bool keepsOwnTiming(_Bar b, List<_Group> g) {
          if (b.sum != length) return true;
          if (g.length != b.groups.length) return false;
          var t = BeatFraction.zero;
          for (final x in g) {
            if (x.onset != t) return false;
            t = t + x.advance;
          }
          return true;
        }
        if (!keepsOwnTiming(r, hands[0]) || !keepsOwnTiming(l, hands[1])) { why = 'moves a fitting hand'; continue; }
        newR = _emitTimed(r, hands[0]);
        newL = _emitTimed(l, hands[1]);
        if (newR != null && newL != null) break;
        newR = newL = null;
      }
      // One hand fits and the other overruns it (a second voice read
      // serially): place the overrunning hand's attacks by x against it.
      final rightFits = r.sum == length;
      final anchor = rightFits ? r : l, other = rightFits ? l : r;
      if (newR == null && (r.sum == length) != (l.sum == length) && other.sum > length) {
        if (_interpolatedTiming(anchor.groups, other.groups, length, tolerance)) {
          final emitted = _emitColumns(other, other.groups, length);
          if (emitted != null) {
            newR = rightFits ? [...r.raw] : emitted;
            newL = rightFits ? emitted : [...l.raw];
          } else {
            why = 'interpolation not representable';
          }
        } else {
          why = 'interpolation overruns';
        }
      }
    }
    if (broken && (newR == null || newL == null) && r.alignable && l.alignable && r.groups.isNotEmpty && l.groups.isNotEmpty) {
      String g(_Bar b) => b.groups.map((x) => '${x.tokens.where((t) => t.isTimed).map((t) => t.rhythm.replaceAll('note_', '').replaceAll('rest_', 'r')).join('+')}@${x.x.round()}').join(' ');
      grandStaffDebug?.call('$why R=${r.sum} L=${l.sum} len=$length\n   R: ${g(r)}\n   L: ${g(l)}');
    }
    if (newR != null && newL != null) {
      grandStaffDebug?.call('changed');
      outR.addAll(newR); outL.addAll(newL);
      changed.add(k);
    } else {
      outR.addAll(r.raw); outL.addAll(l.raw);
    }
  }
  return changed.isEmpty ? null : GrandStaffTiming(outR, outL, changed);
}

/// Cursor advance summed per bar (null for bars with multi-bar rests).
List<BeatFraction?> barSums(List<OmrSymbol> symbols) {
  final out = <BeatFraction?>[];
  var sum = BeatFraction.zero;
  var multi = false;
  var open = false;
  for (final group in groupOmrChords(symbols)) {
    if (_isBarline(group.first)) {
      out.add(multi ? null : sum);
      sum = BeatFraction.zero; multi = false; open = false;
      continue;
    }
    open = true;
    if (group.any((s) => s.isTimed && _multiRest.hasMatch(s.rhythm))) { multi = true; continue; }
    if (group.any((s) => s.isTimed)) sum = sum + chordAdvance(group);
  }
  if (open) out.add(multi ? null : sum);
  return out;
}
