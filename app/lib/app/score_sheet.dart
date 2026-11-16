import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../score.dart';
import 'bar_model.dart';
import 'practice_session.dart';
import 'theme.dart';

/// Normalized bar rectangle on a page (0..1 in both axes).
class BarBox {
  const BarBox(this.measure, this.rect, this.system, [this.anchors = const []]);
  final int measure;
  final Rect rect;
  /// The whole system (staff group) the bar belongs to.
  final Rect system;
  /// (fraction of the bar, normalized x) at recognized note positions, in
  /// order; empty when the bar has no positions.
  final List<Offset> anchors;

  /// x (0..1 of the page) of the playhead at [fraction] through the bar.
  double xAt(double fraction) {
    final f = fraction.clamp(0.0, 1.0);
    if (anchors.length < 2) return rect.left + rect.width * f;
    for (var i = 1; i < anchors.length; i++) {
      final a = anchors[i - 1], b = anchors[i];
      if (f <= b.dx || i == anchors.length - 1) {
        final t = b.dx == a.dx ? 0.0 : ((f - a.dx) / (b.dx - a.dx)).clamp(0.0, 1.0);
        return a.dy + (b.dy - a.dy) * t;
      }
    }
    return rect.right;
  }
}

/// Bar boxes per page from the recognition layout. Bars with recognized
/// barlines ([staves]' `bounds`) use them; the others divide their system
/// evenly, as in the browser version.
Map<int, List<BarBox>> barBoxes(Map? layout, List<Map> measures, {List<List>? staves}) {
  final result = <int, List<BarBox>>{};
  for (final page in (layout?['pages'] as List? ?? const [])) {
    if (page is! Map) continue;
    final number = page['page'] as int? ?? 1;
    final width = (page['width'] as num?)?.toDouble() ?? 1, height = (page['height'] as num?)?.toDouble() ?? 1;
    final boxes = <BarBox>[];
    for (final region in (page['systems'] as List? ?? const []).cast<Map>()) {
      final bars = [for (var i = 0; i < measures.length; i++)
        if ((measures[i]['page'] ?? 1) == number &&
          (measures[i]['system'] == region['index'] ||
            (region['first_measure'] is num && i + 1 >= region['first_measure'] && i + 1 <= region['last_measure']))) i];
      if (bars.isEmpty) continue;
      final x0 = (region['x0'] as num) / width, x1 = (region['x1'] as num) / width;
      final y0 = (region['y0'] as num) / height, y1 = (region['y1'] as num) / height;
      final system = Rect.fromLTRB(x0, y0, x1, y1);
      final w = (x1 - x0) / bars.length;
      for (var k = 0; k < bars.length; k++) {
        var left = x0 + k * w, right = x0 + (k + 1) * w;
        final points = <double, List<double>>{};
        double? b0, b1;
        for (final staff in staves ?? const []) {
          if (bars[k] >= staff.length) continue;
          final bar = staff[bars[k]];
          if (bar is! Map) continue;
          final bounds = bar['bounds'];
          if (bounds is Map) {
            if (bounds['x0'] is num && (b0 == null || bounds['snapped0'] == true)) b0 = (bounds['x0'] as num) / width;
            if (bounds['x1'] is num && (b1 == null || bounds['snapped1'] == true)) b1 = (bounds['x1'] as num) / width;
          }
          final time = bar['time_sig'];
          final length = time is List && time.length == 2 && time[0] is num && time[1] is num && time[1] != 0
            ? (time[0] as num) * 4 / (time[1] as num) : 4.0;
          for (final e in (bar['events'] as List? ?? const [])) {
            final place = e is Map ? e['place'] : null;
            if (place is! Map || place['x'] is! num || e['grace'] == true) continue;
            final onset = _beat(e['onset']);
            if (onset == null || length <= 0) continue;
            points.putIfAbsent(onset / length, () => []).add((place['x'] as num) / width);
          }
        }
        if (b0 != null) left = b0;
        if (b1 != null) right = b1;
        if (right <= left) { left = x0 + k * w; right = x0 + (k + 1) * w; }
        // Median x per beat, kept moving forward.
        final anchors = <Offset>[];
        for (final f in points.keys.toList()..sort()) {
          final xs = points[f]!..sort();
          final x = xs[xs.length ~/ 2];
          if (x <= left || x >= right || (anchors.isNotEmpty && x <= anchors.last.dy)) continue;
          anchors.add(Offset(f, x));
        }
        if (anchors.isNotEmpty) {
          if (anchors.first.dx > 0) anchors.insert(0, Offset(0, left));
          anchors.add(Offset(1, right));
        }
        boxes.add(BarBox(bars[k], Rect.fromLTRB(left, y0, right, y1), system, anchors));
      }
    }
    result[number] = boxes;
  }
  return result;
}

