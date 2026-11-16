import 'dart:collection';
import 'dart:math' as math;

import 'repeat_plan.dart';
import 'score.dart';

class PlaybackNote {
  PlaybackNote({required this.staffId, required this.partId, required this.role,
    required this.pitch, required this.start, required this.duration, required this.velocity,
    required this.grace, required this.voice, required this.measure, required this.sourceMeasure,
    required this.legato});
  final String staffId, partId, role;
  final int pitch, voice, measure, sourceMeasure;
  final double start, velocity;
  double duration;
  final bool grace;
  bool legato;
  /// Tuning offset from equal temperament (just intonation); 0 = unchanged.
  /// The written [pitch] never changes.
  double cents = 0;
}

class PlaybackTimeline {
  const PlaybackTimeline({required this.notes, required this.order, required this.measureStarts,
    required this.measureLengths, required this.warnings, required this.validRepeats});
  final List<PlaybackNote> notes;
  final List<int> order;
  final List<double> measureStarts, measureLengths;
  final List<String> warnings;
  final bool validRepeats;

  double get totalBeats => measureStarts.isEmpty ? 0 : measureStarts.last + measureLengths.last;

  /// Produce sample-scheduled Android events. A seek into a held note resumes
  /// its remaining duration; the source score and repeat order remain intact.
  List<Map<String, Object>> events({required double tempo, double fromBeat = 0,
    double? toBeat, Map<String, double> volumes = const {}, Set<String> muted = const {},
    Set<String> solo = const {}}) {
    final end = toBeat ?? totalBeats;
    if (!tempo.isFinite || tempo <= 0 || tempo > 400 || !fromBeat.isFinite || !end.isFinite ||
        fromBeat < 0 || end > totalBeats + 1e-8 || end <= fromBeat) {
      throw const FormatException('再生範囲またはテンポが不正です。');
    }
    final output = <Map<String, Object>>[];
    for (final note in notes) {
      if (muted.contains(note.partId) || (solo.isNotEmpty && !solo.contains(note.partId))) continue;
      final gain = volumes[note.partId] ?? 1.0;
      if (!gain.isFinite || gain < 0 || gain > 1) throw const FormatException('音量が不正です。');
      final start = math.max(note.start, fromBeat);
      final finish = math.min(note.start + note.duration, end);
      if (finish <= start || gain == 0) continue;
      final startMs = ((start - fromBeat) * 60000 / tempo).round();
      final endMs = ((finish - fromBeat) * 60000 / tempo).round();
      if (endMs > 1800000 || endMs <= startMs) throw const FormatException('試聴できない曲の長さです。');
      output.add({'pitch': note.pitch, 'start': startMs, 'duration': endMs - startMs,
        'piano': note.role == 'piano_rh' || note.role == 'piano_lh',
        'gain': gain * note.velocity, 'legato': note.legato, 'partId': note.partId,
        if (note.cents != 0) 'cents': note.cents});
    }
    if (output.length > 50000) throw const FormatException('音符が多すぎます。');
    _stableSort(output, (a, b) => (a['start'] as int).compareTo(b['start'] as int));
    return output;
  }
}

class _Timing {
  const _Timing(this.onset, this.duration);
  final double onset, duration;
}

