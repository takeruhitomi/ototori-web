import 'dart:math' as math;

import 'playback_timeline.dart';

/// Conservative just intonation, ported from experiments/just_intonation/tuning.py.
///
/// Only complete major/minor triads are tuned. The root stays on the
/// equal-tempered grid (no drift); thirds and fifths move to pure ratios.
/// A held note whose wanted correction changes, or that sounds through any
/// unrecognized moment, stays equal-tempered. Analysis uses the whole sung
/// ensemble, before mute/solo, so a part sounds the same when soloed.
class JustIntonationPlan {
  JustIntonationPlan._(this.cents, this.segments);

  /// Correction per timeline note (same index as [PlaybackTimeline.notes]).
  final List<double> cents;

  /// Every time slice between note boundaries, with its chord (or none).
  final List<ChordSegment> segments;

  int get tunedNotes => cents.where((c) => c != 0).length;

  /// Sung parts take part; the piano stays equal-tempered and grace notes
  /// are too short to define a chord.
  static bool participates(PlaybackNote n) => !n.grace && n.role != 'piano_rh' && n.role != 'piano_lh';

  factory JustIntonationPlan.build(List<PlaybackNote> notes, {bool Function(PlaybackNote)? include}) {
    final take = include ?? participates;
    final index = [for (var i = 0; i < notes.length; i++) if (take(notes[i]) && notes[i].duration > 0) i];
    // Beats come from fractions through doubles; snap boundaries so float
    // noise cannot create microscopic slices.
    int key(double beat) => (beat * 1e6).round();
    final bounds = {for (final i in index) ...[key(notes[i].start), key(notes[i].start + notes[i].duration)]}.toList()..sort();
    int lower(int k) {
      var lo = 0, hi = bounds.length;
      while (lo < hi) { final mid = (lo + hi) >> 1; if (bounds[mid] < k) { lo = mid + 1; } else { hi = mid; } }
      return lo;
    }
    final masks = List<int>.filled(math.max(0, bounds.length - 1), 0);
    final spans = <int, (int, int)>{};
    for (final i in index) {
      final n = notes[i];
      final span = (lower(key(n.start)), lower(key(n.start + n.duration)));
      spans[i] = span;
      for (var s = span.$1; s < span.$2; s++) { masks[s] |= 1 << (n.pitch % 12); }
    }
    final chords = [for (final m in masks) detectTriad(m)];
    final cents = List<double>.filled(notes.length, 0);
    for (final i in index) {
      final (first, last) = spans[i]!;
      double? wanted;
      var stable = first < last;
      for (var s = first; s < last && stable; s++) {
        final chord = chords[s];
        if (chord == null) { stable = false; break; }
        final value = triadCents((notes[i].pitch - chord.root) % 12, chord.minor);
        if (wanted == null) { wanted = value; } else if ((value - wanted).abs() > 1e-8) { stable = false; }
      }
      if (stable && wanted != null) cents[i] = wanted;
    }
    return JustIntonationPlan._(cents, [
      for (var s = 0; s < masks.length; s++)
        ChordSegment(bounds[s] / 1e6, bounds[s + 1] / 1e6, chords[s]?.root, chords[s]?.minor ?? false),
    ]);
  }

  /// Chord sounding at [beat], or null for silence/unrecognized harmony.
  ChordSegment? chordAt(double beat) {
    var lo = 0, hi = segments.length;
    while (lo < hi) { final mid = (lo + hi) >> 1; if (segments[mid].start <= beat + 1e-9) { lo = mid + 1; } else { hi = mid; } }
    if (lo == 0) return null;
    final s = segments[lo - 1];
    return beat < s.end && s.root != null ? s : null;
  }

  /// Writes the corrections into the timeline notes (zero when [on] is false).
  void applyTo(List<PlaybackNote> notes, {required bool on}) {
    for (var i = 0; i < notes.length && i < cents.length; i++) { notes[i].cents = on ? cents[i] : 0; }
  }
}

class ChordSegment {
  const ChordSegment(this.start, this.end, this.root, this.minor);
  final double start, end;
  /// Pitch class 0 (C) .. 11 (B); null when no triad was recognized.
  final int? root;
  final bool minor;

  static const _names = ['C', 'C♯', 'D', 'E♭', 'E', 'F', 'F♯', 'G', 'A♭', 'A', 'B♭', 'B'];
  /// Pitch-class name only: the timeline has no written spelling, so
  /// enharmonics are not decided here (C♯ may be written D♭).
  String? get label => root == null ? null : '${_names[root!]}${minor ? 'm' : ''}';
}

/// Exact complete major/minor triad from a 12-bit pitch-class mask.
({int root, bool minor})? detectTriad(int mask) {
  int shape(int root, int third) => (1 << root) | (1 << (root + third) % 12) | (1 << (root + 7) % 12);
  for (var root = 0; root < 12; root++) {
    if (mask == shape(root, 4)) return (root: root, minor: false);
    if (mask == shape(root, 3)) return (root: root, minor: true);
  }
  return null;
}

/// Cents from equal temperament for a chord tone [interval] semitones above the root.
double triadCents(int interval, bool minor) {
  double cents(double ratio) => 1200 * math.log(ratio) / math.ln2;
  return switch (interval) {
    0 => 0,
    3 => cents(6 / 5) - 300,
    4 => cents(5 / 4) - 400,
    7 => cents(3 / 2) - 700,
    _ => throw ArgumentError('not a triad tone: $interval'),
  };
}
