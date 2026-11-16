import 'package:flutter/services.dart';
import 'playback_timeline.dart';

/// Thin transport boundary; event timing is calculated in the shared layer,
/// then the Android audio thread renders the events on a sample clock.
class PlaybackController {
  const PlaybackController();
  static const _channel = MethodChannel('jp.choiromr.mobile/score');

  Future<int> play(PlaybackTimeline timeline, {required double tempo, double fromBeat = 0,
    double? toBeat, Map<String, double> volumes = const {}, Set<String> muted = const {},
    Set<String> solo = const {}, bool keepSilence = false, bool loop = false, double? startAtBeat,
    double master = 0.8, Map<String, String> instruments = const {}, List<double> clicks = const [],
    double metroVolume = 0.6, double countInBeats = 0, double countInUnit = 1}) async {
    if (!countInUnit.isFinite || countInUnit <= 0 || !countInBeats.isFinite || countInBeats < 0) {
      throw const FormatException('カウントの拍子が不正です。');
    }
    final events = timeline.events(tempo: tempo, fromBeat: fromBeat, toBeat: toBeat);
    final prefixMs = (countInBeats * 60000 / tempo).round();
    for (final e in events) { e['start'] = (e['start'] as int) + prefixMs; }
    for (var i = 0; i < clicks.length; i++) {
      if (clicks[i] < fromBeat || clicks[i] >= (toBeat ?? timeline.totalBeats)) continue;
      events.add({'pitch': 100, 'start': ((clicks[i] - fromBeat) * 60000 / tempo).round() + prefixMs,
        'duration': 40, 'gain': 1.0, 'partId': '_metronome',
        'accent': timeline.measureStarts.any((b) => (b - clicks[i]).abs() < 0.00001)});
    }
    for (var i = 0.0; i < countInBeats - 0.00001; i += countInUnit) {
      events.add({'pitch': 100, 'start': (i * 60000 / tempo).round(), 'duration': 40,
        'gain': 1.0, 'partId': '_countin', 'accent': i == 0});
    }
    if (events.isNotEmpty || keepSilence) {
      final lengthMs = (((toBeat ?? timeline.totalBeats) - fromBeat) * 60000 / tempo).round() + prefixMs;
      final start = startAtBeat ?? fromBeat;
      if (!start.isFinite || start < fromBeat || start > (toBeat ?? timeline.totalBeats) || (!loop && startAtBeat != null)) {
        throw const FormatException('反復の再開位置が不正です。');
      }
      final offsetMs = ((start - fromBeat) * 60000 / tempo).round();
      if (lengthMs > 1800000) throw const FormatException('再生は30分以内です。');
      await _channel.invokeMethod<void>('play', {'events': events, 'lengthMs': lengthMs, 'loop': loop,
        'offsetMs': offsetMs, 'loopStartMs': prefixMs,
        'mixer': mixer(volumes, muted, solo, master, instruments, metroVolume)});
    } else {
      await stop();
    }
    return events.length;
  }

  Future<void> stop() => _channel.invokeMethod<void>('stop');
  static Map<String, Object> mixer(Map<String, double> volumes, Set<String> muted, Set<String> solo,
    double master, Map<String, String> instruments, double metroVolume) =>
      {'volumes': volumes, 'muted': muted.toList(), 'solo': solo.toList(), 'master': master,
        'instruments': instruments, 'metroVolume': metroVolume};
  Future<void> updateMixer({Map<String, double> volumes = const {}, Set<String> muted = const {},
    Set<String> solo = const {}, double master = 0.8, Map<String, String> instruments = const {},
    double metroVolume = 0.6}) => _channel.invokeMethod<void>('updateMixer',
      mixer(volumes, muted, solo, master, instruments, metroVolume));
  Future<Map<Object?, Object?>> status() async => await _channel.invokeMapMethod<Object?, Object?>('playbackStatus') ?? {};
}