/// Creates the same expanded note timeline as the browser player, including
/// repeat jumps, tied notes, grace timing and cross-staff piano grace runs.
class PlaybackTimelineBuilder {
  PlaybackTimeline build(Map<String, dynamic> score) {
    final staves = (score['staves'] as List).cast<Map>();
    final repeat = RepeatPlanner().build(score);
    final order = repeat.order;
    Map? reference;
    for (final staff in staves) {
      if (reference == null || (staff['measures'] as List).length > (reference['measures'] as List).length) reference = staff;
    }
    final starts = <double>[];
    final lengths = <double>[];
    double cursor = 0;
    for (final index in order) {
      final measures = reference!['measures'] as List;
      final m = measures[index] as Map;
      final length = _measureLength(m);
      starts.add(cursor); lengths.add(length); cursor += length;
    }

    // Every occurrence gets a separate event map, so repeat jumps can clear
    // tie/slur endpoints without modifying the saved score.
    final expanded = <List<Map<String, dynamic>>>[];
    for (final staff in staves) {
      final originals = staff['measures'] as List;
      final measures = <Map<String, dynamic>>[];
      for (var pos = 0; pos < order.length; pos++) {
        final source = order[pos];
        final original = source < originals.length ? originals[source] as Map : const {'events': [], 'time_sig': [4, 4]};
        final jumpIn = pos > 0 && source != order[pos - 1] + 1;
        final jumpOut = pos + 1 < order.length && order[pos + 1] != source + 1;
        final copy = Map<String, dynamic>.from(original);
        copy['events'] = (original['events'] as List).map((raw) {
          final event = Map<String, dynamic>.from(raw as Map);
          if (jumpIn) { event['tie_stop'] = false; event['slur_stops'] = <String>[]; }
          if (jumpOut) { event['tie_start'] = false; event['slur_starts'] = <String>[]; }
          return event;
        }).toList();
        measures.add(copy);
      }
      expanded.add(measures);
    }

    final plans = <List<Map<Map<String, dynamic>, _Timing>>>[];
    final pianoGroups = <String, List<(int, int, Map<String, dynamic>)>>{};
    for (var s = 0; s < staves.length; s++) {
      plans.add(expanded[s].map((m) => _eventTimings(m)).toList());
      if (!['piano_rh', 'piano_lh'].contains(staves[s]['role'])) continue;
      for (var mi = 0; mi < expanded[s].length; mi++) {
        for (final event in (expanded[s][mi]['events'] as List).cast<Map<String, dynamic>>()) {
          final count = event['grace_count'];
          if (event['grace'] == true && (event['pitches'] as List).isNotEmpty &&
              event['grace_index'] is int && count is int && count > 0 && count <= 256) {
            final key = '$mi:${_beat(event['onset'])}:$count';
            pianoGroups.putIfAbsent(key, () => []).add((s, mi, event));
          }
        }
      }
    }
    final limits = <(int, int), Map<String, double>>{};
    for (final entries in pianoGroups.values) {
      final count = entries.first.$3['grace_count'] as int;
      final ids = entries.map((e) => e.$1).toSet();
      final indices = entries.map((e) => e.$3['grace_index'] as int).toList()..sort();
      if (ids.length < 2 || entries.length != count || List.generate(count, (i) => i).asMap().entries.any((e) => indices[e.key] != e.value)) continue;
      final span = entries.map((e) => plans[e.$1][e.$2][e.$3]!.duration * count).reduce(math.min);
      for (final entry in entries) {
        final key = '${_beat(entry.$3['onset'])}:${entry.$3['voice'] ?? 0}';
        limits.putIfAbsent((entry.$1, entry.$2), () => {})[key] = span;
      }
    }

    final output = <PlaybackNote>[];
    for (var s = 0; s < staves.length; s++) {
      final staff = staves[s];
      final role = (staff['role'] ?? 'unknown') as String;
      final id = (staff['id'] ?? 'S${s + 1}') as String;
      final partId = role == 'piano_rh' || role == 'piano_lh' ? 'piano' : id;
      final notes = <PlaybackNote>[];
      final pending = <String, PlaybackNote>{};
      final phrases = <int, Set<String>>{};
      final phraseEnds = <String, double>{};
      for (var mi = 0; mi < order.length; mi++) {
        for (final event in (expanded[s][mi]['events'] as List).cast<Map<String, dynamic>>()) {
          for (final slur in (event['slur_stops'] as List? ?? const [])) { phraseEnds[slur as String] = starts[mi] + _beat(event['onset']); }
        }
      }
      for (var mi = 0; mi < order.length; mi++) {
        if (mi > 0 && order[mi] != order[mi - 1] + 1) { pending.clear(); phrases.clear(); }
        final measure = expanded[s][mi];
        final timings = limits.containsKey((s, mi)) ? _eventTimings(measure, limits[(s, mi)]!) : plans[s][mi];
        final events = (measure['events'] as List).cast<Map<String, dynamic>>().toList();
        _stableSort(events, (a, b) => _beat(a['onset']).compareTo(_beat(b['onset'])));
        for (final event in events) {
          final timing = timings[event];
          final onset = starts[mi] + (timing?.onset ?? _beat(event['onset']));
          final duration = timing?.duration ?? _beat(event['duration']);
          final voice = (event['voice'] as int?) ?? 0;
          final active = phrases.putIfAbsent(voice, () => <String>{});
          active.removeWhere((id) => (phraseEnds[id] ?? double.negativeInfinity) <= onset);
          for (final id in (event['slur_stops'] as List? ?? const [])) { active.remove(id); }
          for (final id in (event['slur_starts'] as List? ?? const [])) { if ((phraseEnds[id] ?? double.negativeInfinity) > onset) active.add(id as String); }
          final pitches = event['pitches'] as List;
          if (pitches.isEmpty) { active.clear(); continue; }
          if (!onset.isFinite || !duration.isFinite || onset < 0 || duration < 0) throw const FormatException('音符の時刻が不正です。');
          final velocity = ((event['velocity'] as num?)?.toDouble() ?? 90) / 127;
          for (final rawPitch in pitches) {
            final pitch = rawPitch as int;
            if (pitch < 0 || pitch > 127 || velocity < 0 || velocity > 1) throw const FormatException('音高または強さが不正です。');
            final key = '$voice:$pitch';
            var tied = event['tie_stop'] == true ? pending[key] : null;
            if ((tied == null || (tied.start + tied.duration - onset).abs() >= 0.001) && event['tie_stop'] == true && _beat(event['onset']) == 0) {
              final candidates = pending.values.toSet().where((n) => n.pitch == pitch && n.measure < mi && (n.start + n.duration - onset).abs() < 0.001).toList();
              tied = candidates.length == 1 ? candidates.single : null;
            }
            if (tied != null && (tied.start + tied.duration - onset).abs() < 0.001) {
              tied.duration += duration; tied.legato = active.isNotEmpty;
              pending.removeWhere((_, value) => identical(value, tied));
              if (event['tie_start'] == true) pending[key] = tied;
              continue;
            }
            pending.remove(key);
            final note = PlaybackNote(staffId: id, partId: partId, role: role, pitch: pitch,
              start: onset, duration: duration, velocity: velocity, grace: event['grace'] == true,
              voice: voice, measure: mi, sourceMeasure: order[mi], legato: event['grace'] == true || active.isNotEmpty);
            notes.add(note);
            if (event['tie_start'] == true) pending[key] = note;
          }
        }
      }
      _stableSort(notes, (a, b) => a.start.compareTo(b.start));
      final previous = <int, List<PlaybackNote>>{};
      for (final note in notes) {
        if (note.grace) {
          for (final prior in previous[note.voice] ?? const <PlaybackNote>[]) {
            if (prior.start < note.start && prior.start + prior.duration > note.start) prior.duration = note.start - prior.start;
          }
        }
        final last = previous[note.voice] ?? [];
        previous[note.voice] = last.isNotEmpty && (last.first.start - note.start).abs() < 1e-9 ? [...last, note] : [note];
      }
      output.addAll(notes);
    }
    _stableSort(output, (a, b) => a.start.compareTo(b.start));
    return PlaybackTimeline(notes: output, order: order, measureStarts: starts, measureLengths: lengths,
      warnings: repeat.warnings, validRepeats: repeat.valid);
  }

