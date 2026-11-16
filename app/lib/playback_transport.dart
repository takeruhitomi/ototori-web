import 'dart:async';
import 'package:flutter/foundation.dart';
import 'playback_controller.dart';
import 'playback_timeline.dart';

/// UI transport follows the native playback head; timers never schedule notes.
class PlaybackTransport extends ChangeNotifier {
  PlaybackTransport({PlaybackController controller = const PlaybackController()}) : _controller = controller;
  final PlaybackController _controller;
  PlaybackTimeline? timeline;
  double position = 0, rangeFrom = 0, rangeTo = 0;
  bool playing = false;
  bool looping = false;
  String? error;
  String? interruption;
  double _tempo = 80, _origin = 0;
  Map<String, double> _volumes = {};
  Set<String> _muted = {}, _solo = {};
  double _master = 0.8, _metroVolume = 0.6, _prefix = 0;
  Map<String, String> _instruments = {};
  List<double> _clicks = [];
  Future<void> _tail = Future.value();
  Timer? _timer;
  bool _disposed = false, _polling = false;
  int _epoch = 0;

  Future<T> _run<T>(Future<T> Function() action) {
    final result = _tail.then((_) async {
      if (_disposed) throw StateError('Transport is disposed');
      _epoch++; _timer?.cancel();
      try { return await action(); }
      catch (_) { if (playing && !_disposed) _beginPolling(); rethrow; }
    });
    _tail = result.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return result;
  }

  Future<int> play(PlaybackTimeline score, {required double tempo, double fromBeat = 0,
    double? toBeat, Map<String, double> volumes = const {}, Set<String> muted = const {}, Set<String> solo = const {}, bool loop = false,
    double master = 0.8, Map<String, String> instruments = const {}, List<double> clicks = const [],
    double metroVolume = 0.6, double countInBeats = 0, double countInUnit = 1, bool start = true}) => _run(() async {
    await _controller.stop();
    playing = false;
    timeline = score; _tempo = tempo; rangeFrom = fromBeat; rangeTo = toBeat ?? score.totalBeats;
    looping = loop;
    position = fromBeat; _volumes = Map.of(volumes); _muted = Set.of(muted); _solo = Set.of(solo);
    _master = master; _instruments = Map.of(instruments); _clicks = List.of(clicks); _metroVolume = metroVolume;
    if (!start) {
      _prefix = 0; _origin = position; error = null; interruption = null;
      final count = score.events(tempo: tempo, fromBeat: rangeFrom, toBeat: rangeTo).length;
      _notify(); return count;
    }
    return _start(countInBeats: countInBeats, countInUnit: countInUnit);
  });

  Future<int> _start({double countInBeats = 0, double countInUnit = 1}) async {
    error = null; interruption = null; _origin = looping ? rangeFrom : position;
    _prefix = countInBeats;
    final count = await _controller.play(timeline!, tempo: _tempo, fromBeat: looping ? rangeFrom : position, toBeat: rangeTo,
      volumes: _volumes, muted: _muted, solo: _solo, keepSilence: true, loop: looping,
      startAtBeat: looping ? position : null, master: _master, instruments: _instruments,
      clicks: _clicks, metroVolume: _metroVolume, countInBeats: countInBeats, countInUnit: countInUnit);
    playing = true;
    _beginPolling();
    _notify();
    return count;
  }

