import 'dart:convert';
import 'package:choir_mobile/project_backup.dart';
import 'package:choir_mobile/score.dart';
import 'package:choir_mobile/app/library_tab.dart';
import 'package:choir_mobile/app/bar_editor.dart';
import 'support/harness.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = ProjectBackup.channel;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  ScoreDocument document() => ScoreDocument.parse(jsonEncode({'title': 'Backup', 'staves': [
    {'measures': [{'events': [{'onset': '0/1', 'duration': '1/1', 'pitches': [60]}]}]}
  ]}))..transpose(0, 0, 0, 0, 1);

  test('restores IDs and history into a new library item only after validation', () async {
    final original = document();
    final calls = <String>[];
    String? saved;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'pickProjectBackup': return {'token': 'staging', 'text': original.encodeProject()};
        case 'commitProjectBackup': return null;
        case 'saveProject':
          expect((call.arguments as Map)['id'], null);
          saved = (call.arguments as Map)['text'] as String;
          return 'new-library-id';
        case 'discardProjectBackup': return null;
      }
      fail('Unexpected ${call.method}');
    });
    final restored = (await const ProjectBackup().restore(attached: () => true))!;
    expect(calls, ['pickProjectBackup', 'commitProjectBackup', 'saveProject', 'discardProjectBackup']);
    expect(restored.persistence.id, 'new-library-id');
    expect(restored.score.identity.toJson(), original.identity.toJson());
    expect(ScoreDocument.fromProject(saved!).revision, 1);
    restored.score.undo();
    expect(restored.score.events(0, 0)[0]['pitches'], [60]);
  });
  test('invalid shared history is discarded before native data or library changes', () async {
    final saved = jsonDecode(document().encodeProject());
    saved['_choir_mobile_history']['undo'][0][0]['after'] = 90;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'pickProjectBackup') return {'token': 'staging', 'text': jsonEncode(saved)};
      if (call.method == 'discardProjectBackup') return null;
      fail('Invalid backup published');
    });
    await expectLater(const ProjectBackup().restore(attached: () => true), throwsFormatException);
    expect(calls, ['pickProjectBackup', 'discardProjectBackup']);
  });
  test('cancelled selection and detached UI do not create a library item', () async {
    final calls = <String>[];
    var cancelled = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'pickProjectBackup') return cancelled ? null : {'token': 'staging', 'text': document().encodeProject()};
      if (call.method == 'discardProjectBackup') return null;
      fail('Detached backup published');
    });
    expect(await const ProjectBackup().restore(attached: () => true), null);
    cancelled = false;
    expect(await const ProjectBackup().restore(attached: () => false), null);
    expect(calls, ['pickProjectBackup', 'pickProjectBackup', 'discardProjectBackup']);
  });
  test('native commit failure releases staging and never saves a library item', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'pickProjectBackup') return {'token': 'staging', 'text': document().encodeProject()};
      if (call.method == 'commitProjectBackup') throw PlatformException(code: 'disk');
      if (call.method == 'discardProjectBackup') return null;
      fail('Failed backup saved');
    });
    await expectLater(const ProjectBackup().restore(attached: () => true), throwsA(isA<PlatformException>()));
    expect(calls, ['pickProjectBackup', 'commitProjectBackup', 'discardProjectBackup']);
  });
  test('export captures the complete project snapshot and preserves cancellation', () async {
    final score = document();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'exportProjectBackup');
      final captured = ScoreDocument.fromProject((call.arguments as Map)['text'] as String);
      expect(captured.identity.toJson(), score.identity.toJson());
      expect(captured.canUndo, true);
      return false;
    });
    expect(await const ProjectBackup().export(score), false);
  });
  testWidgets('restored score remains editable and autosaves under its new library id', (tester) async {
    final original = document();
    String? saved;
    final ids = <Object?>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'stop': case 'updateMixer': return null;
        case 'listProjects': return saved == null ? [] : [{'id': 'restored-id', 'title': 'Backup', 'updated': 1}];
        case 'loadProject': return saved;
        case 'pickProjectBackup': return {'token': 'staging', 'text': original.encodeProject()};
        case 'commitProjectBackup':
        case 'discardProjectBackup': return null;
        case 'saveProject':
          ids.add((call.arguments as Map)['id']);
          saved = (call.arguments as Map)['text'] as String;
          return 'restored-id';
      }
      fail('Unexpected ${call.method}');
    });
    final h = Harness();
    await tester.pumpWidget(h.wrap(const LibraryTab()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('読み込む'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('バックアップから復元'));
    await tester.pumpAndSettle();
    expect(ids, [null]);
    await h.session.openProject('restored-id');
    await tester.pumpWidget(h.wrap(BarEditorPage(session: h.session, measure: 0)));
    await selectFirstNote(tester);
    await tester.tap(find.byTooltip('半音上げる'));
    await tester.pumpAndSettle();
    final reopened = ScoreDocument.fromProject(saved!);
    expect(reopened.identity.documentId, original.identity.documentId);
    expect(reopened.revision, 2);
    expect(reopened.events(0, 0)[0]['pitches'], [62]);
    expect(ids, [null, 'restored-id']);
  });
}