  static Map<Map<String, dynamic>, _Timing> _eventTimings(Map<String, dynamic> measure, [Map<String, double> limits = const {}]) {
    final result = HashMap<Map<String, dynamic>, _Timing>.identity();
    final groups = <String, List<Map<String, dynamic>>>{};
    final events = (measure['events'] as List).cast<Map<String, dynamic>>();
    for (final e in events) {
      if (e['grace'] != true || (e['pitches'] as List).isEmpty) continue;
      groups.putIfAbsent('${_beat(e['onset'])}:${e['voice'] ?? 0}', () => []).add(e);
    }
    final length = _measureLength(measure);
    for (final entry in groups.entries) {
      final group = entry.value;
      final explicit = group.every((e) => e['grace_index'] is int && e['grace_count'] is int &&
        (e['grace_index'] as int) >= 0 && (e['grace_index'] as int) < (e['grace_count'] as int) &&
        (e['grace_count'] as int) <= 256 && e['grace_count'] == group.first['grace_count']);
      final count = explicit ? group.first['grace_count'] as int : group.length;
      final anchor = _beat(group.first['onset']).clamp(0.0, length);
      var span = math.min(0.0625 * count, limits[entry.key] ?? double.infinity);
      final following = events.where((e) => e['grace'] != true && (e['voice'] ?? 0) == (group.first['voice'] ?? 0) && _beat(e['onset']) >= anchor).toList();
      double start;
      if (anchor > 0) { span = math.min(span, anchor); start = anchor - span; }
      else {
        span = math.min(span, length);
        for (final e in following) {
          final duration = _beat(e['duration']);
          if (duration > 0) span = math.min(span, _beat(e['onset']) == 0 ? duration / 2 : _beat(e['onset']));
        }
        start = 0;
        for (final e in following) {
          final duration = _beat(e['duration']);
          if (_beat(e['onset']) == 0 && duration > span) result[e] = _Timing(span, duration - span);
        }
      }
      for (var i = 0; i < group.length; i++) {
        final slot = explicit ? group[i]['grace_index'] as int : i;
        result[group[i]] = _Timing(start + span / count * slot, span / count);
      }
    }
    return result;
  }

  static double _beat(dynamic value) {
    final number = ScoreDocument.beat(value);
    if (!number.isFinite) throw const FormatException('拍の値が不正です。');
    return number;
  }

  static double _measureLength(Map measure) {
    final time = measure['time_sig'] ?? [4, 4];
    if (time is! List || time.length != 2 || time[0] is! num || time[1] is! num || time[0] <= 0 || time[1] <= 0) {
      throw const FormatException('拍子が不正です。');
    }
    return (time[0] as num) * 4 / (time[1] as num);
  }
}

void _stableSort<T>(List<T> values, int Function(T, T) compare) {
  final indexed = values.asMap().entries.toList();
  indexed.sort((a, b) {
    final result = compare(a.value, b.value);
    return result != 0 ? result : a.key.compareTo(b.key);
  });
  for (var i = 0; i < indexed.length; i++) { values[i] = indexed[i].value; }
}
