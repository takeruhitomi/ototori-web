import 'dart:async';
import 'dart:ui' as ui;
import 'package:choir_mobile/score_reference.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const channel = MethodChannel('jp.choiromr.mobile/pdf');
  testWidgets('renders a returned source image with zoom controls', (tester) async {
    final png = await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 16, 16), ui.Paint()..color = const ui.Color(0xffffffff));
      final picture = recorder.endRecording();
      final image = await picture.toImage(16, 16);
      final png = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
      image.dispose(); picture.dispose();
      return png;
    });
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => png);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    int? selected;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(children: [
      ExpansionTile(key: const PageStorageKey('source-panel'), title: const Text('原譜を開く'),
      children: [ScoreReference(hash: 'source-id', page: 3,
      layout: const {'pages': [{'page': 3, 'width': 100, 'height': 100, 'systems': [
        {'index': 0, 'x0': 10, 'x1': 90, 'y0': 20, 'y1': 80},
      ]}]}, measures: const [{'page': 3, 'system': 0}, {'page': 3, 'system': 0}],
      onSeek: (index) => selected = index)]),
    ]))));
    await tester.tap(find.text('原譜を開く'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.textContaining('原譜 3ページ'), findsOneWidget);
    final origin = tester.getTopLeft(find.byType(Image)), size = tester.getSize(find.byType(Image));
    await tester.tapAt(origin + Offset(size.width * 0.75, size.height * 0.5));
    expect(selected, 1);
    expect(tester.takeException(), null);
  });
  testWidgets('uses source hash and page and ignores obsolete page errors', (tester) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final first = Completer<Object?>();
    final calls = <Map>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'renderSourcePage');
      calls.add(call.arguments as Map);
      if (calls.length == 1) return first.future;
      throw PlatformException(code: 'source', message: 'page 2 failed');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(const MaterialApp(home: ScoreReference(hash: 'source-id', page: 1)));
    await tester.pump();
    expect(calls.single, {'hash': 'source-id', 'page': 0});
    await tester.pumpWidget(const MaterialApp(home: ScoreReference(hash: 'source-id', page: 2)));
    await tester.pump(); await tester.pump();
    expect(calls.last, {'hash': 'source-id', 'page': 1});
    expect(find.text('page 2 failed'), findsOneWidget);
    first.completeError(PlatformException(code: 'source', message: 'obsolete page 1 failure'));
    await tester.pump(); await tester.pump();
    expect(find.text('obsolete page 1 failure'), findsNothing);
    expect(find.text('page 2 failed'), findsOneWidget);
    await tester.tap(find.text('原譜を再読み込み'));
    await tester.pump(); await tester.pump();
    expect(calls.length, 3);
  });
}