  void _beginPolling() {
    _timer?.cancel();
    final epoch = _epoch;
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      refresh().catchError((Object e) {
        if (_disposed || epoch != _epoch) return;
        error = '$e'; playing = false; _timer?.cancel(); _notify();
        _controller.stop().catchError((Object _) {});
      });
    });
  }

  Future<void> refresh() async {
    if (!playing || _disposed || _polling) return;
    _polling = true;
    final epoch = _epoch;
    try {
      final status = await _controller.status();
      if (_disposed || epoch != _epoch) return;
      if (status['error'] is String) throw FormatException('音声再生に失敗しました: ${status['error']}');
      if (status['positionMs'] is! num || status['playing'] is! bool) throw const FormatException('再生位置を取得できません。');
      position = (_origin + (status['positionMs'] as num) * _tempo / 60000 - _prefix).clamp(rangeFrom, rangeTo);
      playing = status['playing'] as bool;
      interruption = status['interruption'] as String?;
      if (!playing) _timer?.cancel();
      _notify();
    } finally { _polling = false; }
  }

  Future<void> pause() => _run(() async {
    if (playing) {
      final status = await _controller.status();
      if (status['positionMs'] is num) position = (_origin + (status['positionMs'] as num) * _tempo / 60000 - _prefix).clamp(rangeFrom, rangeTo);
    }
    await _controller.stop(); playing = false; _notify();
  });

  Future<void> resume() => _run(() async {
    if (timeline == null) return;
    if (position >= rangeTo) position = rangeFrom;
    await _controller.stop(); playing = false;
    await _start();
  });

  Future<void> seek(double beat) => _run(() async {
    if (timeline == null || !beat.isFinite || beat < rangeFrom || beat > rangeTo) throw const FormatException('再生位置が範囲外です。');
    final resume = playing;
    await _controller.stop(); playing = false; position = beat;
    if (resume && beat < rangeTo) { await _start(); } else { _notify(); }
  });

  Future<void> stop() => _run(() async {
    await _controller.stop(); playing = false; position = rangeFrom; _notify();
  });

  /// Gain and instrument changes reach the rendering thread without restarting
  /// held notes. Tempo/range changes restart from the sampled playback head.
  Future<void> update({double? tempo, Map<String, double>? volumes, Set<String>? muted, Set<String>? solo,
    double? master, Map<String, String>? instruments, List<double>? clicks, double? metroVolume,
    bool? loop, double? fromBeat, double? toBeat}) => _run(() async {
    final restart = (tempo != null && tempo != _tempo) || clicks != null || loop != null || fromBeat != null || toBeat != null;
    final wasPlaying = playing;
    if (restart && playing) {
      final status = await _controller.status();
      if (status['positionMs'] is num) position = (_origin + (status['positionMs'] as num) * _tempo / 60000 - _prefix).clamp(rangeFrom, rangeTo);
      await _controller.stop(); playing = false;
    }
    if (tempo != null) _tempo = tempo;
    if (volumes != null) _volumes = Map.of(volumes);
    if (muted != null) _muted = Set.of(muted);
    if (solo != null) _solo = Set.of(solo);
    if (master != null) _master = master;
    if (instruments != null) _instruments = Map.of(instruments);
    if (clicks != null) _clicks = List.of(clicks);
    if (metroVolume != null) _metroVolume = metroVolume;
    if (loop != null) looping = loop;
    if (fromBeat != null) rangeFrom = fromBeat;
    if (toBeat != null) rangeTo = toBeat;
    position = position.clamp(rangeFrom, rangeTo);
    await _controller.updateMixer(volumes: _volumes, muted: _muted, solo: _solo,
      master: _master, instruments: _instruments, metroVolume: _metroVolume);
    if (restart && wasPlaying && position < rangeTo) { await _start(); }
    else if (playing) { _beginPolling(); }
    _notify();
  });

  /// Re-sends the notes from the playback head, e.g. after per-note tuning
  /// changed. A paused transport picks the change up when it resumes.
  Future<void> reload() => _run(() async {
    if (timeline == null || !playing) { _notify(); return; }
    final status = await _controller.status();
    if (status['positionMs'] is num) position = (_origin + (status['positionMs'] as num) * _tempo / 60000 - _prefix).clamp(rangeFrom, rangeTo);
    await _controller.stop(); playing = false;
    if (position < rangeTo) { await _start(); } else { _notify(); }
  });

  Future<void> reset() => _run(() async {
    await _controller.stop(); playing = false; timeline = null;
    position = 0; rangeFrom = 0; rangeTo = 0; error = null; interruption = null; looping = false; _notify();
  });

  void _notify() { if (!_disposed) notifyListeners(); }
  @override
  void dispose() {
    _disposed = true; _epoch++; _timer?.cancel();
    _tail.then((_) => _controller.stop()).catchError((Object _) {});
    super.dispose();
  }
}
