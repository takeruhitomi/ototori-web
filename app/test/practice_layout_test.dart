import 'dart:convert';
import 'package:choir_mobile/app/practice_tab.dart';
import 'package:choir_mobile/score.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/harness.dart';

Map<String, dynamic> score({bool source = false}) => {
  'title': 'とても長い曲名の合唱曲（混声四部合唱とピアノのための）', 'tempo_bpm': 96,
  'warnings': ['3小節: 音価を推定しました'],
  'meta': {
    if (source) 'source_hash': 'c' * 64,
    if (source) 'source_pages': 2,
    if (source) 'layout': {'pages': [
      {'page': 1, 'width': 1000, 'height': 1414, 'systems': [{'index': 0, 'x0': 100, 'x1': 900, 'y0': 200, 'y1': 500}]},
    ]},
  },
  'staves': [
    for (final (id, name) in [('s', 'Soprano'), ('a', 'Alto'), ('t', 'Tenor'), ('b', 'Bass'), ('piano_rh', 'Piano'), ('piano_lh', 'Piano')])
      {'id': id, 'name': name, 'role': id.startsWith('piano') ? id : 'voice', 'measures': [
        for (var i = 0; i < 4; i++) {'number': i + 1, 'page': 1, 'system': 0, 'time_sig': [4, 4],
          'events': [{'onset': '0', 'duration': '4', 'pitches': [60 + i]}]},
      ]},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const scoreChannel = MethodChannel('jp.choiromr.mobile/score');
  const pdf = MethodChannel('jp.choiromr.mobile/pdf');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  setUp(() {
    messenger.setMockMethodCallHandler(scoreChannel, (call) async => call.method == 'saveProject' ? 'id' : null);
    messenger.setMockMethodCallHandler(pdf, (call) async => null);
  });
  tearDown(() { messenger.setMockMethodCallHandler(scoreChannel, null); messenger.setMockMethodCallHandler(pdf, null); });

  for (final source in [false, true]) {
    for (final size in [const Size(320, 640), const Size(412, 915), const Size(1280, 800)]) {
      testWidgets('practice ${source ? 'with' : 'without'} PDF fits ${size.width.toInt()} logical pixels', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final h = Harness();
        await h.session.open(ScoreDocument.parse(jsonEncode(score(source: source))));
        await tester.pumpWidget(h.wrap(const PracticeTab()));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byTooltip('再生'), findsOneWidget);
        expect(find.text('要確認の箇所が1件あります'), findsOneWidget);
        // The mixer starts closed so the score gets the whole width.
        expect(find.text('自分のパートで練習'), findsNothing);
        await tester.tap(find.byTooltip('ミキサー'));
        await tester.pumpAndSettle();
        // Mixer: parts and the choir focus shortcut.
        expect(find.text('自分のパートで練習'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Alto'));
        await tester.pumpAndSettle();
        expect(h.session.focusPart, 'a');
        expect(h.session.volumeOf('a'), 1);
        expect(h.session.volumeOf('s'), lessThan(1));
        await tester.tap(find.byTooltip('ミキサーを閉じる'));
        await tester.pumpAndSettle();
        expect(find.text('自分のパートで練習'), findsNothing);
        await tester.pump(const Duration(seconds: 1));
      });
    }
  }

  testWidgets('tapping a bar on the score moves the playhead there', (tester) async {
    final h = Harness();
    await h.session.open(ScoreDocument.parse(jsonEncode(score(source: true))));
    await tester.pumpWidget(h.wrap(const PracticeTab()));
    await tester.pumpAndSettle();
    final page = tester.getRect(find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_BarPainter').first);
    // Third of four bars in the system spanning x 0.1..0.9, y 0.14..0.35.
    await tester.tapAt(Offset(page.left + page.width * 0.55, page.top + page.height * 0.25));
    await tester.pumpAndSettle();
    expect(h.session.currentMeasure, 2);
  });

  for (final width in [400.0, 1280.0]) {
    testWidgets('swiping in from the right edge opens the mixer at ${width.toInt()} px', (tester) async {
      tester.view.physicalSize = Size(width, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = Harness();
      await h.session.open(ScoreDocument.parse(jsonEncode(score(source: true))));
      await tester.pumpWidget(h.wrap(const PracticeTab()));
      await tester.pumpAndSettle();
      expect(find.text('自分のパートで練習'), findsNothing);
      await tester.timedDragFrom(Offset(width - 6, 400), const Offset(-300, 0), const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      // Fully in: the section header sits well inside the screen.
      expect(tester.getRect(find.text('自分のパートで練習')).left, lessThan(width - 250));
      // Dragging the panel header back to the right closes it.
      await tester.drag(find.text('ミキサー').first, const Offset(300, 0));
      await tester.pumpAndSettle();
      expect(find.text('自分のパートで練習'), findsNothing);
    });
  }

  testWidgets('recognized notes are drawn over the original and can be hidden', (tester) async {
    final data = score(source: true);
    const lines = [100.0, 110.0, 120.0, 130.0, 140.0];
    for (final staff in data['staves'] as List) {
      for (final bar in staff['measures'] as List) {
        bar['bounds'] = {'x0': 100.0, 'lines0': lines, 'x1': 300.0, 'lines1': lines};
        bar['clef'] = 'G';
        final e = (bar['events'] as List).single as Map;
        e['place'] = {'x': 150.0, 'heads': [{'pitch': e['pitches'][0], 'x': 150.0, 'y': 160.0, 'confidence': 1.0, 'snapped': true}]};
      }
    }
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAD0lEQVR4nGP4jwQYiOMAANuQL9FuRbCyAAAAAElFTkSuQmCC';
    messenger.setMockMethodCallHandler(pdf, (call) async => base64Decode(png));
    final h = Harness();
    await h.session.open(ScoreDocument.parse(jsonEncode(data)));
    await tester.pumpWidget(h.wrap(const PracticeTab()));
    await tester.pumpAndSettle();
    Finder notes() => find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_NotePainter');
    expect(notes(), findsOneWidget);
    // The notes sounding now are filled in.
    expect(find.byWidgetPredicate((w) => w is CustomPaint && '${w.painter.runtimeType}' == '_ActivePainter'), findsOneWidget);
    await tester.tap(find.byTooltip('その他'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('認識した音符を重ねる'));
    await tester.pumpAndSettle();
    expect(h.settings.showRecognized, false);
    expect(notes(), findsNothing);
  });

  testWidgets('solo is one part at a time', (tester) async {
    final h = Harness();
    await h.session.open(ScoreDocument.parse(jsonEncode(score())));
    h.session.toggleSolo('s');
    h.session.toggleSolo('a');
    expect(h.session.solos, {'a'});
    h.session.toggleSolo('a');
    expect(h.session.solos, isEmpty);
  });

  testWidgets('the mixer opens after the practice tab was built while hidden', (tester) async {
    // In the app the score is opened from the library, so the practice tab
    // (and its panel) is built while its TickerMode is off.
    final h = Harness();
    final visible = ValueNotifier(false);
    await tester.pumpWidget(h.wrap(ValueListenableBuilder<bool>(valueListenable: visible,
      builder: (context, on, _) => TickerMode(enabled: on, child: const PracticeTab()))));
    await h.session.open(ScoreDocument.parse(jsonEncode(score(source: true))));
    await tester.pumpAndSettle();
    visible.value = true;
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('ミキサー'));
    await tester.pumpAndSettle();
    final header = tester.getRect(find.text('自分のパートで練習'));
    expect(header.left, lessThan(800 - 200), reason: 'panel should have slid fully in');
  });
}