double? _beat(Object? v) {
  if (v is num) return v.toDouble();
  final parts = '$v'.split('/');
  final a = double.tryParse(parts[0]), b = parts.length == 2 ? double.tryParse(parts[1]) : 1.0;
  return a == null || b == null || b == 0 ? null : a / b;
}

/// The original score as a continuous, zoomable column of pages.
///
/// The current bar is highlighted with a moving playhead, the view follows
/// playback, and tapping a bar moves playback there.
class ScoreSheet extends StatefulWidget {
  const ScoreSheet({super.key, required this.session, this.onEditBar, this.showNotes = true});
  final PracticeSession session;
  /// Draw the recognized note heads over the original.
  final bool showNotes;
  /// Long press on a bar: open it for editing.
  final ValueChanged<int>? onEditBar;
  @override
  State<ScoreSheet> createState() => _ScoreSheetState();
}

class _ScoreSheetState extends State<ScoreSheet> with SingleTickerProviderStateMixin {
  static const _channel = MethodChannel('jp.choiromr.mobile/pdf');
  static const _gap = 12.0;
  final _transform = TransformationController();
  late final AnimationController _scroll = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
  Animation<Matrix4>? _scrollAnimation;
  final _images = <int, Uint8List>{};
  final _aspects = <int, double>{};
  final _loading = <int>{};
  final _errors = <int, String>{};
  String? _hash;
  Size _viewport = Size.zero;
  int _visiblePage = 1;
  bool _detached = false;
  int _followed = -1;
  Map<int, List<BarBox>> _boxes = const {};
  Map? _boxesLayout;
  int _boxesCount = -1;
  int _boxesRevision = -1;
  Map<int, List<NoteMark>> _marks = const {};
  ScoreDocument? _marksScore;
  Map? _marksLayout;
  int _marksRevision = -1;

  /// Recognized heads by page, rebuilt only when the score changes.
  Map<int, List<NoteMark>> get marks {
    final score = session.score;
    if (score == null) return const {};
    if (!identical(score, _marksScore) || score.revision != _marksRevision || !identical(session.layout, _marksLayout)) {
      _marks = noteMarks(score, session.layout);
      _marksScore = score; _marksRevision = score.revision; _marksLayout = session.layout;
    }
    return _marks;
  }

  PracticeSession get session => widget.session;
  int get _pages => math.max(session.sourcePages, 1);

  @override
  void initState() {
    super.initState();
    _hash = session.sourceHash;
    session.addListener(_sessionChanged);
    _transform.addListener(_transformChanged);
    _scroll.addListener(() { if (_scrollAnimation != null) _transform.value = _scrollAnimation!.value; });
  }

