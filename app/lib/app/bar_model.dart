import 'dart:math' as math;
import 'dart:ui' show Offset, Rect, Size;
import '../score.dart';
import '../staff_math.dart';

/// One staff of one bar as the editor sees it.
class BarStaff {
  BarStaff({required this.staff, required this.lines, required this.bottomStep, required this.fifths, required this.offset});
  final int staff;
  /// Staff lines on the page; null when the recognition left no position.
  final StaffLines? lines;
  final int bottomStep, fifths;
  /// Written minus sounding pitch.
  final int offset;
  int written(int sounding) => sounding + offset;
  int sounding(int written) => written - offset;
}

/// A note head as drawn over the original page (1920-wide page pixels).
class DrawnHead {
  const DrawnHead({required this.pitch, required this.x, required this.y, required this.written,
    required this.suspect, required this.edited});
  /// Index into the event's `pitches`.
  final int pitch;
  final double x, y;
  final int written;
  /// Not found on the image at the recognized height: likely a wrong pitch.
  final bool suspect;
  /// Moved or added by the singer (or placed by estimation).
  final bool edited;
}

/// Positions of one bar of every staff, for the overlay and the editor.
class BarView {
  BarView._(this.score, this.measure, this.staves, this.page, this.crop, this.pageWidth, this.pageHeight);
  final ScoreDocument score;
  final int measure;
  final List<BarStaff> staves;
  final int page;
  /// Area of the page to show (page pixels); null without layout.
  final Rect? crop;
  final double pageWidth, pageHeight;

  bool get placed => staves.any((s) => s.lines != null);

  factory BarView.of(ScoreDocument score, Map? layout, int m) {
    final staves = <BarStaff>[];
    int? page;
    int? system;
    double? x0, x1, top, bottom;
    for (var s = 0; s < score.staves.length; s++) {
      if (m >= score.measures(s).length) continue;
      final bar = score.measure(s, m);
      page ??= bar['page'] as int?;
      system ??= bar['system'] as int?;
      final staff = score.staves[s] as Map;
      final lines = StaffLines.of(bar['bounds']);
      final clef = '${bar['clef'] ?? ''}'.isNotEmpty ? '${bar['clef']}' : '${staff['clef'] ?? ''}'.isNotEmpty ? '${staff['clef']}'
        : RegExp('bass|バス|lh', caseSensitive: false).hasMatch('${staff['voice_type']} ${staff['name']} ${staff['role']}') ? 'F' : 'G';
      staves.add(BarStaff(staff: s, lines: lines, bottomStep: clefBottom(clef.substring(0, 1)),
        fifths: (bar['key_fifths'] as num?)?.toInt() ?? 0, offset: score.writtenOffset(s, m)));
      final bounds = bar['bounds'];
      if (lines != null && bounds is Map) {
        if (bounds['x0'] is num) x0 = x0 == null ? lines.x0 : (lines.x0 < x0 ? lines.x0 : x0);
        if (bounds['x1'] is num) x1 = x1 == null ? lines.x1 : (lines.x1 > x1 ? lines.x1 : x1);
        final t = lines.top(lines.x0), b = lines.bottom(lines.x0);
        top = top == null || t < top ? t : top;
        bottom = bottom == null || b > bottom ? b : bottom;
      }
    }
    page ??= 1;
    var width = 1920.0, height = 1920 * 1.414;
    Rect? systemRect;
    for (final p in (layout?['pages'] as List? ?? const [])) {
      if (p is! Map || p['page'] != page) continue;
      width = (p['width'] as num?)?.toDouble() ?? width;
      height = (p['height'] as num?)?.toDouble() ?? height;
      final systems = (p['systems'] as List? ?? const []).whereType<Map>().toList();
      final number = m + 1;
      final region = systems.where((r) => r['index'] == system ||
        (r['first_measure'] is num && number >= (r['first_measure'] as num) && number <= (r['last_measure'] as num))).firstOrNull;
      if (region != null) {
        systemRect = Rect.fromLTRB((region['x0'] as num).toDouble(), (region['y0'] as num).toDouble(),
          (region['x1'] as num).toDouble(), (region['y1'] as num).toDouble());
        // Without barline positions, divide the system evenly like the practice view.
        if (x0 == null || x1 == null) {
          final bars = [for (var i = 0; i < score.measures(0).length; i++)
            if ((score.measure(0, i)['page'] ?? 1) == page && score.measure(0, i)['system'] == score.measure(0, m)['system']) i];
          final k = bars.indexOf(m);
          if (k >= 0) {
            final w = systemRect.width / bars.length;
            x0 ??= systemRect.left + k * w;
            x1 ??= systemRect.left + (k + 1) * w;
          }
        }
      }
    }
    Rect? crop;
    if (x0 != null && x1 != null && (systemRect != null || top != null)) {
      final w = x1 - x0;
      // A little of the neighbors for context; the bar itself as large as possible.
      final pad = w * 0.08 + 16;
      final yTop = systemRect?.top ?? top! - 60, yBottom = systemRect?.bottom ?? bottom! + 60;
      crop = Rect.fromLTRB((x0 - pad).clamp(0, width), (yTop - 28).clamp(0, height),
        (x1 + pad).clamp(0, width), (yBottom + 28).clamp(0, height));
    }
    return BarView._(score, m, staves, page, crop, width, height);
  }

