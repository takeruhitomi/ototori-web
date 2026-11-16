import 'dart:convert';
import 'package:choir_mobile/score.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> note({bool start = false, bool stop = false, int voice = 0}) => {
  'onset': '0/1', 'duration': '4/1', 'pitches': [60, 64], 'voice': voice,
  'tie_start': start, 'tie_stop': stop, 'slur_starts': ['phrase'],
};
ScoreDocument score(List<List<Map<String, dynamic>>> bars) => ScoreDocument.parse(jsonEncode({
  'title': 'Ties', 'meta': {'untouched': true}, 'staves': [
    {'id': 'S1', 'measures': [for (final events in bars) {'time_sig': [4, 4], 'events': events}]}
  ],
}));

void main() {
  test('edits a chord pitch throughout a tie chain and undoes it atomically after restore', () {
    final doc = score([[note(start: true)], [note(start: true, stop: true)], [note(stop: true)], [note()]]);
    final original = doc.encode();
    doc.transpose(0, 1, 0, 1, 12);
    expect(doc.revision, 1);
    for (var m = 0; m < 3; m++) { expect(doc.events(0, m)[0]['pitches'], [60, 76]); }
    expect(doc.events(0, 3)[0]['pitches'], [60, 64]);
    expect(doc.events(0, 1)[0]['slur_starts'], ['phrase']);
    final restored = ScoreDocument.fromProject(doc.encodeProject());
    restored.undo();
    expect(restored.revision, 2);
    expect(restored.encode(), original);
    restored.redo();
    expect(restored.revision, 3);
    expect(restored.encode(), doc.encode());
  });
  test('rejects ambiguous forks and out-of-range edits without partial changes', () {
    final ambiguous = score([[note(start: true)], [note(stop: true), note(stop: true)]]);
    final original = ambiguous.encode();
    expect(() => ambiguous.transpose(0, 0, 0, 0, 1), throwsFormatException);
    expect(ambiguous.encode(), original);
    expect(ambiguous.canUndo, false);
    final valid = score([[note(start: true)], [note(stop: true)]]);
    final before = valid.encode();
    expect(() => valid.transpose(0, 0, 0, 0, 100), throwsFormatException);
    expect(valid.encode(), before);
  });
  test('prefers a unique matching voice without changing a parallel voice', () {
    final doc = score([[note(start: true)], [note(stop: true), note(stop: true, voice: 1)]]);
    doc.transpose(0, 0, 0, 0, -1);
    expect(doc.events(0, 1)[0]['pitches'], [59, 64]);
    expect(doc.events(0, 1)[1]['pitches'], [60, 64]);
  });
  test('does not edit through a one-way cross-voice match', () {
    final doc = score([[note(start: true)], [note(stop: true), note(stop: true, voice: 1)]]);
    final original = doc.encode();
    expect(() => doc.transpose(0, 1, 1, 0, 1), throwsFormatException);
    expect(doc.encode(), original);
  });
  test('continues to restore version 1 single-note history', () {
    final doc = score([[note()]]);
    doc.transpose(0, 0, 0, 0, 1);
    final stored = jsonDecode(doc.encode());
    stored['_choir_mobile_history'] = {'version': 1, 'undo': [[0, 0, 0, 0, 60, 61]], 'redo': []};
    final restored = ScoreDocument.fromProject(jsonEncode(stored));
    restored.undo();
    expect(restored.events(0, 0)[0]['pitches'], [60, 64]);
  });
}