  @override
  void didUpdateWidget(covariant ScoreSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != session) {
      oldWidget.session.removeListener(_sessionChanged);
      session.addListener(_sessionChanged);
    }
  }

  @override
  void dispose() {
    session.removeListener(_sessionChanged);
    _transform.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _resetForScore() {
    _hash = session.sourceHash;
    _images.clear(); _aspects.clear(); _loading.clear(); _errors.clear();
    _transform.value = Matrix4.identity();
    _detached = false; _followed = -1; _visiblePage = 1;
  }

  Map<int, List<BarBox>> get boxes {
    final layout = session.layout;
    final count = session.measureCount;
    final revision = session.score?.revision ?? -1;
    if (!identical(layout, _boxesLayout) || count != _boxesCount || revision != _boxesRevision) {
      _boxes = barBoxes(layout, session.measures, staves: [for (final st in session.score?.staves ?? const []) st['measures'] as List]);
      _boxesLayout = layout; _boxesCount = count; _boxesRevision = revision;
    }
    return _boxes;
  }

  double _aspect(int page) {
    if (_aspects[page] != null) return _aspects[page]!;
    for (final p in (session.layout?['pages'] as List? ?? const [])) {
      if (p is Map && p['page'] == page && p['width'] is num && p['height'] is num) {
        return (p['width'] as num) / (p['height'] as num);
      }
    }
    return 1 / 1.414;
  }

  double _pageHeight(int page) => _viewport.width / _aspect(page);
  double _pageTop(int page) {
    var y = _gap;
    for (var p = 1; p < page; p++) { y += _pageHeight(p) + _gap; }
    return y;
  }
  double get _contentHeight => _pageTop(_pages + 1);

  void _sessionChanged() {
    if (!mounted) return;
    if (session.sourceHash != _hash) { setState(_resetForScore); }
    _follow();
  }

  void _transformChanged() {
    if (_viewport.isEmpty) return;
    final scale = _transform.value.getMaxScaleOnAxis();
    final top = -_transform.value.getTranslation().y / scale;
    final middle = top + _viewport.height / scale / 3;
    var page = 1;
    for (var p = 1; p <= _pages; p++) { if (_pageTop(p) <= middle) page = p; }
    if (page != _visiblePage) setState(() => _visiblePage = page);
    _ensureLoaded();
  }

  void _ensureLoaded() {
    final hash = _hash;
    if (hash == null) return;
    for (var p = _visiblePage - 1; p <= _visiblePage + 1; p++) {
      if (p < 1 || p > _pages || _images.containsKey(p) || _loading.contains(p) || _errors.containsKey(p)) continue;
      _load(hash, p);
    }
    // Keep a small window of decoded pages.
    _images.removeWhere((p, _) => (p - _visiblePage).abs() > 2);
  }

  Future<void> _load(String hash, int page) async {
    _loading.add(page);
    try {
      final image = await _channel.invokeMethod<Uint8List>('renderSourcePage', {'hash': hash, 'page': page - 1});
      if (image == null || image.isEmpty) throw const FormatException('原譜画像がありません。');
      var ratio = _aspect(page);
      if (image.length >= 24 && image[0] == 137 && image[1] == 80) {
        final header = ByteData.sublistView(image);
        final w = header.getUint32(16), h = header.getUint32(20);
        if (w > 0 && h > 0) ratio = w / h;
      }
      if (!mounted || hash != _hash) return;
      setState(() { _images[page] = image; _aspects[page] = ratio; });
    } on PlatformException catch (e) {
      if (mounted && hash == _hash) setState(() => _errors[page] = e.message ?? '原譜を表示できませんでした。');
    } on FormatException catch (e) {
      if (mounted && hash == _hash) setState(() => _errors[page] = e.message);
    } catch (_) {
      if (mounted && hash == _hash) setState(() => _errors[page] = '原譜を表示できませんでした。');
    } finally { _loading.remove(page); }
  }

  /// Scrolls so the system holding the current bar is in view.
  void _follow({bool force = false}) {
    if (_viewport.isEmpty || session.score == null) return;
    final measure = session.currentMeasure;
    if (!force && (!session.follow || _detached || measure == _followed)) return;
    _followed = measure;
    final page = (session.measures.length > measure ? session.measures[measure]['page'] as int? : null) ?? 1;
    final box = boxes[page]?.where((b) => b.measure == measure).firstOrNull;
    final scale = _transform.value.getMaxScaleOnAxis();
    final pageTop = _pageTop(page), pageH = _pageHeight(page);
    final top = box == null ? pageTop : pageTop + box.system.top * pageH;
    final bottom = box == null ? pageTop + math.min(pageH, _viewport.height / scale) : pageTop + box.system.bottom * pageH;
    final visibleTop = -_transform.value.getTranslation().y / scale;
    final visibleBottom = visibleTop + _viewport.height / scale;
    if (!force && top >= visibleTop + 8 && bottom <= visibleBottom - 8) return;
    final maxScroll = math.max(0.0, _contentHeight * scale - _viewport.height);
    final targetY = -(top * scale - _viewport.height * 0.18).clamp(0.0, maxScroll);
    final start = _transform.value.clone();
    final end = start.clone()..setTranslationRaw(start.getTranslation().x, targetY, 0);
    _scrollAnimation = Matrix4Tween(begin: start, end: end).animate(CurvedAnimation(parent: _scroll, curve: Curves.easeInOutCubic));
    if (MediaQuery.of(context).disableAnimations) { _transform.value = end; } else { _scroll.forward(from: 0); }
  }

  BarBox? _hit(int page, Offset local, Size size) {
    final point = Offset(local.dx / size.width, local.dy / size.height);
    final candidates = boxes[page] ?? const [];
    for (final b in candidates) {
      if (point.dy >= b.system.top && point.dy <= b.system.bottom && point.dx >= b.rect.left && point.dx < b.rect.right) return b;
    }
    // Taps just outside a system (lyrics, margins) pick the nearest system's bar.
    if (candidates.isNotEmpty) {
      double distance(BarBox b) => (point.dy - b.system.center.dy).abs() + (point.dx < b.rect.left ? b.rect.left - point.dx : point.dx > b.rect.right ? point.dx - b.rect.right : 0);
      final nearest = candidates.reduce((a, b) => distance(a) <= distance(b) ? a : b);
      if ((point.dy - nearest.system.center.dy).abs() < nearest.system.height) return nearest;
    }
    return null;
  }

  void _onLongPress(int page, Offset local, Size size) {
    final hit = _hit(page, local, size);
    if (hit == null || widget.onEditBar == null) return;
    HapticFeedback.mediumImpact();
    widget.onEditBar!(hit.measure);
  }

  void _onTap(int page, Offset local, Size size) {
    final hit = _hit(page, local, size);
    if (hit == null) {
      if ((boxes[page] ?? const []).isEmpty) session.notice('このページには段の位置情報がありません。下の再生バーで移動してください。');
      return;
    }
    HapticFeedback.selectionClick();
    setState(() { _detached = false; _followed = hit.measure; });
    session.seekToMeasure(hit.measure);
  }

  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);
      if (size != _viewport) {
        _viewport = size;
        WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) { _ensureLoaded(); _follow(force: true); } });
      }
      final current = session.currentMeasure;
      final loopBars = session.loop && session.plan != null
        ? {for (var i = session.loopFrom; i <= session.loopTo && i < session.plan!.order.length; i++) session.plan!.order[i]}
        : const <int>{};
      return Stack(children: [
        Positioned.fill(child: InteractiveViewer(
          transformationController: _transform,
          constrained: false,
          minScale: 1, maxScale: 4,
          boundaryMargin: EdgeInsets.zero,
          onInteractionStart: (_) {
            _scroll.stop();
            if (session.playing && session.follow) setState(() => _detached = true);
          },
          child: SizedBox(width: size.width, height: _contentHeight, child: Column(children: [
            for (var p = 1; p <= _pages; p++) ...[
              const SizedBox(height: _gap),
              SizedBox(width: size.width, height: _pageHeight(p), child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: _Page(
                  image: _images[p], error: _errors[p], cacheWidth: (size.width * MediaQuery.devicePixelRatioOf(context)).round(),
                  boxes: boxes[p] ?? const [], current: current,
                  marks: widget.showNotes ? marks[p] ?? const [] : const [], fraction: session.barFraction,
                  showPlayhead: session.prepared, loopBars: loopBars,
                  onRetry: () => setState(() { _errors.remove(p); _ensureLoaded(); }),
                  onTap: (local, s) => _onTap(p, local, s),
                  onLongPress: (local, s) => _onLongPress(p, local, s)),
              )),
            ],
          ])),
        )),
        Positioned(top: 10, right: 12, child: IgnorePointer(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: c.surfaceRaised.withValues(alpha: 0.92), borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.separator)),
          child: Text('$_visiblePage / $_pages', style: Theme.of(context).textTheme.labelMedium),
        ))),
        if (_detached && session.follow) Positioned(bottom: 12, left: 0, right: 0, child: Center(child: FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size(44, 40), shape: const StadiumBorder()),
          onPressed: () { setState(() => _detached = false); _follow(force: true); },
          icon: const Icon(Icons.my_location_rounded, size: 18), label: const Text('再生位置に戻る')))),
      ]);
    });
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.image, required this.error, required this.cacheWidth, required this.boxes, required this.marks,
    required this.current, required this.fraction, required this.showPlayhead, required this.loopBars,
    required this.onRetry, required this.onTap, required this.onLongPress});
  final Uint8List? image;
  final String? error;
  final int cacheWidth;
  final List<BarBox> boxes;
  final List<NoteMark> marks;
  final int current;
  final double fraction;
  final bool showPlayhead;
  final Set<int> loopBars;
  final VoidCallback onRetry;
  final void Function(Offset local, Size size) onTap;
  final void Function(Offset local, Size size) onLongPress;

  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return LayoutBuilder(builder: (context, box) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) => onTap(d.localPosition, box.biggest),
      onLongPressStart: (d) => onLongPress(d.localPosition, box.biggest),
      child: DecoratedBox(
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(4),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 6, offset: const Offset(0, 1))]),
        child: Stack(fit: StackFit.expand, children: [
          if (image != null) ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.memory(image!,
            fit: BoxFit.fill, gaplessPlayback: true, cacheWidth: cacheWidth,
            errorBuilder: (context, e, s) => const Center(child: Text('原譜画像を開けませんでした。'))))
          else if (error != null) Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF5B6283))),
            TextButton(onPressed: onRetry, child: const Text('再読み込み')),
          ]))
          else const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5))),
          // The original a little lighter, so the drawn notes read against it.
          if (image != null && marks.isNotEmpty) const IgnorePointer(child: ColoredBox(color: Color(0x59FFFFFF))),
          if (image != null && marks.isNotEmpty) IgnorePointer(child: RepaintBoundary(child: CustomPaint(painter: _NotePainter(marks)))),
          IgnorePointer(child: CustomPaint(painter: _BarPainter(boxes: boxes, current: current, fraction: fraction,
            showPlayhead: showPlayhead, loopBars: loopBars, attention: c.attention,
            markFill: c.markFill, markLine: c.markLine, playhead: c.playhead))),
          // Above the bar highlight: what sounds now.
          if (image != null && marks.isNotEmpty) IgnorePointer(child: CustomPaint(
            painter: _ActivePainter(marks: marks, measure: current, fraction: fraction, color: c.playhead))),
        ]),
      ),
    ));
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({required this.boxes, required this.current, required this.fraction, required this.showPlayhead,
    required this.loopBars, required this.attention, required this.markFill, required this.markLine, required this.playhead});
  final List<BarBox> boxes;
  final int current;
  final double fraction;
  final bool showPlayhead;
  final Set<int> loopBars;
  final Color attention, markFill, markLine, playhead;

  @override
  void paint(Canvas canvas, Size size) {
    Rect scaled(Rect r) => Rect.fromLTRB(r.left * size.width, r.top * size.height, r.right * size.width, r.bottom * size.height);
    for (final b in boxes) {
      if (!loopBars.contains(b.measure)) continue;
      final r = scaled(b.rect);
      canvas.drawRect(r, Paint()..color = attention.withValues(alpha: 0.07));
      canvas.drawLine(r.bottomLeft + const Offset(0, 3), r.bottomRight + const Offset(0, 3),
        Paint()..color = attention..strokeWidth = 3);
    }
    for (final b in boxes) {
      if (b.measure != current) continue;
      final r = scaled(b.rect).inflate(1);
      final rounded = RRect.fromRectAndRadius(r, const Radius.circular(4));
      canvas.drawRRect(rounded, Paint()..color = markFill);
      canvas.drawRRect(rounded, Paint()..color = markLine..style = PaintingStyle.stroke..strokeWidth = 1.5);
      if (showPlayhead) {
        final x = b.xAt(fraction) * size.width;
        canvas.drawLine(Offset(x, r.top - 4), Offset(x, r.bottom + 4),
          Paint()..color = playhead..strokeWidth = 2.5..strokeCap = StrokeCap.round);
      }
    }
  }

  @override
  bool shouldRepaint(_BarPainter old) => old.current != current || old.fraction != fraction ||
    old.showPlayhead != showPlayhead || old.markFill != markFill || old.playhead != playhead || !identical(old.boxes, boxes) || old.loopBars.length != loopBars.length ||
    !old.loopBars.containsAll(loopBars);
}

