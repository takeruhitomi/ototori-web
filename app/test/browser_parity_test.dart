import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/musicxml_export.dart';
import 'package:choir_mobile/midi_export.dart';
import 'package:choir_mobile/repeat_editor.dart';
import 'package:choir_mobile/repeat_plan.dart';
import 'package:choir_mobile/score.dart';
import 'package:choir_mobile/app/practice_tab.dart';
import 'support/harness.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, dynamic> score() => jsonDecode(jsonEncode({
    'title': 'Parity', 'staves': [
      for (final id in ['s', 'a', 'piano_rh', 'piano_lh']) {
        'id': id, 'role': id.startsWith('piano') ? id : 'voice', 'name': id, 'clef': 'G',
        'measures': [for (var i = 0; i < 3; i++) {
          'number': i + 1, 'time_sig': [4, 4], 'events': [
            {'onset': '0', 'duration': '1', 'pitches': [60 + i], 'velocity': 90},
          ],
        }],
      },
    ], 'meta': {'repeat_override': [
      {'start': 1, 'end': 2, 'times': 2, 'endings': [
        {'start': 2, 'end': 2, 'passes': [1]},
        {'start': 3, 'end': 3, 'passes': [2]},
      ]},
    ]},
  })) as Map<String, dynamic>;
  test('manual endings survive MusicXML export without changing saved source', () {
    final input = score(), before = jsonEncode(score());
    final xml = MusicXmlExporter().export(input);
    expect(xml, contains('<repeat direction="forward"/>'));
    expect(xml, contains('<repeat direction="backward" times="2"/>'));
    expect(xml, contains('<ending number="1" type="start"/>'));
    expect(xml, contains('<ending number="2" type="start"/>'));
    expect(jsonEncode(input), before);
    expect(RepeatPlanner().build(input).order, [0, 1, 0, 2]);
    final target = Directory('.dart_tool/musicxml-export-check')..createSync(recursive: true);
    File('${target.path}/manual_endings.musicxml').writeAsStringSync(xml);
    final expected = score();
    for (final staff in expected['staves'] as List) {
      staff['measures'][0]['repeat_start'] = true;
      staff['measures'][1]['repeat_end'] = 2;
      staff['measures'][1]['ending_numbers'] = [1];
      staff['measures'][2]['ending_numbers'] = [2];
    }
    File('${target.path}/manual_endings.json').writeAsStringSync(jsonEncode(expected));
  });
  test('MIDI subset groups piano and applies practice velocities', () {
    final midi = MidiExporter().export(score(), partsOnly: {'s', 'piano'}, velocities: {'s': 110, 'piano': 60});
    expect(midi[10] * 256 + midi[11], 3); // conductor plus two parts
    final velocities = <int, int>{};
    var offset = 14;
    while (offset < midi.length) {
      final length = midi[offset + 4] * 0x1000000 + midi[offset + 5] * 0x10000 + midi[offset + 6] * 256 + midi[offset + 7];
      var cursor = offset + 8;
      final end = cursor + length;
      int variable() {
        var n = 0;
        int b;
        do { b = midi[cursor++]; n = n * 128 + (b & 127); } while (b >= 128);
        return n;
      }
      while (cursor < end) {
        variable(); // delta ticks
        final status = midi[cursor++];
        if (status == 255) { cursor++; final size = variable(); cursor += size; continue; }
        if ((status & 0xf0) == 0xc0) { cursor++; continue; }
        if ((status & 0xf0) == 0x90) {
          final velocity = midi[cursor + 1];
          velocities.update(velocity, (n) => n + 1, ifAbsent: () => 1);
        }
        cursor += 2;
      }
      offset = end;
    }
    expect(velocities, {110: 4, 60: 4});
    final names = latin1.decode(midi);
    expect(names, contains('piano_rh')); expect(names, isNot(contains('piano_lh')));
    final solo = MidiExporter().export(score(), partsOnly: {'a'});
    expect(solo[10] * 256 + solo[11], 2);
  });
  testWidgets('repeat editor previews performed endings and saves override', (tester) async {
    List<Map<String, dynamic>>? saved;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: RepeatEditor(score: score(),
      onSave: (enabled, regions) { saved = regions; }))));
    await tester.ensureVisible(find.text('演奏順を確認'));
    await tester.tap(find.text('演奏順を確認')); await tester.pumpAndSettle();
    expect(find.text('演奏順: 1 → 2 → 1 → 3'), findsOneWidget);
    await tester.tap(find.text('反復設定を保存')); await tester.pumpAndSettle();
    expect(saved!.single['times'], 2); expect(saved!.single['endings'], hasLength(2));
  });
  testWidgets('practice settings autosave without closing the open control panel', (tester) async {
    const channel = MethodChannel('jp.choiromr.mobile/score');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    String? saved;
    Map? mixer;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'saveProject') { saved = (call.arguments as Map)['text'] as String; return 'parity-project'; }
      if (call.method == 'updateMixer') { mixer = call.arguments as Map; }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final h = Harness();
    await h.session.open(ScoreDocument.parse(jsonEncode(score())));
    await h.session.save();
    await tester.pumpWidget(h.wrap(const PracticeTab()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('ミキサー')); await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('クリックを鳴らす'), 200, scrollable: find.byType(Scrollable).last); await tester.pumpAndSettle();
    await tester.tap(find.text('クリックを鳴らす')); await tester.pump(const Duration(seconds: 1)); await tester.pumpAndSettle();
    expect(jsonDecode(saved!)['meta']['mobile_playback']['metronome'], true);
    expect(mixer!['master'], 0.8);
    // The sheet stays open while settings save.
    expect(find.text('再生前に1小節カウント'), findsOneWidget);
    await tester.ensureVisible(find.text('再生前に1小節カウント')); await tester.pumpAndSettle();
    await tester.tap(find.text('再生前に1小節カウント')); await tester.pump(const Duration(seconds: 1)); await tester.pumpAndSettle();
    expect(jsonDecode(saved!)['meta']['mobile_playback']['countIn'], true);
    final reloaded = ScoreDocument.fromProject(saved!);
    expect(reloaded.data['meta']['mobile_playback']['metronome'], true);
  });
}
