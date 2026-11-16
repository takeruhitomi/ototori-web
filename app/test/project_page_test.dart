import 'dart:convert';
import 'package:choir_mobile/app/library_tab.dart';
import 'package:choir_mobile/app/bar_editor.dart';
import 'package:choir_mobile/score.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/harness.dart';

void main() {
  testWidgets('saves the complete score, autosaves edits and reloads it from the library', (tester) async {
    const channel = MethodChannel('jp.choiromr.mobile/score');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? saved;
    List? played;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'saveProject': saved = (call.arguments as Map)['text'] as String; return 'project-id';
        case 'listProjects': return [{'id': 'project-id', 'title': 'Saved score', 'updated': 1, 'parts': ['Soprano'], 'measures': 1}];
        case 'loadProject': return saved!.replaceFirst('Saved score', 'Reloaded score');
        case 'stop': case 'updateMixer': return null;
        case 'play': played = (call.arguments as Map)['events'] as List; return null;
      }
      throw StateError('Unexpected ${call.method}');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final data = {'title': 'Saved score', 'custom_metadata': {'preserved': true}, 'staves': [
      {'id': 'S1', 'name': 'Soprano', 'role': 'voice', 'measures': [
        {'events': [{'onset': '0/1', 'duration': '1/1', 'pitches': [60]}]}
      ]}
    ]};
    final h = Harness();
    await h.session.open(ScoreDocument.parse(jsonEncode(data)));
    expect(await h.session.save(), isTrue);
    expect(h.session.projectId, 'project-id');
    final savedData = jsonDecode(saved!) as Map;
    expect(savedData.remove('_choir_mobile_history'), {'version': 3, 'undo': [], 'redo': []});
    final identity = savedData.remove('_choir_mobile_document') as Map;
    expect(identity['schema_version'], 1);
    expect(identity['revision'], 0);
    expect(savedData, data);

    await tester.pumpWidget(h.wrap(BarEditorPage(session: h.session, measure: 0)));
    await selectFirstNote(tester);
    await tester.tap(find.byTooltip('半音上げる'));
    await tester.pumpAndSettle();
    expect(jsonDecode(saved!)['staves'][0]['measures'][0]['events'][0]['pitches'], [61]);
    expect(jsonDecode(saved!)['_choir_mobile_history']['undo'], hasLength(1));
    await tester.tap(find.byTooltip('聴く'));
    await tester.pumpAndSettle();
    expect(played!.single['pitch'], 61);
    expect(played!.single['piano'], false);

    await h.session.close();
    await h.library.refresh();
    await tester.pumpWidget(h.wrap(const LibraryTab()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Saved score'));
    await tester.pumpAndSettle();
    expect(h.session.title, 'Reloaded score');
    expect(h.session.projectId, 'project-id');
    h.session.undo();
    await tester.pumpAndSettle();
    expect(jsonDecode(saved!)['staves'][0]['measures'][0]['events'][0]['pitches'], [60]);
    expect(jsonDecode(saved!)['_choir_mobile_history']['redo'], hasLength(1));
  });
}
