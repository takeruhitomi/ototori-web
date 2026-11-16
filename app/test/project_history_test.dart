import 'dart:async';
import 'dart:convert';
import 'package:choir_mobile/score.dart';
import 'package:choir_mobile/project_persistence.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ScoreDocument document() => ScoreDocument.parse(jsonEncode({'staves': [
  {'measures': [{'events': [{'onset': '0/1', 'duration': '1/1', 'pitches': [60, 64]}]}]}
]}));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('restores undo and redo without changing exported score metadata', () {
    final score = document();
    score.transpose(0, 0, 0, 0, 1);
    score.transpose(0, 0, 0, 1, 12);
    score.undo();
    final restored = ScoreDocument.fromProject(score.encodeProject());
    expect(restored.encode(), score.encode());
    expect(restored.canUndo, true); expect(restored.canRedo, true);
    restored.redo(); expect(restored.events(0, 0)[0]['pitches'], [61, 76]);
    restored.undo(); restored.undo(); expect(restored.events(0, 0)[0]['pitches'], [60, 64]);
    expect(restored.data.containsKey('_choir_mobile_history'), false);
  });
  test('rejects inconsistent history before edits can be applied', () {
    final score = document(); score.transpose(0, 0, 0, 0, 1);
    final stored = jsonDecode(score.encodeProject());
    stored['_choir_mobile_history']['undo'][0][0]['after'] = 90;
    expect(() => ScoreDocument.fromProject(jsonEncode(stored)), throwsFormatException);
    stored['_choir_mobile_history']['undo'][0][0]['part_id'] = 'missing-part';
    expect(() => ScoreDocument.fromProject(jsonEncode(stored)), throwsFormatException);
  });
  test('serializes first save and rapid snapshots under a single project id', () async {
    const channel = MethodChannel('jp.choiromr.mobile/score');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final gate = Completer<String>();
    final calls = <Map>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.arguments as Map);
      if (calls.length == 1) return gate.future;
      return 'saved-id';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final persistence = ProjectPersistence();
    final first = persistence.save('first');
    final second = persistence.save('second');
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(1));
    gate.complete('saved-id');
    await Future.wait([first, second]);
    expect(calls[0]['id'], null);
    expect(calls[1], {'id': 'saved-id', 'text': 'second'});
  });

  test('a failed save is reported and does not prevent a subsequent retry', () async {
    const channel = MethodChannel('jp.choiromr.mobile/score');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var count = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (++count == 1) throw PlatformException(code: 'disk', message: 'full');
      return 'retried-id';
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final persistence = ProjectPersistence();
    final failed = persistence.save('first');
    final retried = persistence.save('latest');
    await expectLater(failed, throwsA(isA<PlatformException>()));
    expect(await retried, 'retried-id');
    expect(persistence.id, 'retried-id');
  });
}
