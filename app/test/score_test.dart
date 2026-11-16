import 'dart:convert';
import 'package:choir_mobile/score.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String fixture({bool tie = false}) => jsonEncode({
    'title': 'test', 'tempo_bpm': 120, 'extra': {'preserved': true},
    'staves': [{'id': 'v1', 'measures': [{'number': 1, 'events': [
      {'onset': '1/2', 'duration': '3/2', 'pitches': [60, 64], 'tie_start': tie, 'slur_starts': ['s1']},
      {'onset': '2/1', 'duration': '1/1', 'pitches': []},
    ]}]}],
  });

  test('edits a single chord pitch and preserves timing, metadata and slurs', () {
    final score = ScoreDocument.parse(fixture());
    score.transpose(0, 0, 0, 1, 1);
    final result = jsonDecode(score.encode());
    final event = result['staves'][0]['measures'][0]['events'][0];
    expect(event['pitches'], [60, 65]);
    expect(event['onset'], '1/2');
    expect(event['duration'], '3/2');
    expect(event['slur_starts'], ['s1']);
    expect(result['extra']['preserved'], true);
    score.undo(); expect(score.events(0, 0)[0]['pitches'], [60, 64]);
    score.redo(); expect(score.events(0, 0)[0]['pitches'], [60, 65]);
  });

  test('preview preserves chord onset and duration at the given tempo', () {
    final score = ScoreDocument.parse(fixture());
    expect(score.preview(0, 0), [
      {'pitch': 60, 'start': 250, 'duration': 750},
      {'pitch': 64, 'start': 250, 'duration': 750},
    ]);
  });

  test('imports a UTF-8 BOM-prefixed score', () {
    expect(ScoreDocument.parse('\uFEFF${fixture()}').staves, hasLength(1));
  });

  test('unresolved ties cannot be edited or played by the legacy isolated preview', () {
    final score = ScoreDocument.parse(fixture(tie: true));
    expect(() => score.transpose(0, 0, 0, 0, 1), throwsFormatException);
    expect(() => score.preview(0, 0), throwsFormatException);
    expect(score.events(0, 0)[0]['pitches'], [60, 64]);
  });

  test('staff preview refuses repeat notation rather than playing a misleading order', () {
    final score = ScoreDocument.parse(fixture());
    score.measures(0)[0]['repeat_end'] = 2;
    expect(() => score.previewStaff(0), throwsFormatException);
    score.measures(0)[0]['repeat_end'] = 0;
    expect(score.previewStaff(0), score.preview(0, 0));
  });
}
