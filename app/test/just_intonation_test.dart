import 'dart:math' as math;

import 'package:choir_mobile/just_intonation.dart';
import 'package:choir_mobile/playback_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

PlaybackNote note(int pitch, double start, double duration, {String role = 'voice', bool grace = false}) =>
  PlaybackNote(staffId: 's', partId: role, role: role, pitch: pitch, start: start, duration: duration,
    velocity: 1, grace: grace, voice: 1, measure: 0, sourceMeasure: 0, legato: false);

double hz(PlaybackNote n) => 440 * math.pow(2, (n.pitch - 69) / 12 + n.cents / 1200).toDouble();

void main() {
  test('major and minor triads get pure ratios with the root fixed (same as tuning.py)', () {
    final major = [note(60, 0, 4), note(64, 0, 4), note(67, 0, 4)];
    JustIntonationPlan.build(major).applyTo(major, on: true);
    expect(major[0].cents, 0);
    expect(major[1].cents, closeTo(-13.686, 0.001));
    expect(major[2].cents, closeTo(1.955, 0.001));
    expect(hz(major[1]) / hz(major[0]), closeTo(1.25, 1e-9));
    expect(hz(major[2]) / hz(major[0]), closeTo(1.5, 1e-9));

    final minor = [note(57, 0, 4), note(60, 0, 4), note(64, 0, 4)];
    JustIntonationPlan.build(minor).applyTo(minor, on: true);
    expect(hz(minor[1]) / hz(minor[0]), closeTo(1.2, 1e-9));
  });

  test('inversions count; incomplete or extra tones abstain', () {
    expect(detectTriad(1 << 4 | 1 << 7 | 1 << 0), (root: 0, minor: false));
    expect(detectTriad(1 << 0 | 1 << 7), isNull);
    expect(detectTriad(1 << 0 | 1 << 4 | 1 << 5 | 1 << 7), isNull);
  });

  test('a held note whose role changes stays equal-tempered', () {
    final notes = [note(64, 0, 8), note(60, 0, 4), note(67, 0, 4), note(57, 4, 4), note(60, 4, 4)];
    final plan = JustIntonationPlan.build(notes);
    expect(plan.cents, [0, 0, closeTo(1.955, 0.001), 0, closeTo(15.641, 0.001)]);
    expect(plan.chordAt(1)?.label, 'C');
    expect(plan.chordAt(5)?.label, 'Am');
    expect(plan.chordAt(8), isNull);
  });

  test('piano and grace notes are left out of the analysis and stay at 0', () {
    final notes = [note(60, 0, 4), note(64, 0, 4), note(67, 0, 4),
      note(65, 0, 4, role: 'piano_rh'), note(62, 0, 0.1, grace: true)];
    final plan = JustIntonationPlan.build(notes);
    expect(plan.chordAt(0)?.label, 'C');
    expect(plan.cents[1], closeTo(-13.686, 0.001));
    expect(plan.cents.sublist(3), [0, 0]);
  });

  test('cents reach the playback events only while switched on', () {
    final notes = [note(60, 0, 4), note(64, 0, 4), note(67, 0, 4)];
    final timeline = PlaybackTimeline(notes: notes, order: const [0], measureStarts: const [0],
      measureLengths: const [4], warnings: const [], validRepeats: true);
    final plan = JustIntonationPlan.build(notes);
    plan.applyTo(notes, on: true);
    final events = timeline.events(tempo: 60);
    expect(events.firstWhere((e) => e['pitch'] == 64)['cents'], closeTo(-13.686, 0.001));
    expect(events.firstWhere((e) => e['pitch'] == 60).containsKey('cents'), isFalse);
    expect(events.firstWhere((e) => e['pitch'] == 64)['pitch'], 64);
    plan.applyTo(notes, on: false);
    expect(timeline.events(tempo: 60).any((e) => e.containsKey('cents')), isFalse);
  });
}