  BarStaff staffOf(int s) => staves.firstWhere((b) => b.staff == s);

  static double? eventX(Map event) {
    final place = event['place'];
    return place is Map && place['x'] is num ? (place['x'] as num).toDouble() : null;
  }

  final _moved = <int, Map<int, double>>{};

  /// x of event [e] of staff [s] as drawn: the recognized x, or an estimate
  /// when the recognition put it out of order (see [_outOfOrder]).
  double? xOf(int s, int e) => (_moved[s] ??= _outOfOrder(s))[e] ?? eventX(score.event(s, measure, e));

  /// Events whose recognized x breaks the order of the beats: a head snapped
  /// to its neighbour (two notes on one head) or to an earlier note. Older
  /// recognitions (layout version < 4) have these. The longest run of
  /// left-to-right positions is kept; the others are placed by their beat
  /// between the kept neighbours. Returns event index -> estimated x.
  Map<int, double> _outOfOrder(int s) {
    final lines = staffOf(s).lines;
    if (lines == null) return const {};
    final events = score.events(s, measure);
    // Onset -> leftmost recognized x of the events starting then (graces aside).
    final byOnset = <double, double>{};
    final members = <double, List<int>>{};
    for (var e = 0; e < events.length; e++) {
      final event = events[e] as Map;
      final x = eventX(event);
      if (x == null || event['grace'] == true) continue;
      final onset = ScoreDocument.beat(event['onset']);
      byOnset[onset] = math.min(byOnset[onset] ?? x, x);
      (members[onset] ??= []).add(e);
    }
    final onsets = byOnset.keys.toList()..sort();
    if (onsets.length < 2) return const {};
    // Longest chain with x increasing by at least 4 px (1920-px page frame).
    final n = onsets.length;
    final best = List.filled(n, 1), back = List.filled(n, -1);
    for (var i = 0; i < n; i++) {
      for (var j = 0; j < i; j++) {
        if (byOnset[onsets[i]]! - byOnset[onsets[j]]! >= 4 && best[j] + 1 > best[i]) { best[i] = best[j] + 1; back[i] = j; }
      }
    }
    var end = 0;
    for (var i = 1; i < n; i++) { if (best[i] > best[end]) end = i; }
    if (best[end] == n) return const {};
    final kept = <int>{};
    for (var i = end; i >= 0; i = back[i]) { kept.add(i); }
    final length = score.barLength(s, measure);
    final barBeats = length.numerator / length.denominator;
    final moved = <int, double>{};
    for (var i = 0; i < n; i++) {
      if (kept.contains(i)) continue;
      // Kept neighbours, or the bar's ends.
      var a = (0.0, lines.x0), b = (barBeats, lines.x1);
      for (var j = i - 1; j >= 0; j--) { if (kept.contains(j)) { a = (onsets[j], byOnset[onsets[j]]!); break; } }
      for (var j = i + 1; j < n; j++) { if (kept.contains(j)) { b = (onsets[j], byOnset[onsets[j]]!); break; } }
      final t = b.$1 == a.$1 ? 0.5 : ((onsets[i] - a.$1) / (b.$1 - a.$1)).clamp(0.0, 1.0);
      final x = a.$2 + (b.$2 - a.$2) * t;
      for (final e in members[onsets[i]]!) { moved[e] = x; }
    }
    return moved;
  }

