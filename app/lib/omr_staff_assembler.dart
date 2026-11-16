import 'omr_symbols.dart';

/// Slur ends left open at a staff's edges (a tie or slur continuing into
/// the next system). Only joinSystemTies reads them; it removes them all.
const openSlurStart = '~open-start';
const openSlurStop = '~open-stop';

/// A deliberately strict first stage of model-symbol -> score conversion.
/// Unsupported notation throws instead of producing a silently incorrect score.
/// Ensemble alignment, endings and complex overlapping voices are not yet done.
class OmrStaffAssembler {
  /// Call once after ensemble meter alignment; consumes matching slur endpoints.
  static void resolveTies(Map<String, dynamic> staff) {
    final measures = (staff['measures'] as List).cast<Map<String, dynamic>>();
    _recognizeSimpleTies(measures);
  }
  /// [keepOpenSlurs]: mark slur ends left open at the staff's edges with
  /// [openSlurStart] / [openSlurStop] instead of dropping them (the caller
  /// joins systems and must remove the markers).
  Map<String, dynamic> assemble(List<OmrSymbol> symbols,
      {String staffId = 'S1', bool detectTies = true, bool keepOpenSlurs = false}) {
    final measures = <_Measure>[];
    var current = _Measure(1);
    var cursor = BeatFraction.zero;
    var keyFifths = 0;
    var clef = '';
    int? denominator;
    String? activeSlur;
    Map<String, dynamic>? activeSlurStart;
    var slurCounter = 0;
    var pageNumber = 1;
    var systemNumber = 0;
    final warnings = <String>[];
    var placeholder = false;
    // Page position of the current bar's left end (staff start or barline).
    SymbolPlace? boundary;

    void closeMeasure() {
      if (current.events.isEmpty) return;
      current.length = cursor;
      measures.add(current);
      current = _Measure(measures.length + 1);
      current.page = pageNumber;
      current.system = systemNumber;
      current.keyFifths = keyFifths;
      current.clef = clef;
      current.denominator = denominator;
      cursor = BeatFraction.zero;
    }

    /// Close the bar at a barline-like token, recording both ends' positions.
    void closeAt(SymbolPlace? right) {
      if (current.events.isNotEmpty && (boundary != null || right != null)) current.bounds = _bounds(boundary, right);
      boundary = right;
      closeMeasure();
    }

    for (final group in groupOmrChords(symbols)) {
      final rhythm = group.first.rhythm;
      if (group.any((s) => s.position == 'lower')) {
        throw const FormatException('上下二段の記号を含む五線はまだ組み立てられません。');
      }
      if (rhythm == 'placeholderStart' || rhythm == 'placeholderEnd') {
        placeholder = rhythm == 'placeholderStart';
      } else if (rhythm.startsWith('pageBoundary/')) {
        closeMeasure();
        boundary = null;
        pageNumber = int.parse(rhythm.substring('pageBoundary/'.length));
        current.page = pageNumber;
      } else if (rhythm.startsWith('systemBoundary/')) {
        closeMeasure();
        boundary = null;
        systemNumber = int.parse(rhythm.substring('systemBoundary/'.length));
        current.system = systemNumber;
      } else if (group.length == 1 && RegExp(r'^rest_\d+m$').hasMatch(rhythm)) {
        // Multi-bar rest ("10" over a thick bar): one whole-bar rest per bar.
        // The bar length is known only after the meter is inferred below.
        closeMeasure();
        final bars = int.parse(rhythm.substring(5, rhythm.length - 1)).clamp(1, 500);
        for (var i = 0; i < bars; i++) {
          current.events.add(<String, dynamic>{
            'onset': '0/1', 'duration': '4/1', 'pitches': <int>[], 'voice': 0, 'tie_start': false,
            'tie_stop': false, 'grace': false, 'slur_starts': <String>[], 'slur_stops': <String>[],
            'multi_bar_rest': true,
          });
          cursor = BeatFraction.zero;
          closeMeasure();
        }
      } else if (rhythm.startsWith('note_') || rhythm.startsWith('rest_')) {
        final timedGroup = group.where((s) => s.isTimed).toList();
        final graceMembers = timedGroup.where((s) => s.isGrace).toList();
        final normalMembers = timedGroup.where((s) => !s.isGrace).toList();
        // homr writes the grace part of a mixed chord first and, because a
        // grace has zero length, does not advance its cursor after the chord.
        final mixed = graceMembers.isNotEmpty && normalMembers.isNotEmpty;
        for (final members in [graceMembers, normalMembers]) {
        if (members.isEmpty) continue;
        final isGrace = members.first.isGrace;
        final group = members;
        BeatFraction nominal(OmrSymbol s) {
          if (!s.isGrace) return s.duration;
          return OmrSymbol(
                  rhythm: s.rhythm.replaceFirst('G', ''),
                  pitch: s.pitch,
                  lift: s.lift,
                  position: s.position,
                  articulation: s.articulation,
                  slur: s.slur)
              .duration;
        }

        final durations = group.map(nominal).toSet().toList()..sort();
        if (durations.first == BeatFraction.zero) {
          throw const FormatException('音価が不正です。');
        }
        for (final duration in durations) {
          final timed = group.where((s) => nominal(s) == duration).toList();
          final sounding = timed.where((s) => s.midiPitch != null).toList();
          // A spacer only sets the cursor advance of its chord (grand-staff
          // timing: a long note under which the next notes start).
          final rests = timed.where((s) => s.midiPitch == null && s.articulation != spacerArticulation).toList();
          if (sounding.isNotEmpty && rests.isNotEmpty) {
            warnings.add('同時に認識された音符と休符を別声部で保持しました。原譜を確認してください。');
          }
          for (final layer in [sounding, rests].where((items) => items.isNotEmpty)) {
            final pitches = layer.map((s) => s.midiPitch).toList();
            final slurs = layer
                .map((s) => s.slur)
                .where((s) => s != '_' && s != '.')
                .toSet();
            if (slurs.length > 1) {
              throw const FormatException('和音内の異なるスラーはまだ組み立てられません。');
            }
            final slur = slurs.isEmpty ? '' : slurs.single;
            final stops = <String>[];
            final starts = <String>[];
            if (slur.contains('slurStop')) {
              if (activeSlur == null) {
                // Usually a tie or slur from the previous system.
                if (keepOpenSlurs) { stops.add(openSlurStop); } else { warnings.add('開始位置が不明なスラーを除外しました。'); }
              } else {
                stops.add(activeSlur);
              }
              activeSlur = null;
              activeSlurStart = null;
            }
            if (slur.contains('slurStart')) {
              if (activeSlur != null) {
                // homr emits a fixed slur number per staff. Repeated starts do
                // not replace the opening endpoint in the PC MusicXML importer.
                warnings.add('スラーの開始が重複したため、追加の開始記号を無視しました。');
              } else {
                activeSlur = '$staffId-slur-${++slurCounter}';
                starts.add(activeSlur);
              }
            }
            final event = <String, dynamic>{
              if (placeholder) 'inferred_rest': true,
              'onset': cursor.toString(),
              'duration': duration.toString(),
              'pitches': pitches.whereType<int>().toSet().toList()..sort(),
              'voice': 0,
              'tie_start': false,
              'tie_stop': false,
              'grace': isGrace,
              'slur_starts': starts,
              'slur_stops': stops,
            };
            final placed = layer.where((s) => s.place != null).toList();
            if (placed.isNotEmpty) {
              final lead = placed.firstWhere((s) => s.place!.snapped, orElse: () => placed.first).place!;
              event['place'] = layer == sounding
                  ? {'x': lead.x, 'heads': [for (final s in placed) {'pitch': s.midiPitch, ...s.place!.toJson()}]}
                  : lead.toJson();
            }
            current.events.add(event);
            if (starts.isNotEmpty) activeSlurStart = event;
          }
        }
        if (!isGrace && !mixed) cursor = cursor + durations.first;
        }
      } else if (rhythm == 'barline' ||
          rhythm == 'doublebarline' ||
          rhythm == 'bolddoublebarline') {
        closeAt(group.first.place);
      } else if (rhythm == 'repeatStart') {
        closeAt(group.first.place);
        current.repeatStart = true;
      } else if (rhythm == 'repeatEnd' || rhythm == 'repeatEndStart') {
        if (current.events.isEmpty) throw const FormatException('反復終点の小節が空です。');
        current.repeatEnd = 2;
        closeAt(group.first.place);
        if (rhythm == 'repeatEndStart') current.repeatStart = true;
      } else if (rhythm.startsWith('keySignature_')) {
        if (current.events.isNotEmpty) {
          throw const FormatException('小節途中の調号変更はまだ組み立てられません。');
        }
        keyFifths = int.parse(rhythm.substring('keySignature_'.length));
        if (keyFifths < -7 || keyFifths > 7) {
          throw const FormatException('調号が不正です。');
        }
        current.keyFifths = keyFifths;
      } else if (rhythm.startsWith('clef_')) {
        if (boundary == null && group.first.place?.lines != null) boundary = group.first.place;
        clef = rhythm.substring('clef_'.length, 'clef_'.length + 1);
        // The score model stores the clef effective at the start of a bar;
        // a change inside it is carried forward to the next bar.
        if (current.events.isEmpty) current.clef = clef;
      } else if (rhythm.startsWith('timeSignature/')) {
        if (current.events.isNotEmpty) {
          throw const FormatException('小節途中の拍子変更はまだ組み立てられません。');
        }
        denominator = int.tryParse(rhythm.substring('timeSignature/'.length));
        if (denominator == null || denominator <= 0) {
          throw const FormatException('拍子が不正です。');
        }
        current.denominator = denominator;
      } else if (rhythm == 'PAD' || rhythm == 'BOS' || rhythm == 'EOS') {
        throw const FormatException('制御トークンが楽譜の途中にあります。');
      } else {
        throw FormatException('未対応の記号を含みます: $rhythm');
      }
    }
    if (current.events.isNotEmpty && boundary != null) current.bounds = _bounds(boundary, null);
    closeMeasure();
    if (activeSlur != null) {
      // Usually continues into the next system.
      final starts = activeSlurStart!['slur_starts'] as List<String>;
      if (keepOpenSlurs) {
        starts[starts.indexOf(activeSlur)] = openSlurStart;
      } else {
        starts.remove(activeSlur);
        warnings.add('終点を特定できないスラーを除外しました。');
      }
    }
    if (measures.isEmpty) throw const FormatException('音符・休符を含む小節がありません。');
    final lengths = measures
        .map((m) => m.length!)
        .where((length) => length.compareTo(BeatFraction.zero) > 0)
        .toList()
      ..sort();
    // Only multi-bar rests: no bar length evidence; assume 4/4 bars.
    if (lengths.isEmpty) lengths.add(BeatFraction(4, 1));
    var median = lengths[lengths.length ~/ 2];
    if (lengths.length.isEven) {
      median = (median + lengths[lengths.length ~/ 2 - 1]) * BeatFraction(1, 2);
    }
    final out = <Map<String, dynamic>>[];
    int? activeDenominator;
    for (final m in measures) {
      activeDenominator = m.denominator ?? activeDenominator;
      final den = activeDenominator ?? 4;
      final numerator = activeDenominator != null
          ? ((median.numerator * den) ~/ (median.denominator * 4)).clamp(1, 999)
          : 4;
      out.add({
        'number': m.number,
        'page': m.page,
        'system': m.system,
        'events': m.events,
        'time_sig': [numerator, den],
        'key_fifths': m.keyFifths,
        'clef': m.clef,
        'warnings': <String>[],
        'repeat_start': m.repeatStart,
        'repeat_end': m.repeatEnd,
        'ending_numbers': <int>[],
        if (m.bounds != null) 'bounds': m.bounds,
      });
    }
    for (final m in out) {
      final events = m['events'] as List;
      if (events.length == 1 && (events.first as Map).remove('multi_bar_rest') == true) {
        final time = m['time_sig'] as List<int>;
        (events.first as Map)['duration'] = BeatFraction(time[0] * 4, time[1]).toString();
      }
    }
    _rebalanceVoices(out);
    if (detectTies) _recognizeSimpleTies(out);
    return {
      'id': staffId,
      'name': '',
      'role': 'unknown',
      'clef': measures.first.clef,
      'measures': out,
      'warnings': warnings
    };
  }
}

