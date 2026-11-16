import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'playback_timeline.dart';

/// Standard MIDI file, type 1. Uses the same performed notes as the player.
class MidiExporter {
  static const ticksPerBeat = 9600;

  Uint8List export(Map<String, dynamic> score, {double? tempo, Set<String>? partsOnly,
    Map<String, int> velocities = const {}}) {
    final bpm = tempo ?? (score['tempo_bpm'] as num?)?.toDouble() ?? 80;
    if (!bpm.isFinite || bpm <= 0 || bpm > 400) {
      throw const FormatException('MIDI のテンポが不正です。');
    }
    final micros = (60000000 / bpm).round();
    if (micros > 0xffffff) throw const FormatException('MIDI のテンポが遅すぎます。');
    final timeline = PlaybackTimelineBuilder().build(score);
    if (!timeline.validRepeats) throw const FormatException('反復設定を確認してから MIDI を書き出してください。');
    final end = (timeline.totalBeats * ticksPerBeat).round();
    final parts = <String, Map>{};
    for (final staff in score['staves'] as List) {
      final id = ['piano_rh', 'piano_lh'].contains(staff['role']) ? 'piano' : '${staff['id']}';
      if (partsOnly != null && !partsOnly.contains(id)) continue;
      parts.putIfAbsent(id, () => staff as Map);
    }
    if (parts.length > 15) throw const FormatException('MIDI の声部が多すぎます。');
    final tracks = <Uint8List>[];
    tracks.add(_track([
      _Event(0, 0, _meta(3, utf8.encode('${score['title'] ?? '音鳥'}'))),
      _Event(0, 1, [0xff, 0x51, 3, (micros >> 16) & 255, (micros >> 8) & 255, micros & 255]),
    ], end));
    var index = 0;
    for (final entry in parts.entries) {
      final channel = index < 9 ? index : index + 1;
      index++;
      final piano = entry.key == 'piano';
      final program = piano ? 0 : (entry.value['midi_program'] as int? ?? 52);
      if (program < 0 || program > 127) throw const FormatException('MIDI 音色が不正です。');
      final events = <_Event>[
        _Event(0, -2, _meta(3, utf8.encode('${entry.value['name'] ?? entry.key}'))),
        _Event(0, -1, [0xc0 | channel, program]),
      ];
      // A MIDI channel cannot release just one of two overlapping equal pitches.
      // Merge their sounding intervals so the longer note is not cut short.
      final byPitch = <int, List<PlaybackNote>>{};
      for (final note in timeline.notes.where((n) => n.partId == entry.key)) {
        byPitch.putIfAbsent(note.pitch, () => []).add(note);
      }
      for (final pitch in byPitch.entries) {
        final notes = pitch.value..sort((a, b) => a.start.compareTo(b.start));
        int? start;
        var finish = 0, velocity = 90;
        void flush() {
          if (start == null) return;
          events.add(_Event(start, 1, [0x90 | channel, pitch.key, velocity]));
          events.add(_Event(finish, 0, [0x80 | channel, pitch.key, 0]));
        }
        for (final note in notes) {
          final first = (note.start * ticksPerBeat).round().clamp(0, end);
          final last = math.min(end, ((note.start + note.duration) * ticksPerBeat).round());
          if (last <= first) continue;
          if (start != null && first < finish) {
            finish = math.max(finish, last);
          } else {
            flush();
            start = first; finish = last;
            velocity = velocities[entry.key] ?? (note.velocity * 127).round().clamp(1, 127);
            if (velocity < 1 || velocity > 127) throw const FormatException('MIDI の音量が不正です。');
          }
        }
        flush();
      }
      tracks.add(_track(events, end));
    }
    final out = BytesBuilder();
    out.add(ascii.encode('MThd'));
    out.add(_be32(6));
    out.add([0, 1, (tracks.length >> 8) & 255, tracks.length & 255,
      ticksPerBeat >> 8, ticksPerBeat & 255]);
    for (final track in tracks) { out.add(track); }
    return out.takeBytes();
  }
}

class _Event {
  const _Event(this.tick, this.priority, this.bytes);
  final int tick, priority;
  final List<int> bytes;
}

List<int> _meta(int type, List<int> bytes) => [0xff, type, ..._vlq(bytes.length), ...bytes];
List<int> _be32(int value) => [(value >> 24) & 255, (value >> 16) & 255, (value >> 8) & 255, value & 255];
List<int> _vlq(int value) {
  if (value < 0 || value > 0xfffffff) throw const FormatException('MIDI の時間範囲を超えています。');
  final result = <int>[value & 127];
  while ((value >>= 7) > 0) { result.insert(0, (value & 127) | 128); }
  return result;
}
Uint8List _track(List<_Event> events, int end) {
  events.sort((a, b) => a.tick != b.tick ? a.tick.compareTo(b.tick) : a.priority.compareTo(b.priority));
  final data = BytesBuilder();
  var previous = 0;
  for (final event in events) {
    data.add(_vlq(event.tick - previous)); data.add(event.bytes); previous = event.tick;
  }
  data.add([..._vlq(math.max(0, end - previous)), 0xff, 0x2f, 0]);
  final bytes = data.takeBytes();
  return Uint8List.fromList([...ascii.encode('MTrk'), ..._be32(bytes.length), ...bytes]);
}
