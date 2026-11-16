import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/playback_transport.dart';
import 'package:choir_mobile/playback_timeline.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jp.choiromr.mobile/score');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late PlaybackTransport transport;
  late List<MethodCall> calls;
  var positionMs = 0;
  var running = false;
  String? interruption;
  Completer<Map<String, Object>>? delayedStatus;

  setUp(() {
    transport = PlaybackTransport(); calls = []; positionMs = 0; running = false; interruption = null; delayedStatus = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'play') { running = true; positionMs = 0; interruption = null; }
      if (call.method == 'stop') running = false;
      if (call.method == 'playbackStatus') return delayedStatus?.future ?? {'playing': running, 'positionMs': positionMs, 'interruption': interruption};
      return null;
    });
  });
  tearDown(() async {
    transport.dispose();
    await Future<void>.delayed(Duration.zero);
    messenger.setMockMethodCallHandler(channel, null);
  });
  PlaybackTimeline timeline() {
    final cases = jsonDecode(File('test/fixtures/browser_playback.json').readAsStringSync());
    return PlaybackTimelineBuilder().build(cases['repeat_ties']['score']);
  }

  test('uses native position, pauses and resumes the remaining tied duration', () async {
    await transport.play(timeline(), tempo: 120, toBeat: 8);
    positionMs = 1500;
    await transport.refresh();
    expect(transport.position, 3);
    await transport.pause();
    expect(transport.playing, false);
    expect(transport.position, 3);
    await transport.resume();
    final sent = calls.lastWhere((c) => c.method == 'play').arguments as Map;
    expect(sent['lengthMs'], 2500);
    final events = sent['events'] as List;
    expect(events.first['start'], 0);
    expect(events.first['pitch'], 60);
    expect(events.first['duration'], 1500);
    await transport.seek(5);
    final seek = calls.lastWhere((c) => c.method == 'play').arguments as Map;
    expect((seek['events'] as List).first['duration'], 500);
  });
  test('ignores a late status response from before a seek', () async {
    await transport.play(timeline(), tempo: 120);
    delayedStatus = Completer<Map<String, Object>>();
    final previous = transport.refresh();
    await Future<void>.delayed(Duration.zero);
    await transport.seek(6);
    delayedStatus!.complete({'playing': false, 'positionMs': 5000});
    await previous;
    expect(transport.position, 6);
    expect(transport.playing, true);
    await expectLater(transport.seek(-1), throwsFormatException);
  });
  test('keeps a silent measure on the native clock and clears obsolete score state', () async {
    final silent = PlaybackTimelineBuilder().build({'staves': [
      {'id': 's', 'role': 'voice', 'measures': [{'time_sig': [4, 4], 'events': []}]}
    ]});
    expect(await transport.play(silent, tempo: 120), 0);
    final sent = calls.lastWhere((c) => c.method == 'play').arguments as Map;
    expect(sent['events'], isEmpty); expect(sent['lengthMs'], 2000);
    positionMs = 2000; running = false;
    await transport.refresh();
    expect(transport.position, 4); expect(transport.playing, false);
    await transport.reset();
    expect(transport.timeline, null); expect(transport.position, 0);
  });
  test('loop seek and resume retain the full range and use a native phase offset', () async {
    await transport.play(timeline(), tempo: 120, fromBeat: 2, toBeat: 8, loop: true);
    await transport.seek(5);
    final seek = calls.lastWhere((c) => c.method == 'play').arguments as Map;
    expect(seek['loop'], true);
    expect(seek['lengthMs'], 3000);
    expect(seek['offsetMs'], 1500);
    // The held note is still generated from range start, not just seek position.
    expect((seek['events'] as List).first['duration'], 2000);
    positionMs = 250;
    await transport.refresh();
    expect(transport.position, 2.5);
    await transport.pause();
    await transport.resume();
    final resume = calls.lastWhere((c) => c.method == 'play').arguments as Map;
    expect(resume['lengthMs'], 3000);
    expect(resume['offsetMs'], 250);
  });
  test('an audio interruption preserves position and requires manual resume', () async {
    await transport.play(timeline(), tempo: 120);
    positionMs = 1250; running = false; interruption = 'Headphones disconnected';
    await transport.refresh();
    expect(transport.position, 2.5);
    expect(transport.playing, false);
    expect(transport.interruption, 'Headphones disconnected');
    expect(calls.where((c) => c.method == 'play'), hasLength(1));
    await transport.resume();
    expect(transport.interruption, null);
    expect(calls.where((c) => c.method == 'play'), hasLength(2));
  });
  test('live mixer changes preserve native held notes; tempo uses current head', () async {
    await transport.play(timeline(), tempo: 120);
    positionMs = 1500;
    await transport.update(volumes: {'s': 0.2}, muted: {'s'}, solo: {'s'}, master: 0.5,
      instruments: {'s': 'organ'});
    expect(calls.where((c) => c.method == 'play'), hasLength(1));
    final mix = calls.lastWhere((c) => c.method == 'updateMixer').arguments as Map;
    expect(mix['master'], 0.5); expect(mix['solo'], ['s']); expect(mix['instruments'], {'s': 'organ'});
    await transport.update(tempo: 60);
    expect(transport.position, 3); expect(transport.playing, true);
    final sent = calls.lastWhere((c) => c.method == 'play').arguments as Map;
    expect((sent['events'] as List).first['duration'], 3000);
    expect((sent['mixer'] as Map)['master'], 0.5);
    positionMs = 1000; await transport.refresh();
    expect(transport.position, 4);
  });
  test('count-in respects eighth-note beats and is excluded from repeated score', () async {
    await transport.play(timeline(), tempo: 120, fromBeat: 0, toBeat: 8, loop: true,
      countInBeats: 3, countInUnit: 0.5, clicks: [0, 1, 2, 3, 4, 5, 6, 7]);
    final sent = calls.lastWhere((c) => c.method == 'play').arguments as Map;
    expect(sent['lengthMs'], 5500); expect(sent['loopStartMs'], 1500);
    final count = (sent['events'] as List).where((e) => e['partId'] == '_countin').toList();
    expect(count, hasLength(6)); expect(count.last['start'], 1250);
    positionMs = 1000; await transport.refresh(); expect(transport.position, 0);
    positionMs = 2000; await transport.refresh(); expect(transport.position, 1);
    await transport.pause(); await transport.resume();
    final resumed = calls.lastWhere((c) => c.method == 'play').arguments as Map;
    expect(resumed['loopStartMs'], 0);
    expect((resumed['events'] as List).where((e) => e['partId'] == '_countin'), isEmpty);
  });
}