// Match homr's interval allocation: lowest free voice, ordered by onset/end.
void _rebalanceVoices(List<Map<String, dynamic>> measures) {
  for (final measure in measures) {
    final original =
        (measure['events'] as List).cast<Map<String, dynamic>>().toList();
    // homr orders by (start, end) with a stable sort; a grace note has no
    // MusicXML duration, so it sorts before notes starting at the same time.
    BeatFraction length(Map<String, dynamic> e) =>
        e['grace'] == true ? BeatFraction.zero : _parseFraction(e['duration']);
    final indexed = original.indexed.toList()
      ..sort((a, b) {
        var c = _parseFraction(a.$2['onset']).compareTo(_parseFraction(b.$2['onset']));
        if (c != 0) return c;
        c = length(a.$2).compareTo(length(b.$2));
        return c != 0 ? c : a.$1.compareTo(b.$1);
      });
    final events = [for (final item in indexed) item.$2];
    final active = <int, BeatFraction>{};
    for (final event in events) {
      final start = _parseFraction(event['onset']);
      active.removeWhere((_, end) => end.compareTo(start) <= 0);
      var voice = 0;
      while (active.containsKey(voice)) {
        voice++;
      }
      event['voice'] = voice;
      if (event['grace'] != true) {
        active[voice] = start + _parseFraction(event['duration']);
      }
    }
  }
}

