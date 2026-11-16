import 'package:choir_mobile/main.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(400, 800), const Size(1200, 800)]) {
    testWidgets('shows the tab bar and the convert flow at ${size.width.toInt()} logical pixels', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(const OtotoriApp());
      await tester.pumpAndSettle();
      for (final label in ['変換', 'ライブラリ', '練習', '設定']) { expect(find.text(label), findsWidgets); }
      expect(find.text('PDFを選ぶ'), findsWidgets);
      expect(find.text('自動で認識する'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a chosen color set and appearance are applied and saved', (tester) async {
    const score = MethodChannel('jp.choiromr.mobile/score');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(score, null));
    String? saved;
    messenger.setMockMethodCallHandler(score, (call) async {
      if (call.method == 'loadAppSettings') return jsonEncode({'palette': 'midori', 'themeMode': 'light'});
      if (call.method == 'saveAppSettings') saved = (call.arguments as Map)['text'] as String;
      if (call.method == 'listProjects') return [];
      return null;
    });
    await tester.pumpWidget(const OtotoriApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('設定'));
    await tester.pumpAndSettle();
    // The saved set is restored on launch.
    expect(Theme.of(tester.element(find.text('カラー'))).colorScheme.primary, const Color(0xFF1E6B47));
    await tester.scrollUntilVisible(find.text('認識モデル'), 200, scrollable: find.byType(Scrollable).last);
    expect(find.textContaining('ZIP'), findsNothing);
    await tester.scrollUntilVisible(find.text('くっきり'), -200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('くっきり'));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('カラー'))).colorScheme.primary, const Color(0xFF0040DD));
    expect(jsonDecode(saved!), {'palette': 'contrast', 'themeMode': 'light', 'showRecognized': true});
    await tester.ensureVisible(find.text('ダーク'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ダーク'));
    await tester.pumpAndSettle();
    expect(Theme.of(tester.element(find.text('カラー'))).brightness, Brightness.dark);
    expect(jsonDecode(saved!)['themeMode'], 'dark');
  });

  testWidgets('a converted PDF is saved to the library and opens for practice', (tester) async {
    const pdf = MethodChannel('jp.choiromr.mobile/pdf');
    const omr = MethodChannel('jp.choiromr.mobile/omr');
    const score = MethodChannel('jp.choiromr.mobile/score');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() { for (final c in [pdf, omr, score]) { messenger.setMockMethodCallHandler(c, null); } });
    Map? savedConversion;
    String? savedProject;
    messenger.setMockMethodCallHandler(pdf, (call) async {
      switch (call.method) {
        case 'pickPdfs': return [{'name': 'test.pdf', 'pages': 1, 'sourceHash': 'a' * 64}];
        case 'listConversions': return [];
        case 'openSourcePdf': return {'pages': 1, 'sourceHash': 'a' * 64};
        case 'saveConversion': savedConversion = jsonDecode((call.arguments as Map)['text'] as String) as Map; return 'job-id';
        case 'startNativeConversion': return null;
        case 'nativeConversionState': return {'active': false, 'text': jsonEncode({...savedConversion!, 'status': 'recognized', 'completed_pages': [0]})};
        case 'renderSourcePage': return null;
      }
      throw StateError('Unexpected ${call.method}');
    });
    messenger.setMockMethodCallHandler(omr, (call) async {
      if (call.method == 'modelsReady') return true;
      expect(call.method, 'recognizePage');
      expect(call.arguments, {'page': 0, 'dpi': 300});
      return {'width': 100, 'height': 100, 'warnings': ['原譜を確認'], 'staves': [
        {'crop': [0, 0, 100, 50], 'reachedEos': true, 'symbols': [['note_4', 'C4', '_', 'upper', '_', '_']]}
      ]};
    });
    messenger.setMockMethodCallHandler(score, (call) async {
      switch (call.method) {
        case 'saveProject': savedProject = (call.arguments as Map)['text'] as String; return 'project-id';
        case 'listProjects': return savedProject == null ? [] : [{'id': 'project-id', 'title': 'test', 'updated': 1, 'parts': ['Soprano']}];
        case 'stop': case 'updateMixer': return null;
      }
      throw StateError('Unexpected ${call.method}');
    });
    await tester.pumpWidget(const OtotoriApp());
    await tester.pumpAndSettle();
    await tester.tap(find.text('PDFを選ぶ'));
    await tester.pumpAndSettle();
    expect(find.text('test'), findsOneWidget);
    await tester.tap(find.text('自動で認識する'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Soprano');
    await tester.ensureVisible(find.text('ピアノ伴奏（2段）がある'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ピアノ伴奏（2段）がある'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('音取り音源を作る'));
    await tester.pumpAndSettle();
    // Saved to the library, then opened in the practice tab.
    expect(jsonDecode(savedProject!)['meta']['source_hash'], 'a' * 64);
    expect(savedConversion!['status'], 'complete');
    final banner = find.textContaining(RegExp(r'^要確認の箇所が\d+件あります$'));
    expect(banner, findsOneWidget);
    expect(find.textContaining('原譜を確認'), findsNothing);
    await tester.tap(banner);
    await tester.pumpAndSettle();
    expect(find.textContaining('原譜を確認'), findsOneWidget);
  });
}
