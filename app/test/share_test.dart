import 'dart:convert';
import 'package:choir_mobile/main.dart';
import 'package:choir_mobile/score.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const scoreChannel = MethodChannel('jp.choiromr.mobile/score');
  const incoming = MethodChannel('jp.choiromr.mobile/incoming');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() {
    messenger.setMockMethodCallHandler(scoreChannel, null);
    messenger.setMockMethodCallHandler(incoming, null);
  });

  // The conductor's copy: one note fixed after conversion.
  ScoreDocument original() => ScoreDocument.parse(jsonEncode({'title': 'ふるさと', 'staves': [
    {'id': 'S', 'name': 'Soprano', 'role': 'voice', 'measures': [
      {'number': 1, 'time_sig': [4, 4], 'events': [{'onset': '0', 'duration': '4', 'pitches': [60]}]},
    ]},
  ]}));

  /// Runs the app with one received file. [mine]: this phone's copy of the song.
  Future<({List<Map> saved, List<String> calls})> receive(WidgetTester tester, String shared, {String? mine}) async {
    final saved = <Map>[];
    final calls = <String>[];
    var given = false;
    messenger.setMockMethodCallHandler(incoming, (call) async {
      if (call.method != 'takeIncomingProject' || given) return null;
      given = true;
      return {'token': 'token-1', 'text': shared};
    });
    messenger.setMockMethodCallHandler(scoreChannel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'listProjects':
          if (mine == null) return [];
          return [{'id': 'mine', 'title': '私のふるさと', 'updated': 1, 'parts': ['Soprano'], 'measures': 1,
            'documentId': (jsonDecode(mine)['_choir_mobile_document'] as Map)['document_id']}];
        case 'loadProject':
          final id = (call.arguments as Map)['id'];
          final latest = saved.lastWhere((s) => s['id'] == id || id == 'new-id', orElse: () => {});
          return latest['text'] ?? mine;
        case 'saveProject':
          final args = Map.of(call.arguments as Map);
          saved.add({'id': args['id'] ?? 'new-id', 'text': args['text']});
          return args['id'] ?? 'new-id';
      }
      return null;
    });
    await tester.pumpWidget(const OtotoriApp());
    await tester.pumpAndSettle();
    return (saved: saved, calls: calls);
  }

  testWidgets('a received fix replaces the same song and keeps this phone\'s practice settings', (tester) async {
    final source = original();
    final minePlain = jsonDecode(source.encodeProject()) as Map<String, dynamic>;
    minePlain['meta'] = {'mobile_playback': {'tempo': 72}};
    source.transpose(0, 0, 0, 0, 2);
    final sharedMap = jsonDecode(source.encodeProject()) as Map<String, dynamic>;
    sharedMap['meta'] = {'mobile_playback': {'tempo': 120}};
    final r = await receive(tester, jsonEncode(sharedMap), mine: jsonEncode(minePlain));
    expect(find.text('曲を受け取りました'), findsOneWidget);
    expect(find.textContaining('同じ曲「私のふるさと」'), findsOneWidget);
    await tester.tap(find.text('置き換える'));
    await tester.pumpAndSettle();
    expect(r.calls, contains('commitProjectBackup'));
    final stored = jsonDecode(r.saved.first['text'] as String);
    expect(r.saved.first['id'], 'mine');
    expect(stored['staves'][0]['measures'][0]['events'][0]['pitches'], [62]);
    expect(stored['meta']['mobile_playback'], {'tempo': 72});
    // The edit history travels with it.
    expect(ScoreDocument.fromProject(r.saved.first['text'] as String).canUndo, true);
    expect(find.text('「ふるさと」を受け取った内容に置き換えました。'), findsOneWidget);
  });

  testWidgets('a new song is added; declining adds nothing', (tester) async {
    final shared = original().encodeProject();
    final r = await receive(tester, shared);
    expect(find.text('置き換える'), findsNothing);
    await tester.tap(find.text('ライブラリに追加'));
    await tester.pumpAndSettle();
    expect(r.saved.single['id'], 'new-id');
    expect(r.calls, containsAllInOrder(['commitProjectBackup', 'saveProject']));
  });

  testWidgets('declining discards the staged file', (tester) async {
    final r = await receive(tester, original().encodeProject());
    await tester.tap(find.text('受け取らない'));
    await tester.pumpAndSettle();
    expect(r.saved, isEmpty);
    expect(r.calls, contains('discardProjectBackup'));
    expect(r.calls, isNot(contains('commitProjectBackup')));
  });

  testWidgets('a file that is not a song is reported', (tester) async {
    messenger.setMockMethodCallHandler(incoming, (call) async => {'error': '音鳥の曲ファイルとして開けませんでした（ZIPではありません）。'});
    messenger.setMockMethodCallHandler(scoreChannel, (call) async => call.method == 'listProjects' ? [] : null);
    await tester.pumpWidget(const OtotoriApp());
    await tester.pumpAndSettle();
    expect(find.textContaining('音鳥の曲ファイルとして開けませんでした'), findsOneWidget);
  });
}