/// Recognized note heads as thin gray rings over the printed ones. A ring
/// beside an empty spot (or a printed head without a ring) shows where the
/// recognition differs from the page.
class _NotePainter extends CustomPainter {
  _NotePainter(this.marks);
  final List<NoteMark> marks;
  static const ink = Color(0xC0485066);

  @override
  void paint(Canvas canvas, Size size) {
    final ring = Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 1.1;
    // Heads not found on the page get a heavier ring to catch the eye.
    final heavy = Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 2.2;
    final ledger = Paint()..color = ink..strokeWidth = 0.9;
    for (final m in marks) {
      if (m.rest) continue;
      final c = Offset(m.center.dx * size.width, m.center.dy * size.height);
      final w = m.size.width * size.width, h = m.size.height * size.height;
      canvas.drawOval(Rect.fromCenter(center: c, width: w, height: h), m.suspect ? heavy : ring);
      for (final y in m.ledgers) {
        canvas.drawLine(Offset(c.dx - w * 0.8, y * size.height), Offset(c.dx + w * 0.8, y * size.height), ledger);
      }
      if (m.accidental.isNotEmpty) {
        final tp = TextPainter(text: TextSpan(text: m.accidental, style: TextStyle(color: ink, fontSize: h * 1.5, height: 1)),
          textDirection: TextDirection.ltr)..layout();
        // Above-left of the head, clear of the printed accidental.
        tp.paint(canvas, Offset(c.dx - w * 0.5 - tp.width, c.dy - h * 0.5 - tp.height * 0.9));
      }
    }
  }

