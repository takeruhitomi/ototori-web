import 'dart:convert';
import 'package:choir_mobile/project_identity.dart';
import 'package:choir_mobile/score.dart';
import 'package:flutter_test/flutter_test.dart';

ScoreDocument document() => ScoreDocument.parse(jsonEncode({'title': 'IDs', 'staves': [
  {'id': 'Piano1', 'role': 'piano', 'measures': [{'events': [
    {'onset': '0/1', 'duration': '1/1', 'pitches': [60, 64], 'slur_starts': ['s1']},
    {'onset': '1/1', 'duration': '1/1', 'pitches': [67], 'slur_stops': ['s1']},
    {'onset': '2/1', 'duration': '2/1', 'pitches': []},
  ]}]},
  {'id': 'Piano2', 'role': 'piano', 'measures': [{'events': [
    {'onset': '0/1', 'duration': '4/1', 'pitches': [48]},
  ]}]},
]}));

void main() {
  test('keeps part, measure, chord and pitch identity across edits and reload', () {
    final score = document();
    final identity = score.identity.toJson();
    final original = score.encode();
    expect(score.identity.partId(0), isNot(score.identity.partId(1)));
    expect(score.identity.pitchId(0, 0, 0, 0), isNot(score.identity.pitchId(0, 0, 0, 1)));
    score.transpose(0, 0, 0, 1, 1);
    score.undo(); score.redo();
    expect(score.revision, 3);
    final reopened = ScoreDocument.fromProject(score.encodeProject());
    final savedIdentity = reopened.identity.toJson()..['revision'] = 0;
    expect(savedIdentity, identity);
    expect(reopened.revision, 3);
    reopened.undo();
    expect(reopened.encode(), original);
    expect(reopened.revision, 4);
    expect(reopened.identity.noteId(0, 0, 0), score.identity.noteId(0, 0, 0));
    expect(jsonDecode(reopened.encode()).containsKey('_choir_mobile_document'), false);
    expect(reopened.data.containsKey('_choir_mobile_history'), false);
  });
  test('new import is a distinct document while repeated saves keep their revision', () {
    final score = document();
    expect(document().identity.documentId, isNot(score.identity.documentId));
    expect(ScoreDocument.parse(score.encode()).identity.documentId, isNot(score.identity.documentId));
    expect(score.encodeProject(), score.encodeProject());
    score.transpose(0, 0, 0, 0, 0);
    score.undo(); score.redo();
    expect(score.revision, 0);
    expect(score.canUndo, false);
  });
  test('history follows saved IDs when event and pitch positions change together', () {
    final score = document();
    score.transpose(0, 0, 0, 0, 1);
    final saved = jsonDecode(score.encodeProject());
    final notes = saved['staves'][0]['measures'][0]['events'] as List;
    final ids = saved['_choir_mobile_document']['parts'][0]['measures'][0]['notes'] as List;
    final chord = notes.removeAt(0);
    final chordId = ids.removeAt(0);
    chord['pitches'] = (chord['pitches'] as List).reversed.toList();
    chordId['pitch_ids'] = (chordId['pitch_ids'] as List).reversed.toList();
    notes.add(chord); ids.add(chordId);
    final restored = ScoreDocument.fromProject(jsonEncode(saved));
    restored.undo();
    expect(restored.events(0, 0)[2]['pitches'], [64, 60]);
    expect(restored.events(0, 0)[0]['pitches'], [67]);
    restored.redo();
    expect(restored.events(0, 0)[2]['pitches'], [64, 61]);
  });
  test('rejects duplicate IDs, unsupported schemas and mismatched structure', () {
    void invalid(void Function(dynamic) mutate) {
      final saved = jsonDecode(document().encodeProject());
      mutate(saved['_choir_mobile_document']);
      expect(() => ScoreDocument.fromProject(jsonEncode(saved)), throwsFormatException);
    }
    invalid((m) => m['schema_version'] = 99);
    invalid((m) => m['parts'][1]['part_id'] = m['parts'][0]['part_id']);
    invalid((m) => m['parts'][0]['measures'][0]['notes'].removeLast());
    invalid((m) => m['parts'][0]['measures'][0]['notes'][0]['pitch_ids'] = []);
    invalid((m) => m['revision'] = -1);
  });
  test('rejects history referencing a different parent without applying it', () {
    final score = document()..transpose(0, 0, 0, 0, 1);
    final saved = jsonDecode(score.encodeProject());
    saved['_choir_mobile_history']['undo'][0][0]['part_id'] = score.identity.partId(1);
    expect(() => ScoreDocument.fromProject(jsonEncode(saved)), throwsFormatException);
    saved.remove('_choir_mobile_document');
    expect(() => ScoreDocument.fromProject(jsonEncode(saved)), throwsFormatException);
  });
  test('migrates version 2 grouped history and writes version 3 IDs', () {
    final saved = jsonDecode(document().encode());
    saved['staves'][0]['measures'][0]['events'][0]['pitches'] = [61, 65];
    saved['_choir_mobile_history'] = {'version': 2, 'undo': [
      [[0, 0, 0, 0, 60, 61], [0, 0, 0, 1, 64, 65]],
    ], 'redo': []};
    final score = ScoreDocument.fromProject(jsonEncode(saved));
    score.undo();
    expect(score.events(0, 0)[0]['pitches'], [60, 64]);
    final migrated = jsonDecode(score.encodeProject());
    expect(migrated['_choir_mobile_history']['version'], 3);
    expect(ScoreDocument.fromProject(jsonEncode(migrated)).canRedo, true);
  });
  test('revision overflow and rejected pitches leave data and history unchanged', () {
    final saved = jsonDecode(document().encodeProject());
    saved['_choir_mobile_document']['revision'] = ProjectIdentity.maxRevision;
    final score = ScoreDocument.fromProject(jsonEncode(saved));
    final before = score.encodeProject();
    expect(() => score.transpose(0, 0, 0, 0, 1), throwsFormatException);
    expect(score.encodeProject(), before);
    final normal = document();
    expect(() => normal.transpose(0, 0, 0, 0, 200), throwsFormatException);
    expect(normal.revision, 0);
  });
}
