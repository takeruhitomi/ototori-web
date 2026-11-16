import 'dart:convert';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:choir_mobile/score.dart';
import 'package:choir_mobile/staff_math.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> ev(String onset, String duration, List<int> pitches, {Map<String, dynamic>? place, bool tieStart = false, bool tieStop = false}) => {
  'onset': onset, 'duration': duration, 'pitches': pitches, 'voice': 0,
  if (tieStart) 'tie_start': true, if (tieStop) 'tie_stop': true,
  'slur_starts': <String>[], 'slur_stops': <String>[], if (place != null) 'place': place,
};

const lines = [100.0, 110.0, 120.0, 130.0, 140.0];
ScoreDocument doc() => ScoreDocument.parse(jsonEncode({'title': 'Bars', 'staves': [
  {'id': 'A', 'role': 'voice', 'octave_shift': 0, 'measures': [
    {'number': 1, 'time_sig': [4, 4], 'key_fifths': 0, 'clef': 'G',
      'bounds': {'x0': 0, 'lines0': lines, 'x1': 400, 'lines1': lines},
      'events': [
        ev('0', '1', [64], place: {'x': 50.0, 'heads': [{'pitch': 64, 'x': 50.0, 'y': 140.0, 'confidence': 1.0, 'snapped': true}]}),
        ev('1', '2', [], place: {'x': 150.0, 'confidence': 0.0, 'snapped': false}),
        ev('3', '1', [60, 67], place: {'x': 300.0, 'heads': [
          {'pitch': 67, 'x': 300.0, 'y': 125.0, 'confidence': 1.0, 'snapped': true},
          {'pitch': 60, 'x': 300.0, 'y': 150.0, 'confidence': 1.0, 'snapped': false},
        ]}, tieStart: true),
      ]},
    {'number': 2, 'time_sig': [4, 4], 'events': [ev('0', '4', [60, 67], tieStop: true)]},
  ]},
]}));

List<List> pitches(ScoreDocument d, int m) => [for (final e in d.events(0, m)) e['pitches'] as List];

void main() {
  test('rest to note and back keeps bar length and undoes exactly', () {
    final d = doc();
    final original = d.encode();
    d.restToNote(0, 0, 1, 62, head: (x: 150, y: 145, written: 62));
    expect(pitches(d, 0), [[64], [62], [60, 67]]);
    final heads = ScoreDocument.headsInPitchOrder(d.event(0, 0, 1))!;
    expect(heads.single['manual'], true);
    d.noteToRest(0, 0, 0);
    expect(pitches(d, 0)[0], isEmpty);
    expect(d.event(0, 0, 0)['place'], {'x': 50.0});
    d.undo(); d.undo();
    expect(d.encode(), original);
    d.redo();
    expect(pitches(d, 0)[1], [62]);
  });

  test('split, insert and pitch edits survive save and reload in any order', () {
    final d = doc();
    final original = d.encode();
    d.transpose(0, 0, 0, 0, 1); // event 0 before the split shifts indexes
    d.split(0, 0, 1);
    expect([for (final e in d.events(0, 0)) '${e['onset']}+${e['duration']}'], ['0+1', '1+1', '2+1', '3+1']);
    expect(d.event(0, 0, 2)['place']['x'], 225.0);
    d.restToNote(0, 0, 2, 65);
    d.transpose(0, 0, 3, 0, -1); // tie chain into bar 2
    expect(pitches(d, 1).single, [59, 67]);
    final reopened = ScoreDocument.fromProject(d.encodeProject());
    expect(jsonDecode(d.encodeProject())['_choir_mobile_history']['version'], 4);
    expect(reopened.encode(), d.encode());
    for (var i = 0; i < 4; i++) { reopened.undo(); }
    expect(reopened.encode(), original);
    for (var i = 0; i < 4; i++) { reopened.redo(); }
    expect(reopened.encode(), d.encode());
    expect(reopened.identity.toJson()['parts'], d.identity.toJson()['parts']);
  });

  test('a note turned into a rest drops the tie on the other side of the barline', () {
    final d = doc();
    d.noteToRest(0, 0, 2);
    expect(d.event(0, 1, 0).containsKey('tie_stop'), false);
    d.undo();
    expect(d.event(0, 1, 0)['tie_stop'], true);
  });

  test('merging joins durations and the next event disappears', () {
    final d = doc();
    d.mergeWithNext(0, 0, 0);
    expect([for (final e in d.events(0, 0)) e['duration']], ['3', '1']);
    expect(pitches(d, 0).first, [64]);
    expect(() => d.mergeWithNext(0, 1, 0), throwsFormatException);
    d.undo();
    expect(d.events(0, 0), hasLength(3));
  });

  test('pitch edits move the matching head; chord tones stay aligned with heads', () {
    final d = doc();
    d.transpose(0, 0, 2, 0, 2); // 60 -> 62: the lower head (y 150)
    var heads = ScoreDocument.headsInPitchOrder(d.event(0, 0, 2))!;
    expect([for (final h in heads) h['pitch']], [62, 67]);
    d.addChordTone(0, 0, 2, 64, head: (x: 300, y: 140, written: 64));
    expect(pitches(d, 0)[2], [62, 64, 67]);
    heads = ScoreDocument.headsInPitchOrder(d.event(0, 0, 2))!;
    expect([for (final h in heads) h['pitch']], [62, 64, 67]);
    d.removeChordTone(0, 0, 2, 0);
    expect(pitches(d, 0)[2], [64, 67]);
    expect([for (final h in ScoreDocument.headsInPitchOrder(d.event(0, 0, 2))!) h['pitch']], [64, 67]);
  });

  test('tampered structural history is rejected before use', () {
    final d = doc()..split(0, 0, 1);
    final saved = jsonDecode(d.encodeProject());
    saved['_choir_mobile_history']['undo'][0][0]['after'][1]['event']['duration'] = '3';
    expect(() => ScoreDocument.fromProject(jsonEncode(saved)), throwsFormatException);
    final other = jsonDecode(d.encodeProject());
    other['_choir_mobile_history']['undo'][0][0]['measure_id'] = 'missing';
    expect(() => ScoreDocument.fromProject(jsonEncode(other)), throwsFormatException);
  });

  test('dotted values split unevenly and tiny values are refused', () {
    final d = ScoreDocument.parse(jsonEncode({'staves': [{'measures': [{'events': [ev('0', '3/2', [60]), ev('3/2', '5/2', [])]}]}]}));
    d.split(0, 0, 0, first: BeatFraction(1, 1));
    expect([for (final e in d.events(0, 0)) e['duration']], ['1', '1/2', '5/2']);
    expect(() => d.split(0, 0, 0, first: BeatFraction(1, 1)), throwsFormatException);
  });

  test('staff math spells in the key and maps steps to page heights', () {
    expect(stepOf(60, 0), 28);
    expect(stepOf(66, 1), stepOf(65, 0)); // F♯ in G major sits on F
    expect(stepOf(70, -1), stepOf(71, 0)); // B♭ in F major sits on B
    expect(pitchAtStep(stepOf(66, 2), 2), 66);
    expect(accidental(66, 0), '♯');
    expect(accidental(65, 1), '♮');
    expect(accidental(66, 1), '');
    expect(spelledName(70, -2), 'B♭4');
    final staff = StaffLines(0, lines, 400, [for (final l in lines) l + 8]);
    expect(staff.yOf(30, 0, clefBottom('G')), 140); // E4 on the bottom line
    expect(staff.yOf(38, 400, 30), 108); // F5 on the top line, 8 px lower at the right
    expect(staff.stepAt(126, 200, 30), 34);
  });
}