  @override
  bool shouldRepaint(_NotePainter old) => !identical(old.marks, marks);
}

/// The notes and rests sounding now, filled in the playhead color, so a
/// wrong note shows as a filled ring away from the printed head while it plays.
class _ActivePainter extends CustomPainter {
  _ActivePainter({required this.marks, required this.measure, required this.fraction, required this.color});
  final List<NoteMark> marks;
  final int measure;
  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color.withValues(alpha: 0.55);
    final ring = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 2;
    for (final m in marks) {
      if (!m.soundsAt(measure, fraction)) continue;
      final r = Rect.fromCenter(center: Offset(m.center.dx * size.width, m.center.dy * size.height),
        width: m.size.width * size.width, height: m.size.height * size.height);
      if (m.rest) {
        final bar = RRect.fromRectAndRadius(r, Radius.circular(r.height / 2));
        canvas.drawRRect(bar, fill);
        canvas.drawRRect(bar, ring);
      } else {
        canvas.drawOval(r.inflate(1), fill);
        canvas.drawOval(r.inflate(1), ring);
      }
    }
  }

  @override
  bool shouldRepaint(_ActivePainter old) => old.measure != measure || old.fraction != fraction ||
    old.color != color || !identical(old.marks, marks);
}

/// Bar grid for scores without a linked PDF; tap a bar to move there.
class MeasureGrid extends StatelessWidget {
  const MeasureGrid({super.key, required this.session});
  final PracticeSession session;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final count = session.measureCount;
    final current = session.currentMeasure;
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 76, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1.15),
      itemCount: count,
      itemBuilder: (context, i) {
        final selected = i == current;
        return Material(
          color: selected ? c.nowFill : c.surface,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(borderRadius: BorderRadius.circular(10), onTap: () => session.seekToMeasure(i),
            child: Center(child: Text(session.measureLabel(i), style: Theme.of(context).textTheme.titleMedium!.copyWith(
              color: selected ? c.onNow : c.label)))),
        );
      },
    );
  }
}