  /// Heads of event [e] of staff [s] as drawn over the page.
  List<DrawnHead> heads(int s, int e) {
    final staff = staffOf(s);
    final lines = staff.lines;
    if (lines == null) return const [];
    final event = score.event(s, measure, e);
    final pitches = event['pitches'] as List;
    if (pitches.isEmpty) return const [];
    // Out of order (see _outOfOrder): every head moves with the event.
    final movedX = (_moved[s] ??= _outOfOrder(s))[e];
    final recognized = movedX == null ? ScoreDocument.headsInPitchOrder(event) : null;
    if (recognized != null) {
      return [for (var p = 0; p < recognized.length; p++) () {
        final h = recognized[p];
        final x = (h['x'] as num?)?.toDouble() ?? eventX(event) ?? lines.x0;
        final y0 = (h['y'] as num).toDouble();
        final written = h['pitch'] as int;
        final was = lines.stepAt(y0, x, staff.bottomStep), now = stepOf(written, staff.fifths);
        return DrawnHead(pitch: p, x: x, y: y0 - (now - was) * lines.half(x), written: written,
          suspect: h['snapped'] != true && h['manual'] != true && now == was, edited: h['manual'] == true || now != was);
      }()];
    }
    final x = movedX ?? eventX(event);
    if (x == null) return const [];
    return [for (var p = 0; p < pitches.length; p++) () {
      final written = staff.written(pitches[p] as int);
      return DrawnHead(pitch: p, x: x, y: lines.yOf(stepOf(written, staff.fifths), x, staff.bottomStep),
        written: written, suspect: false, edited: true);
    }()];
  }

  /// Number of heads in this bar that were not found on the image.
  int get suspects {
    var n = 0;
    for (final st in staves) {
      for (var e = 0; e < score.events(st.staff, measure).length; e++) { n += heads(st.staff, e).where((h) => h.suspect).length; }
    }
    return n;
  }

  /// Event indexes of a staff in reading order.
  List<int> order(int s) {
    final list = score.events(s, measure);
    final idx = [for (var i = 0; i < list.length; i++) i];
    idx.sort((a, b) {
      final c = ScoreDocument.beat(list[a]['onset']).compareTo(ScoreDocument.beat(list[b]['onset']));
      return c != 0 ? c : ((list[a]['voice'] as num?) ?? 0).compareTo((list[b]['voice'] as num?) ?? 0);
    });
    return idx;
  }

  /// A sensible pitch for a rest turned into a note: the last note sung
  /// before it in the staff, or the middle line.
  int defaultPitch(int s, int e) {
    for (var m = measure; m >= 0; m--) {
      final list = score.events(s, m);
      final onset = m == measure ? ScoreDocument.beat(list[e]['onset']) : double.infinity;
      Map? best;
      for (final ev in list) {
        if ((ev['pitches'] as List).isEmpty || ScoreDocument.beat(ev['onset']) >= onset) continue;
        if (best == null || ScoreDocument.beat(ev['onset']) > ScoreDocument.beat(best['onset'])) best = ev as Map;
      }
      if (best != null) return (best['pitches'] as List).first as int;
    }
    final st = staffOf(s);
    return st.sounding(pitchAtStep(st.bottomStep + 4, st.fifths));
  }
}

/// Japanese name of a note or rest value in quarter beats.
String durationName(double beats, {bool rest = false}) {
  const names = [(4.0, '全'), (2.0, '2分'), (1.0, '4分'), (0.5, '8分'), (0.25, '16分'), (0.125, '32分')];
  for (final (value, name) in names) {
    for (final (dots, factor) in [(0, 1.0), (1, 1.5), (2, 1.75)]) {
      if ((beats - value * factor).abs() < 1e-6) {
        return '${dots == 0 ? '' : dots == 1 ? '付点' : '複付点'}$name${rest ? '休符' : '音符'}';
      }
    }
  }
  return '${_beats(beats)}拍の${rest ? '休符' : '音符'}';
}

