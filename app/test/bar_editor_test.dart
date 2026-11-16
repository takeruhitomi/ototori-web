import 'dart:convert';
import 'package:choir_mobile/app/bar_editor.dart';
import 'package:choir_mobile/score.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/harness.dart';

const lines = [100.0, 110.0, 120.0, 130.0, 140.0];
final png = base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAD0lEQVR4nGP4jwQYiOMAANuQL9FuRbCyAAAAAElFTkSuQmCC');

Map<String, dynamic> head(int pitch, double x, double y, {bool snapped = true}) =>
  {'pitch': pitch, 'x': x, 'y': y, 'confidence': snapped ? 1.0 : 0.0, 'snapped': snapped};

Map<String, dynamic> bar(int number, {required List<Map<String, dynamic>> events}) => {
  'number': number, 'page': 1, 'system': 0, 'time_sig': [4, 4], 'key_fifths': 0, 'clef': 'G',
  'bounds': {'x0': 200.0 + (number - 1) * 400, 'lines0': lines, 'x1': 600.0 + (number - 1) * 400, 'lines1': lines,
    'snapped0': true, 'snapped1': number == 1, 'confidence0': 1.0, 'confidence1': 1.0},
  'events': events,
};

Map<String, dynamic> score() => {
  'title': 'Overlay', 'meta': {'source_hash': 'd' * 64, 'source_pages': 1, 'layout': {'pages': [
    {'page': 1, 'width': 1920, 'height': 2715, 'systems': [{'index': 0, 'x0': 200, 'x1': 1000, 'y0': 80, 'y1': 170}]},
  ]}},
  'staves': [{'id': 'S', 'name': 'Soprano', 'role': 'voice', 'measures': [
    bar(1, events: [
      {'onset': '0', 'duration': '2', 'pitches': [64], 'place': {'x': 300.0, 'heads': [head(64, 300, 140)]}},
      {'onset': '2', 'duration': '2', 'pitches': [], 'place': {'x': 450.0, 'confidence': 0.0, 'snapped': false}},
    ]),
    bar(2, events: [
      {'onset': '0', 'duration': '4', 'pitches': [72], 'place': {'x': 700.0, 'heads': [head(72, 700, 115, snapped: false)]}},
    ]),
  ]}],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const scoreChannel = MethodChannel('jp.choiromr.mobile/score');
  const pdf = MethodChannel('jp.choiromr.mobile/pdf');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(scoreChannel, (call) async => call.method == 'saveProject' ? 'id' : null);
    messenger.setMockMethodCallHandler(pdf, (call) async => call.method == 'renderSourcePage' ? png : null);
  });
  tearDown(() { messenger.setMockMethodCallHandler(scoreChannel, null); messenger.setMockMethodCallHandler(pdf, null); });

  Future<Harness> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = Harness();
    await h.session.open(ScoreDocument.parse(jsonEncode(score())));
    await tester.pumpWidget(h.wrap(BarEditorPage(session: h.session, measure: 0)));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    return h;
  }

  Finder overlay() => find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_OverlayPainter');
  /// Screen position of a page point in the overlay (the crop starts at x 152, y 52).
  Offset at(WidgetTester tester, double x, double y) {
    final r = tester.getRect(overlay());
    final scale = r.width / (648 - 152);
    return r.topLeft + Offset((x - 152) * scale, (y - 52) * scale);
  }

  for (final size in [const Size(320, 640), const Size(412, 915), const Size(1280, 800)]) {
    testWidgets('editor fits ${size.width.toInt()} px and selects from the original and the strip', (tester) async {
      final h = await open(tester, size);
      expect(tester.takeException(), isNull);
      expect(overlay(), findsOneWidget);
      await tester.tapAt(at(tester, 302, 139));
      await tester.pumpAndSettle();
      expect(find.text('E4'), findsOneWidget);
      await selectFirstNote(tester);
      expect(find.text('E4'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('1つ上へ'));
      await tester.tap(find.byTooltip('1つ上へ'));
      await tester.pumpAndSettle();
      expect(h.session.score!.events(0, 0)[0]['pitches'], [65]);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('dragging a head up the staff sets its pitch; a rest dragged becomes a note', (tester) async {
    final h = await open(tester, const Size(412, 915));
    await tester.tapAt(at(tester, 300, 140));
    await tester.pumpAndSettle();
    // Six steps up (five page pixels each): E4 -> D5.
    final start = at(tester, 300, 140);
    await tester.timedDragFrom(start, at(tester, 300, 110) - start, const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(h.session.score!.events(0, 0)[0]['pitches'], [74]);
    expect(ScoreDocument.headsInPitchOrder(h.session.score!.events(0, 0)[0] as Map)!.single['pitch'], 74);
    // The rest's handle sits on the middle line; drag it to the top line (F5).
    await tester.tapAt(at(tester, 450, 120));
    await tester.pumpAndSettle();
    expect(find.text('休符'), findsOneWidget);
    final rest = at(tester, 450, 120);
    await tester.timedDragFrom(rest, at(tester, 450, 100) - rest, const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(h.session.score!.events(0, 0)[1]['pitches'], [77]);
    h.session.undo();
    expect(h.session.score!.events(0, 0)[1]['pitches'], isEmpty);
  });

  testWidgets('notes missing on the image are counted and reached with 次の要確認', (tester) async {
    await open(tester, const Size(412, 915));
    expect(find.text('1小節'), findsOneWidget);
    await tester.tap(find.text('次の要確認'));
    await tester.pumpAndSettle();
    expect(find.text('2小節'), findsOneWidget);
    expect(find.text('見つからない音 1'), findsOneWidget);
  });

  testWidgets('rests become notes, notes split and merge from the tools', (tester) async {
    final h = await open(tester, const Size(412, 915));
    await tester.tapAt(at(tester, 450, 120));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('音符にする'));
    await tester.tap(find.text('音符にする'));
    await tester.pumpAndSettle();
    expect(h.session.score!.events(0, 0)[1]['pitches'], [64]); // the note before it
    await tester.ensureVisible(find.text('分ける'));
    await tester.tap(find.text('分ける'));
    await tester.pumpAndSettle();
    expect([for (final e in h.session.score!.events(0, 0)) e['duration']], ['2', '1', '1']);
    await tester.ensureVisible(find.text('次とつなぐ'));
    await tester.tap(find.text('次とつなぐ'));
    await tester.pumpAndSettle();
    expect([for (final e in h.session.score!.events(0, 0)) e['duration']], ['2', '2']);
    expect(tester.takeException(), isNull);
  });
}
