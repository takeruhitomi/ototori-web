import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/playback_timeline.dart';
import 'package:choir_mobile/playback_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('repeat, tie, slur and piano grace timing match the browser player', () {
    final cases = jsonDecode(File('test/fixtures/browser_playback.json').readAsStringSync()) as Map<String, dynamic>;
    expect(cases.length, 3);
    for (final entry in cases.entries) {
      final result = PlaybackTimelineBuilder().build(entry.value['score'] as Map<String, dynamic>);
      final expected = (entry.value['notes'] as List).cast<Map>();
      final actual = [...result.notes]..sort((a, b) {
        final staff = a.staffId.compareTo(b.staffId);
        if (staff != 0) return staff;
        final start = a.start.compareTo(b.start);
        return start != 0 ? start : a.pitch.compareTo(b.pitch);
      });
      expected.sort((a, b) {
        final staff = (a['staffId'] as String).compareTo(b['staffId'] as String);
        if (staff != 0) return staff;
        final start = (a['start'] as num).compareTo(b['start'] as num);
        return start != 0 ? start : (a['pitch'] as int).compareTo(b['pitch'] as int);
      });
      expect(actual.length, expected.length, reason: entry.key);
      for (var i = 0; i < expected.length; i++) {
        final a = actual[i], b = expected[i];
        expect(a.staffId, b['staffId'], reason: entry.key);
        expect(a.pitch, b['pitch'], reason: entry.key);
        expect(a.start, closeTo((b['start'] as num).toDouble(), 1e-9), reason: entry.key);
        expect(a.duration, closeTo((b['duration'] as num).toDouble(), 1e-9), reason: entry.key);
        expect(a.grace, b['grace'], reason: entry.key);
        expect(a.legato, b['legato'], reason: entry.key);
        expect(a.measure, b['measure'], reason: entry.key);
      }
    }
  });

  test('mixer links piano staves and resumes a sounding note after seek', () {
    final cases = jsonDecode(File('test/fixtures/browser_playback.json').readAsStringSync()) as Map<String, dynamic>;
    final timeline = PlaybackTimelineBuilder().build(cases['piano_cross_staff_graces']['score'] as Map<String, dynamic>);
    expect(timeline.events(tempo: 100, muted: {'piano'}), isEmpty);
    final events = timeline.events(tempo: 100, fromBeat: 0.5, toBeat: 1, volumes: {'piano': 0.5});
    expect(events, hasLength(1));
    expect(events.single['start'], 0);
    expect(events.single['duration'], 300);
    expect(events.single['piano'], true);
    expect(events.single['gain'] as double, closeTo(0.5 * 90 / 127, 1e-9));
  });

  test('controller sends mixed events to the native audio boundary', () async {
    const channel = MethodChannel('jp.choiromr.mobile/score');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    List? sent;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'play');
      sent = (call.arguments as Map)['events'] as List;
      return null;
    });
    final cases = jsonDecode(File('test/fixtures/browser_playback.json').readAsStringSync()) as Map<String, dynamic>;
    final timeline = PlaybackTimelineBuilder().build(cases['piano_cross_staff_graces']['score'] as Map<String, dynamic>);
    final count = await const PlaybackController().play(timeline, tempo: 100, solo: {'piano'});
    expect(count, 4);
    expect(sent, hasLength(4));
    expect(sent!.every((event) => event['piano'] == true), isTrue);
  });
}