String _beats(double v) => v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');

/// "2拍目", "2拍目の裏" … for an onset in quarter beats.
String beatName(double onset) {
  final whole = onset.floor();
  final rest = onset - whole;
  if (rest.abs() < 1e-6) return '${whole + 1}拍目';
  if ((rest - 0.5).abs() < 1e-6) return '${whole + 1}拍目の裏';
  return '${whole + 1}拍目の途中';
}

/// A recognized note head to draw over the original page, in page fractions
/// (0..1 of the page width and height).
class NoteMark {
  const NoteMark(this.center, this.size, this.ledgers, this.accidental,
    {this.suspect = false, this.measure = 0, this.start = 0, this.end = 0, this.rest = false});
  final Offset center;
  final Size size;
  /// Heights of ledger lines the head needs (page fractions), drawn as wide as [size].
  final List<double> ledgers;
  /// '♯', '♭' or '♮' when the recognized pitch needs one in the key.
  final String accidental;
  /// Not found on the page at this height.
  final bool suspect;
  /// Bar index and when the note sounds, as fractions of the bar (0..1).
  final int measure;
  final double start, end;
  /// A rest: drawn only while it is the current one.
  final bool rest;
  bool soundsAt(int bar, double fraction) => bar == measure && fraction >= start - 1e-9 && fraction < end - 1e-9;
}

/// Every recognized head of the score that has a position, by page.
///
/// Heights come from the staff lines measured at both ends of each bar, so a
/// slightly tilted page is followed bar by bar.
Map<int, List<NoteMark>> noteMarks(ScoreDocument score, Map? layout) {
  final result = <int, List<NoteMark>>{};
  final count = score.staves.isEmpty ? 0 : score.measures(0).length;
  for (var m = 0; m < count; m++) {
    final view = BarView.of(score, layout, m);
    if (!view.placed) continue;
    final marks = result.putIfAbsent(view.page, () => []);
    final w = view.pageWidth, h = view.pageHeight;
    for (final st in view.staves) {
      final lines = st.lines;
      if (lines == null || m >= score.measures(st.staff).length) continue;
      // Accidentals as engraved: shown where the alteration of a line or
      // space changes within the bar.
      final inEffect = <int, int>{};
      final barLength = score.barLength(st.staff, m);
      final length = barLength.numerator / barLength.denominator;
      for (final e in view.order(st.staff)) {
        final event = score.event(st.staff, m, e);
        final start = ScoreDocument.beat(event['onset']) / length;
        final end = event['grace'] == true ? start : start + ScoreDocument.beat(event['duration']) / length;
        if ((event['pitches'] as List).isEmpty) {
          final x = view.xOf(st.staff, e);
          if (x != null && event['inferred_rest'] != true) {
            final half = lines.half(x);
            marks.add(NoteMark(Offset(x / w, lines.line(2, x) / h), Size(3.2 * half / w, 1.5 * half / h), const [], '',
              measure: m, start: start, end: end, rest: true));
          }
          continue;
        }
        for (final head in view.heads(st.staff, e)) {
          final half = lines.half(head.x);
          final step = stepOf(head.written, st.fifths);
          final alter = spell(head.written, st.fifths).alter;
          final before = inEffect[step] ?? keyAlteration(step % 7, st.fifths);
          inEffect[step] = alter;
          final sign = alter == before ? '' : switch (alter) { 1 => '♯', -1 => '♭', 2 => '𝄪', -2 => '𝄫', _ => '♮' };
          final ledgers = <double>[
            for (var s = st.bottomStep - 2; s >= step; s -= 2) lines.yOf(s, head.x, st.bottomStep) / h,
            for (var s = st.bottomStep + 10; s <= step; s += 2) lines.yOf(s, head.x, st.bottomStep) / h,
          ];
          marks.add(NoteMark(Offset(head.x / w, head.y / h), Size(3.0 * half / w, 2.4 * half / h), ledgers, sign,
            suspect: head.suspect, measure: m, start: start, end: end));
        }
      }
    }
  }
  return result;
}
