import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/midi_export.dart';
import 'package:choir_mobile/playback_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports browser reference performances as multitrack MIDI', () {
    final cases = jsonDecode(File('test/fixtures/browser_playback.json').readAsStringSync()) as Map;
    final target = Directory(Platform.environment['MOBILE_MIDI_OUTPUT'] ?? '.dart_tool/midi-export-check')..createSync(recursive: true);
    for (final entry in cases.entries) {
      final score = entry.value['score'] as Map<String, dynamic>;
      final bytes = MidiExporter().export(score);
      expect(ascii.decode(bytes.take(4).toList()), 'MThd');
      expect(bytes.sublist(8, 10), [0, 1]);
      File('${target.path}/${entry.key}.mid').writeAsBytesSync(bytes);
      final notes = PlaybackTimelineBuilder().build(score).notes;
      File('${target.path}/${entry.key}.json').writeAsStringSync(jsonEncode({
        'tempo': score['tempo_bpm'], 'notes': [for (final n in notes)
          {'part': n.partId, 'pitch': n.pitch, 'start': (n.start * MidiExporter.ticksPerBeat).round(),
            'end': ((n.start + n.duration) * MidiExporter.ticksPerBeat).round()}],
      }));
    }
  });

  test('rejects invalid tempos', () {
    final cases = jsonDecode(File('test/fixtures/browser_playback.json').readAsStringSync()) as Map;
    final score = cases.values.first['score'] as Map<String, dynamic>;
    expect(() => MidiExporter().export(score, tempo: 0), throwsFormatException);
    expect(() => MidiExporter().export(score, tempo: double.nan), throwsFormatException);
  });
}