/// A slur between two adjacent notes or chords that share a pitch is a tie.
/// The PC rule accepted single notes only, which left piano chords (and
/// choir divisi) without ties: 20 of 127 piano ties on the six evaluation
/// pieces. Playback joins only the shared pitches.
bool _tiedPitches(List a, List b) => a.isNotEmpty && b.isNotEmpty && a.any(b.contains);

void _recognizeSimpleTies(List<Map<String, dynamic>> measures) {
  final starts = <String, (Map<String, dynamic>, int, int, BeatFraction)>{};
  final sequences = <int, int>{};
  BeatFraction base = BeatFraction.zero;
  for (final measure in measures) {
    final events = (measure['events'] as List<Map<String, dynamic>>).indexed.toList()
      ..sort((a, b) {
        final onset = _parseFraction(a.$2['onset']).compareTo(_parseFraction(b.$2['onset']));
        if (onset != 0) return onset;
        final voice = (a.$2['voice'] as int).compareTo(b.$2['voice'] as int);
        return voice != 0 ? voice : a.$1.compareTo(b.$1);
      });
    for (final item in events) {
      final event = item.$2;
      final onset = _parseFraction(event['onset'] as String);
      final duration = _parseFraction(event['duration'] as String);
      final voice = event['voice'] as int;
      final index = sequences[voice] ?? 0;
      for (final id in List<String>.from(event['slur_stops'] as List)) {
        final start = starts[id];
        if (start == null) continue;
        final previous = start.$1;
        if (start.$2 == voice && start.$3 == index - 1 && start.$4 == base + onset &&
            previous['grace'] == false && event['grace'] == false &&
            _tiedPitches(previous['pitches'] as List, event['pitches'] as List)) {
          previous['tie_start'] = true;
          event['tie_stop'] = true;
          (previous['slur_starts'] as List).remove(id);
          (event['slur_stops'] as List).remove(id);
        }
      }
      for (final id in event['slur_starts'] as List<String>) {
        starts[id] = (event, voice, index, base + onset + duration);
      }
      sequences[voice] = index + 1;
    }
    // The bar's written length. A system without a time signature is read
    // as 4/4 here, so a 2/4 bar would leave a gap and lose every tie across
    // its barline; the notes themselves say where the bar ends.
    var length = BeatFraction.zero;
    for (final e in measure['events'] as List<Map<String, dynamic>>) {
      if (e['grace'] == true) continue;
      final end = _parseFraction(e['onset'] as String) + _parseFraction(e['duration'] as String);
      if (end.compareTo(length) > 0) length = end;
    }
    if (length == BeatFraction.zero) {
      final time = measure['time_sig'] as List<int>;
      length = BeatFraction(time[0] * 4, time[1]);
    }
    base = base + length;
  }
}

BeatFraction _parseFraction(String value) {
  final pieces = value.split('/');
  return BeatFraction(int.parse(pieces[0]), int.parse(pieces[1]));
}

class _Measure {
  _Measure(this.number);
  final int number;
  int page = 1;
  int system = 0;
  final events = <Map<String, dynamic>>[];
  BeatFraction? length;
  int keyFifths = 0;
  int? denominator;
  String clef = '';
  bool repeatStart = false;
  int repeatEnd = 0;
  Map<String, dynamic>? bounds;
}

/// Page position of a bar: its left and right ends with the staff lines there.
Map<String, dynamic> _bounds(SymbolPlace? left, SymbolPlace? right) => {
  if (left != null) ...{'x0': left.x, 'lines0': left.lines, 'confidence0': left.confidence, 'snapped0': left.snapped},
  if (right != null) ...{'x1': right.x, 'lines1': right.lines, 'confidence1': right.confidence, 'snapped1': right.snapped},
};
