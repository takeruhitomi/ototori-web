import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../omr_symbols.dart';
import '../score.dart';
import '../staff_math.dart';
import 'bar_model.dart';
import 'practice_session.dart';
import 'theme.dart';

typedef Selection = ({int staff, int event, int pitch});

/// Fixes one bar at a time, looking at the original.
///
/// Top: the bar cut out of the original page with the recognized notes drawn
/// over it (colored outlines on the noteheads). Below: the selected part as
/// plain notation, then the tools for the selected note. Every change keeps
/// the bar's length, so nothing else in the score moves.
class BarEditorPage extends StatefulWidget {
  const BarEditorPage({super.key, required this.session, required this.measure});
  final PracticeSession session;
  final int measure;
  @override
  State<BarEditorPage> createState() => _BarEditorPageState();
}

class _BarEditorPageState extends State<BarEditorPage> {
  late int measure = widget.measure;
  Selection? selected;
  late int staff = _firstVoice();
  final _pages = <int, ui.Image>{};
  final _pageErrors = <int, String>{};
  final _loading = <int>{};

  PracticeSession get session => widget.session;
  ScoreDocument get score => session.score!;

  int _firstVoice() {
    final s = widget.session.score;
    if (s == null) return 0;
    for (var i = 0; i < s.staves.length; i++) { if (s.staves[i]['role'] == 'voice') return i; }
    return 0;
  }

  @override
  void dispose() {
    for (final image in _pages.values) { image.dispose(); }
    super.dispose();
  }

  Future<void> _load(String hash, int page) async {
    if (_pages.containsKey(page) || _loading.contains(page) || _pageErrors.containsKey(page)) return;
    _loading.add(page);
    try {
      final bytes = await const MethodChannel('jp.choiromr.mobile/pdf').invokeMethod<Uint8List>('renderSourcePage', {'hash': hash, 'page': page - 1});
      if (bytes == null || bytes.isEmpty) throw const FormatException('原譜画像がありません。');
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      if (!mounted) { frame.image.dispose(); return; }
      setState(() => _pages[page] = frame.image);
      // Keep the pages around this one only.
      for (final p in _pages.keys.where((p) => (p - page).abs() > 1).toList()) { _pages.remove(p)!.dispose(); }
    } on PlatformException catch (e) {
      if (mounted) setState(() => _pageErrors[page] = e.message ?? '原譜を表示できませんでした。');
    } catch (_) {
      if (mounted) setState(() => _pageErrors[page] = '原譜を表示できませんでした。');
    } finally { _loading.remove(page); }
  }

  void _go(int to) {
    if (to < 0 || to >= score.measures(0).length) return;
    setState(() { measure = to; selected = null; });
  }

  /// The next bar (after this one) with notes that were not found on the image.
  int? _nextSuspect() {
    final count = score.measures(0).length;
    for (var i = 1; i < count; i++) {
      final m = (measure + i) % count;
      if (BarView.of(score, session.layout, m).suspects > 0) return m;
    }
    return null;
  }

  void _select(int s, int e, [int pitch = 0]) {
    HapticFeedback.selectionClick();
    setState(() { staff = s; selected = (staff: s, event: e, pitch: pitch); });
  }

  /// Runs an edit and keeps the selection on the same note where possible.
  void _edit(void Function(ScoreDocument d) change, {Selection? then}) {
    if (session.edit(change)) setState(() => selected = then ?? selected);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: session, builder: (context, _) {
    final c = OtotoriColors.of(context);
    if (session.score == null) return const Scaffold(body: SizedBox.shrink());
    final count = score.measures(0).length;
    measure = measure.clamp(0, count - 1);
    final view = BarView.of(score, session.layout, measure);
    final sel = selected;
    if (sel != null && (sel.staff >= score.staves.length || sel.event >= score.events(sel.staff, measure).length)) selected = null;
    final hash = session.sourceHash;
    if (hash != null && view.crop != null) _load(hash, view.page);
    final number = score.measure(0, measure)['number'] ?? measure + 1;
    final warnings = <String>{for (var s = 0; s < score.staves.length; s++)
      ...((score.measure(s, measure)['warnings'] as List?) ?? const []).map((w) => '$w')}.toList();
    final suspects = view.suspects;

    final original = hash == null
      ? _Note(icon: Icons.picture_as_pdf_outlined, text: '原譜PDFを関連付けると、原譜に重ねて確かめられます。')
      : view.crop == null
        ? _Note(icon: Icons.crop_free_rounded, text: 'この小節には原譜上の位置がありません。下の楽譜で直してください。')
        : _pageErrors[view.page] != null
          ? _Note(icon: Icons.broken_image_outlined, text: _pageErrors[view.page]!)
          : _Original(view: view, image: _pages[view.page], selected: selected, staffFocus: staff,
              onSelect: _select,
              onDrop: (sel, step) => _dropAt(view, sel, step));

    final nav = _BarNav(number: '$number', index: measure, count: count, suspects: suspects,
      onPrev: measure > 0 ? () => _go(measure - 1) : null,
      onNext: measure + 1 < count ? () => _go(measure + 1) : null,
      onNextSuspect: () {
        final m = _nextSuspect();
        if (m == null) { session.notice('原譜で見つからなかった音は、ほかの小節にはありません。'); } else { _go(m); }
      });

    final tools = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (warnings.isNotEmpty) Container(
        color: c.attentionWash, padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          Icon(Icons.error_outline_rounded, size: 16, color: c.attention), const SizedBox(width: 8),
          Expanded(child: Text(warnings.join(' / '), maxLines: 2, overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium!.copyWith(color: c.attention))),
        ])),
      _PartChips(score: score, selected: staff, onSelect: (s) => setState(() { staff = s; selected = null; })),
      _Strip(view: view, staff: staff, selected: selected?.staff == staff ? selected : null,
        onSelect: (e) => _select(staff, e)),
      Divider(height: 1, color: c.separator),
      _Inspector(view: view, selected: selected, session: session, onSelect: _select, onEdit: _edit),
    ]);

    return Scaffold(
      appBar: AppBar(title: const Text('音を直す'), actions: [
        IconButton(tooltip: '元に戻す', onPressed: score.canUndo ? () => _edit((d) => d.undo()) : null, icon: const Icon(Icons.undo_rounded)),
        IconButton(tooltip: 'やり直す', onPressed: score.canRedo ? () => _edit((d) => d.redo()) : null, icon: const Icon(Icons.redo_rounded)),
        const SizedBox(width: 4),
      ]),
      body: SafeArea(top: false, child: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= 840) {
          return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: Column(children: [nav, Expanded(child: original)])),
            VerticalDivider(width: 1, color: c.separator),
            SizedBox(width: 400, child: SingleChildScrollView(child: tools)),
          ]);
        }
        return Column(children: [
          nav,
          Expanded(child: original),
          Divider(height: 1, color: c.separator),
          ConstrainedBox(constraints: BoxConstraints(maxHeight: box.maxHeight * 0.62), child: SingleChildScrollView(child: tools)),
        ]);
      })),
    );
  });

  /// A note head (or a rest's handle) was dragged to [step] on its staff.
  void _dropAt(BarView view, Selection sel, int step) {
    final st = view.staffOf(sel.staff);
    final lines = st.lines;
    final event = score.event(sel.staff, measure, sel.event);
    final written = pitchAtStep(step, st.fifths);
    final sounding = st.sounding(written);
    if ((event['pitches'] as List).isEmpty) {
      final x = BarView.eventX(event);
      _edit((d) => d.restToNote(sel.staff, measure, sel.event, sounding,
        head: lines == null || x == null ? null : (x: x, y: lines.yOf(step, x, st.bottomStep), written: written)),
        then: (staff: sel.staff, event: sel.event, pitch: 0));
      return;
    }
    final heads = view.heads(sel.staff, sel.event);
    final current = heads.where((h) => h.pitch == sel.pitch).firstOrNull;
    if (current != null && stepOf(current.written, st.fifths) == step) return;
    _edit((d) => d.setPitch(sel.staff, measure, sel.event, sel.pitch, sounding));
  }
}

// ----------------------------------------------------------------- original

class _Original extends StatefulWidget {
  const _Original({required this.view, required this.image, required this.selected, required this.staffFocus,
    required this.onSelect, required this.onDrop});
  final BarView view;
  final ui.Image? image;
  final Selection? selected;
  final int staffFocus;
  final void Function(int staff, int event, int pitch) onSelect;
  final void Function(Selection sel, int step) onDrop;
  @override
  State<_Original> createState() => _OriginalState();
}

class _OriginalState extends State<_Original> {
  /// Page y of the head being dragged, before snapping.
  double? _dragY;
  int? _dragStep;
  final _scroll = ScrollController();

  @override
  void dispose() { _scroll.dispose(); super.dispose(); }

  /// Where the selected event's handle sits (page pixels).
  Offset? _handle() {
    final sel = widget.selected;
    if (sel == null) return null;
    final view = widget.view;
    final st = view.staffOf(sel.staff);
    final lines = st.lines;
    if (lines == null) return null;
    final event = view.score.event(sel.staff, view.measure, sel.event);
    if (event['grace'] == true && (event['pitches'] as List).isEmpty) return null;
    final heads = view.heads(sel.staff, sel.event);
    final head = heads.where((h) => h.pitch == sel.pitch).firstOrNull;
    if (head != null) return Offset(head.x, head.y);
    if ((event['pitches'] as List).isNotEmpty) return null;
    final x = view.xOf(sel.staff, sel.event);
    return x == null ? null : Offset(x, lines.line(2, x));
  }

  void _tap(Offset local, double scale) {
    final view = widget.view;
    final crop = view.crop!;
    final p = Offset(crop.left + local.dx / scale, crop.top + local.dy / scale);
    BarStaff? best;
    var bestDistance = double.infinity;
    for (final st in view.staves) {
      final l = st.lines;
      if (l == null) continue;
      final top = l.top(p.dx) - 4 * l.half(p.dx), bottom = l.bottom(p.dx) + 4 * l.half(p.dx);
      if (p.dy < top || p.dy > bottom) continue;
      final d = (p.dy - (l.top(p.dx) + l.bottom(p.dx)) / 2).abs();
      if (d < bestDistance) { best = st; bestDistance = d; }
    }
    if (best == null) return;
    final l = best.lines!;
    final space = 2 * l.half(p.dx);
    int? event;
    var pitch = 0;
    var near = 3.2 * space;
    final list = view.score.events(best.staff, view.measure);
    for (var e = 0; e < list.length; e++) {
      final heads = view.heads(best.staff, e);
      if (heads.isNotEmpty) {
        for (final h in heads) {
          final d = (h.x - p.dx).abs() + 0.35 * (h.y - p.dy).abs();
          if (d < near) { near = d; event = e; pitch = h.pitch; }
        }
      } else {
        final x = view.xOf(best.staff, e);
        if (x == null) continue;
        final d = (x - p.dx).abs() + 0.35 * (l.line(2, x) - p.dy).abs();
        if (d < near) { near = d; event = e; pitch = 0; }
      }
    }
    if (event != null) widget.onSelect(best.staff, event, pitch);
  }

  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final view = widget.view;
    final crop = view.crop!;
    return LayoutBuilder(builder: (context, box) {
      final scale = box.maxWidth / crop.width;
      final height = crop.height * scale;
      final handle = _handle();
      final sel = widget.selected;
      final st = sel == null ? null : view.staffOf(sel.staff);
      final ghost = _dragStep != null && handle != null && st?.lines != null
        ? (step: _dragStep!, y: st!.lines!.yOf(_dragStep!, handle.dx, st.bottomStep), x: handle.dx) : null;
      final content = SizedBox(width: box.maxWidth, height: height, child: Stack(children: [
        Positioned.fill(child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) => _tap(d.localPosition, scale),
          child: CustomPaint(painter: _OverlayPainter(view: view, image: widget.image, scale: scale, selected: sel,
            colors: _OverlayColors.of(context, view.score), tint: c.tint, attention: c.attention,
            ghost: ghost == null ? null : (x: ghost.x, y: ghost.y,
              label: spelledName(pitchAtStep(ghost.step, st!.fifths), st.fifths)))),
        )),
        if (widget.image == null) const Center(child: SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.5))),
        if (handle != null && sel != null && st?.lines != null) Positioned(
          left: (handle.dx - crop.left) * scale - 24, top: (handle.dy - crop.top) * scale - 24, width: 48, height: 48,
          child: Semantics(label: '音の高さを上下に動かす', child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The head follows the finger from where it touched down.
            dragStartBehavior: DragStartBehavior.down,
            onVerticalDragStart: (_) => setState(() { _dragY = handle.dy; _dragStep = st!.lines!.stepAt(handle.dy, handle.dx, st.bottomStep); }),
            onVerticalDragUpdate: (d) {
              _dragY = _dragY! + d.delta.dy / scale;
              final step = st!.lines!.stepAt(_dragY!, handle.dx, st.bottomStep).clamp(st.bottomStep - 12, st.bottomStep + 20);
              if (step != _dragStep) { HapticFeedback.selectionClick(); setState(() => _dragStep = step); }
            },
            onVerticalDragEnd: (_) { final step = _dragStep; setState(() { _dragY = null; _dragStep = null; }); if (step != null) widget.onDrop(sel, step); },
            onVerticalDragCancel: () => setState(() { _dragY = null; _dragStep = null; }),
          )),
        ),
      ]));
      return ColoredBox(color: Colors.white, child: height <= box.maxHeight
        ? Align(alignment: Alignment.topCenter, child: content)
        : Scrollbar(controller: _scroll, child: SingleChildScrollView(controller: _scroll, child: content)));
    });
  }
}

/// Part colors readable on white paper in both themes.
class _OverlayColors {
  _OverlayColors(this.byStaff);
  final List<Color> byStaff;
  static _OverlayColors of(BuildContext context, ScoreDocument score) {
    final parts = OtotoriColors.of(context).parts;
    return _OverlayColors([for (final s in score.staves) () {
      final role = '${s['role']}';
      final color = role.startsWith('piano') ? parts.piano : parts.forPart('${s['id']}', '${s['name'] ?? ''}');
      final hsl = HSLColor.fromColor(color);
      return hsl.lightness > 0.48 ? hsl.withLightness(0.42).toColor() : color;
    }()]);
  }
}

class _OverlayPainter extends CustomPainter {
  _OverlayPainter({required this.view, required this.image, required this.scale, required this.selected,
    required this.colors, required this.tint, required this.attention, required this.ghost});
  final BarView view;
  final ui.Image? image;
  final double scale;
  final Selection? selected;
  final _OverlayColors colors;
  final Color tint, attention;
  final ({double x, double y, String label})? ghost;

  @override
  void paint(Canvas canvas, Size size) {
    final crop = view.crop!;
    final img = image;
    if (img != null) {
      final k = img.width / view.pageWidth;
      canvas.drawImageRect(img, Rect.fromLTRB(crop.left * k, crop.top * k, crop.right * k, crop.bottom * k),
        Offset.zero & size, Paint()..filterQuality = FilterQuality.medium);
    }
    canvas.save();
    canvas.scale(scale);
    canvas.translate(-crop.left, -crop.top);
    final px = 1 / scale; // one logical pixel in page pixels
    for (final st in view.staves) {
      final l = st.lines;
      if (l == null) continue;
      final color = colors.byStaff[st.staff];
      final bar = view.score.measure(st.staff, view.measure);
      final bounds = bar['bounds'] as Map;
      // Barlines as the recognizer placed them.
      for (final (key, snapKey) in [('x0', 'snapped0'), ('x1', 'snapped1')]) {
        if (bounds[key] is! num) continue;
        final x = (bounds[key] as num).toDouble();
        final sure = bounds[snapKey] == true;
        final paint = Paint()..color = (sure ? tint : attention).withValues(alpha: sure ? 0.45 : 0.8)..strokeWidth = 2 * px;
        final top = l.top(x) - l.half(x), bottom = l.bottom(x) + l.half(x);
        if (sure) {
          canvas.drawLine(Offset(x, top), Offset(x, bottom), paint);
        } else {
          for (var y = top; y < bottom; y += 6 * px) { canvas.drawLine(Offset(x, y), Offset(x, math.min(y + 3 * px, bottom)), paint); }
        }
      }
      final list = view.score.events(st.staff, view.measure);
      for (var e = 0; e < list.length; e++) {
        final event = list[e] as Map;
        final isSelected = selected?.staff == st.staff && selected?.event == e;
        final x = view.xOf(st.staff, e);
        final heads = view.heads(st.staff, e);
        final anchor = heads.isNotEmpty ? heads.first.x : x;
        if (anchor == null) continue;
        final half = l.half(anchor);
        if (isSelected) {
          final r = RRect.fromRectAndRadius(Rect.fromLTRB(anchor - 2.6 * half, l.top(anchor) - 5 * half,
            anchor + 2.6 * half, l.bottom(anchor) + 5 * half), Radius.circular(half));
          canvas.drawRRect(r, Paint()..color = tint.withValues(alpha: 0.10));
          canvas.drawRRect(r, Paint()..color = tint.withValues(alpha: 0.55)..style = PaintingStyle.stroke..strokeWidth = 1.5 * px);
        }
        if (heads.isEmpty) {
          if ((event['pitches'] as List).isNotEmpty) continue;
          // A rest: a small bar on the middle line.
          final r = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(anchor, l.line(2, anchor)), width: 2.2 * half, height: 1.1 * half),
            Radius.circular(half));
          canvas.drawRRect(r, Paint()..color = color.withValues(alpha: isSelected ? 0.5 : 0.22));
          canvas.drawRRect(r, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5 * px);
          continue;
        }
        for (final h in heads) {
          final hh = l.half(h.x);
          final step = stepOf(h.written, st.fifths);
          // Ledger lines for heads above or below the staff.
          final ledger = Paint()..color = color.withValues(alpha: 0.75)..strokeWidth = 1.5 * px;
          for (var s = st.bottomStep - 2; s >= step; s -= 2) {
            final y = l.yOf(s, h.x, st.bottomStep);
            canvas.drawLine(Offset(h.x - 1.8 * hh, y), Offset(h.x + 1.8 * hh, y), ledger);
          }
          for (var s = st.bottomStep + 10; s <= step; s += 2) {
            final y = l.yOf(s, h.x, st.bottomStep);
            canvas.drawLine(Offset(h.x - 1.8 * hh, y), Offset(h.x + 1.8 * hh, y), ledger);
          }
          final rect = Rect.fromCenter(center: Offset(h.x, h.y), width: 2.9 * hh, height: 2.2 * hh);
          final mark = h.suspect ? attention : color;
          final chosen = isSelected && selected!.pitch == h.pitch;
          if (h.suspect || h.edited || chosen) {
            canvas.drawOval(rect, Paint()..color = (chosen ? tint : mark).withValues(alpha: h.suspect ? 0.38 : 0.28));
          }
          canvas.drawOval(rect, Paint()..color = chosen ? tint : mark..style = PaintingStyle.stroke..strokeWidth = (chosen || h.suspect ? 3 : 2) * px);
          final sign = accidental(h.written, st.fifths);
          if (sign.isNotEmpty && h.edited) {
            final tp = TextPainter(text: TextSpan(text: sign, style: TextStyle(color: mark, fontSize: 4.2 * hh, fontWeight: FontWeight.w700)),
              textDirection: TextDirection.ltr)..layout();
            tp.paint(canvas, Offset(h.x - 1.6 * hh - tp.width, h.y - tp.height / 2));
          }
        }
      }
    }
    final g = ghost;
    if (g != null) {
      final st = view.staffOf(selected!.staff);
      final hh = st.lines!.half(g.x);
      canvas.drawOval(Rect.fromCenter(center: Offset(g.x, g.y), width: 2.9 * hh, height: 2.2 * hh), Paint()..color = tint.withValues(alpha: 0.7));
      final tp = TextPainter(text: TextSpan(text: g.label, style: TextStyle(color: Colors.white, fontSize: 13 * px, fontWeight: FontWeight.w600)),
        textDirection: TextDirection.ltr)..layout();
      final bubble = Rect.fromCenter(center: Offset(g.x, g.y - 3.2 * hh - 10 * px), width: tp.width + 14 * px, height: tp.height + 8 * px);
      canvas.drawRRect(RRect.fromRectAndRadius(bubble, Radius.circular(8 * px)), Paint()..color = tint);
      tp.paint(canvas, bubble.topLeft + Offset(7 * px, 4 * px));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OverlayPainter old) => true;
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: c.secondaryLabel, size: 32),
      const SizedBox(height: 8),
      Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium!.copyWith(color: c.secondaryLabel)),
    ])));
  }
}

// ---------------------------------------------------------------- bar nav

class _BarNav extends StatelessWidget {
  const _BarNav({required this.number, required this.index, required this.count, required this.suspects,
    required this.onPrev, required this.onNext, required this.onNextSuspect});
  final String number;
  final int index, count, suspects;
  final VoidCallback? onPrev, onNext;
  final VoidCallback onNextSuspect;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    return Material(color: c.background, child: Padding(padding: const EdgeInsets.fromLTRB(4, 2, 8, 2), child: Row(children: [
      IconButton(tooltip: '前の小節', onPressed: onPrev, icon: const Icon(Icons.chevron_left_rounded)),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('$number小節', style: text.titleMedium),
        Text(suspects > 0 ? '見つからない音 $suspects' : '${index + 1} / $count',
          style: text.labelMedium!.copyWith(color: suspects > 0 ? c.attention : c.secondaryLabel)),
      ])),
      TextButton.icon(onPressed: onNextSuspect, icon: const Icon(Icons.skip_next_rounded, size: 20), label: const Text('次の要確認')),
      IconButton(tooltip: '次の小節', onPressed: onNext, icon: const Icon(Icons.chevron_right_rounded)),
    ])));
  }
}

class _PartChips extends StatelessWidget {
  const _PartChips({required this.score, required this.selected, required this.onSelect});
  final ScoreDocument score;
  final int selected;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return SizedBox(height: 52, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), children: [
      for (var i = 0; i < score.staves.length; i++) Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(
        label: Text(staffName(score, i)), selected: selected == i, showCheckmark: false,
        labelStyle: TextStyle(color: selected == i ? c.onTint : c.label),
        onSelected: (_) => onSelect(i))),
    ]));
  }
}

String staffName(ScoreDocument score, int i) {
  final st = score.staves[i];
  return st['role'] == 'piano_rh' ? 'ピアノ右手' : st['role'] == 'piano_lh' ? 'ピアノ左手' : '${st['name'] ?? st['id']}';
}

// ------------------------------------------------------------------ strip

/// The selected part's bar as plain notation, laid out by beat.
class _Strip extends StatelessWidget {
  const _Strip({required this.view, required this.staff, required this.selected, required this.onSelect});
  final BarView view;
  final int staff;
  final Selection? selected;
  final ValueChanged<int> onSelect;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final colors = _OverlayColors.of(context, view.score);
    return LayoutBuilder(builder: (context, box) {
      final painter = _StripPainter(view: view, staff: staff, selected: selected?.event, ink: c.label, faint: c.tertiaryLabel,
        tint: c.tint, attention: c.attention, part: colors.byStaff[staff]);
      return Semantics(label: '${staffName(view.score, staff)}の認識結果', child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) {
          final e = painter.hit(d.localPosition.dx, box.maxWidth);
          if (e != null) onSelect(e);
        },
        child: CustomPaint(size: Size(box.maxWidth, 128), painter: painter),
      ));
    });
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({required this.view, required this.staff, required this.selected, required this.ink, required this.faint,
    required this.tint, required this.attention, required this.part});
  final BarView view;
  final int staff;
  final int? selected;
  final Color ink, faint, tint, attention, part;
  static const gap = 9.0;

  double get _length {
    final b = view.score.barLength(staff, view.measure);
    return b.numerator / b.denominator;
  }
  double _x(double onset, double width) => 28 + (onset / _length) * (width - 56);

  int? hit(double x, double width) {
    final list = view.score.events(staff, view.measure);
    int? best;
    var near = double.infinity;
    for (var e = 0; e < list.length; e++) {
      final d = (_x(ScoreDocument.beat(list[e]['onset']), width) + 6 - x).abs();
      if (d < near) { near = d; best = e; }
    }
    return near < 40 ? best : null;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final st = view.staffOf(staff);
    final top = size.height / 2 - 2 * gap;
    final bottomY = top + 4 * gap;
    double yOf(int step) => bottomY - (step - st.bottomStep) * gap / 2;
    final line = Paint()..color = faint..strokeWidth = 1;
    for (var i = 0; i < 5; i++) { canvas.drawLine(Offset(12, top + i * gap), Offset(size.width - 12, top + i * gap), line); }
    canvas.drawLine(Offset(12, top), Offset(12, bottomY), line);
    canvas.drawLine(Offset(size.width - 12, top), Offset(size.width - 12, bottomY), line);
    final list = view.score.events(staff, view.measure);
    final voices = {for (final e in list) (e['voice'] as num?)?.toInt() ?? 0};
    for (var e = 0; e < list.length; e++) {
      final event = list[e] as Map;
      final onset = ScoreDocument.beat(event['onset']), duration = ScoreDocument.beat(event['duration']);
      final grace = event['grace'] == true;
      var x = _x(onset, size.width) + 6;
      if (grace) x -= 10;
      final pitches = (event['pitches'] as List).cast<int>();
      final heads = view.heads(staff, e);
      final suspect = heads.any((h) => h.suspect);
      final edited = heads.any((h) => h.edited);
      final color = suspect ? attention : edited ? part : ink;
      final paint = Paint()..color = color;
      if (e == selected) {
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTRB(x - 13, 6, x + 15, size.height - 6), const Radius.circular(8)),
          Paint()..color = tint.withValues(alpha: 0.14));
      }
      final g = _glyph(duration);
      if (pitches.isEmpty) {
        _rest(canvas, x, top, g, paint);
        continue;
      }
      final steps = [for (final p in pitches) stepOf(st.written(p), st.fifths)]..sort();
      final voice = (event['voice'] as num?)?.toInt() ?? 0;
      final up = voices.length > 1 ? voice == voices.reduce(math.min) : (steps.first + steps.last) / 2 < st.bottomStep + 4;
      final scale = grace ? 0.7 : 1.0;
      final hw = 5.6 * scale, hh = 4.2 * scale;
      for (final p in pitches) {
        final written = st.written(p);
        final step = stepOf(written, st.fifths);
        final y = yOf(step);
        for (var s = st.bottomStep - 2; s >= step; s -= 2) { canvas.drawLine(Offset(x - 9, yOf(s)), Offset(x + 9, yOf(s)), line); }
        for (var s = st.bottomStep + 10; s <= step; s += 2) { canvas.drawLine(Offset(x - 9, yOf(s)), Offset(x + 9, yOf(s)), line); }
        final rect = Rect.fromCenter(center: Offset(x, y), width: 2 * hw, height: 2 * hh);
        canvas.save();
        canvas.translate(x, y); canvas.rotate(-0.35); canvas.translate(-x, -y);
        if (g.hollow) {
          canvas.drawOval(rect, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.6);
        } else { canvas.drawOval(rect, paint); }
        canvas.restore();
        final sign = accidental(written, st.fifths);
        if (sign.isNotEmpty) {
          final tp = TextPainter(text: TextSpan(text: sign, style: TextStyle(color: color, fontSize: 14 * scale, height: 1)),
            textDirection: TextDirection.ltr)..layout();
          tp.paint(canvas, Offset(x - hw - 3 - tp.width, y - tp.height / 2));
        }
        // A dot on a line moves up into the space.
        final dotY = (step - st.bottomStep).isEven ? y - gap / 2 : y;
        for (var d = 0; d < g.dots; d++) { canvas.drawCircle(Offset(x + hw + 4 + d * 5, dotY), 1.8, paint); }
      }
      if (g.stem) {
        final low = yOf(steps.first), high = yOf(steps.last);
        final stemX = up ? x + hw - 0.8 : x - hw + 0.8;
        final end = up ? high - 3.4 * gap * scale : low + 3.4 * gap * scale;
        canvas.drawLine(Offset(stemX, up ? low : high), Offset(stemX, end), Paint()..color = color..strokeWidth = 1.4);
        for (var f = 0; f < g.flags; f++) {
          final y = end + (up ? f * 6.0 : -f * 6.0);
          final path = Path()..moveTo(stemX, y)..quadraticBezierTo(stemX + 9, y + (up ? 7 : -7), stemX + 7, y + (up ? 15 : -15));
          canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.8);
        }
      }
    }
  }

  void _rest(Canvas canvas, double x, double top, ({bool hollow, bool stem, int flags, int dots, double base}) g, Paint paint) {
    final mid = top + 2 * gap;
    if (g.base >= 4) {
      canvas.drawRect(Rect.fromLTWH(x - 6, top + gap, 12, gap / 2), paint);
    } else if (g.base >= 2) {
      canvas.drawRect(Rect.fromLTWH(x - 6, mid - gap / 2, 12, gap / 2), paint);
    } else if (g.base >= 1) {
      final p = Path()..moveTo(x - 2, mid - 1.6 * gap)..lineTo(x + 3, mid - 0.8 * gap)..lineTo(x - 2, mid)
        ..lineTo(x + 3, mid + 0.8 * gap)..quadraticBezierTo(x - 5, mid + 0.6 * gap, x - 1, mid + 1.6 * gap);
      canvas.drawPath(p, Paint()..color = paint.color..style = PaintingStyle.stroke..strokeWidth = 2.2..strokeJoin = StrokeJoin.round);
    } else {
      final flags = math.max(1, g.flags);
      canvas.drawLine(Offset(x + 3, mid - gap), Offset(x - 2, mid + gap * (0.6 + 0.5 * (flags - 1))), Paint()..color = paint.color..strokeWidth = 1.6);
      for (var f = 0; f < flags; f++) {
        canvas.drawCircle(Offset(x - 2, mid - gap * 0.6 + f * gap * 0.8), 2.4, paint);
      }
    }
    for (var d = 0; d < g.dots; d++) { canvas.drawCircle(Offset(x + 10 + d * 5, mid - gap / 2), 1.8, paint); }
  }

  static ({bool hollow, bool stem, int flags, int dots, double base}) _glyph(double beats) {
    const bases = [4.0, 2.0, 1.0, 0.5, 0.25, 0.125, 0.0625];
    for (final b in bases) {
      for (final (dots, factor) in [(0, 1.0), (1, 1.5), (2, 1.75)]) {
        if ((beats - b * factor).abs() < 1e-6) {
          return (hollow: b >= 2, stem: b < 4, flags: b >= 1 ? 0 : (math.log(1 / b) / math.ln2).round(), dots: dots, base: b);
        }
      }
    }
    final b = bases.firstWhere((b) => b <= beats + 1e-9, orElse: () => 0.0625);
    return (hollow: b >= 2, stem: b < 4, flags: b >= 1 ? 0 : (math.log(1 / b) / math.ln2).round(), dots: 0, base: b);
  }

  @override
  bool shouldRepaint(_StripPainter old) => true;
}

// -------------------------------------------------------------- inspector

class _Inspector extends StatelessWidget {
  const _Inspector({required this.view, required this.selected, required this.session, required this.onSelect, required this.onEdit});
  final BarView view;
  final Selection? selected;
  final PracticeSession session;
  final void Function(int staff, int event, int pitch) onSelect;
  final void Function(void Function(ScoreDocument d) change, {Selection? then}) onEdit;

  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    final sel = selected;
    if (sel == null) {
      return Padding(padding: const EdgeInsets.fromLTRB(20, 14, 20, 20), child: Text(
        view.placed
          ? '直したい音を原譜の上か、上の楽譜でタップしてください。選んだ丸を上下に動かすと音の高さが変わります。'
          : '直したい音を上の楽譜でタップしてください。',
        style: text.bodyMedium!.copyWith(color: c.secondaryLabel)));
    }
    final m = view.measure;
    final score = view.score;
    final st = view.staffOf(sel.staff);
    final event = score.event(sel.staff, m, sel.event);
    final pitches = (event['pitches'] as List).cast<int>();
    final rest = pitches.isEmpty;
    final grace = event['grace'] == true;
    final onset = ScoreDocument.beat(event['onset']), duration = ScoreDocument.beat(event['duration']);
    final order = view.order(sel.staff);
    final at = order.indexOf(sel.event);
    final piano = '${score.staves[sel.staff]['role']}'.startsWith('piano');
    final pitch = rest ? null : pitches[sel.pitch.clamp(0, pitches.length - 1)];
    final written = pitch == null ? null : st.written(pitch);
    final heads = view.heads(sel.staff, sel.event);
    final suspect = heads.any((h) => h.pitch == sel.pitch && h.suspect);
    final next = score.nextInVoice(sel.staff, m, sel.event);
    final keep = (staff: sel.staff, event: sel.event, pitch: 0);

    void stepBy(int delta) {
      final s = stepOf(written!, st.fifths) + delta;
      onEdit((d) => d.setPitch(sel.staff, m, sel.event, sel.pitch, st.sounding(pitchAtStep(s, st.fifths))));
    }
    void shift(int delta) => onEdit((d) => d.transpose(sel.staff, m, sel.event, sel.pitch, delta));
    void toNote() {
      final p = view.defaultPitch(sel.staff, sel.event);
      final w = st.written(p);
      final x = BarView.eventX(event);
      final lines = st.lines;
      onEdit((d) => d.restToNote(sel.staff, m, sel.event, p, head: lines == null || x == null ? null
        : (x: x, y: lines.yOf(stepOf(w, st.fifths), x, st.bottomStep), written: w)), then: keep);
    }
    Future<void> split() async {
      final f = BeatFraction.parse(event['duration']);
      BeatFraction? first;
      // A dotted value can split into its note and the dot.
      final k = f.numerator ~/ 3;
      final dotted = f.numerator % 3 == 0 && k > 0 && (k & (k - 1)) == 0;
      if (dotted) {
        final choice = await showModalBottomSheet<int>(context: context, showDragHandle: true, builder: (context) => SafeArea(child: Column(
          mainAxisSize: MainAxisSize.min, children: [
            ListTile(title: const Text('半分ずつに分ける'), onTap: () => Navigator.pop(context, 0)),
            ListTile(title: Text('${durationName(duration * 2 / 3)}＋${durationName(duration / 3)}'), onTap: () => Navigator.pop(context, 1)),
            ListTile(title: Text('${durationName(duration / 3)}＋${durationName(duration * 2 / 3)}'), onTap: () => Navigator.pop(context, 2)),
          ])));
        if (choice == null) return;
        if (choice == 1) first = f * BeatFraction(2, 3);
        if (choice == 2) first = f * BeatFraction(1, 3);
      }
      onEdit((d) => d.split(sel.staff, m, sel.event, first: first), then: keep);
    }

    Widget tool(String label, IconData? icon, VoidCallback? onTap, {String? tooltip}) => Tooltip(message: tooltip ?? label, child: OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: const Size(44, 44), padding: const EdgeInsets.symmetric(horizontal: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
      onPressed: onTap,
      child: label.isEmpty ? Icon(icon, size: 20)
        : icon == null ? Text(label) : Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 18), const SizedBox(width: 4), Text(label)]),
    ));

    return Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        IconButton(tooltip: '前の音', onPressed: at > 0 ? () => onSelect(sel.staff, order[at - 1], 0) : null, icon: const Icon(Icons.chevron_left_rounded)),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(rest ? '休符' : [for (final p in pitches) spelledName(st.written(p), st.fifths)].join('・'),
            style: text.titleLarge!.copyWith(color: suspect ? c.attention : null)),
          Text('${staffName(score, sel.staff)}・${beatName(onset)}・${grace ? '小音符' : durationName(duration, rest: rest)}',
            maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelMedium!.copyWith(color: c.secondaryLabel)),
        ])),
        if (!rest) IconButton(tooltip: '聴く', onPressed: () => session.audition(pitch!, piano: piano), icon: const Icon(Icons.volume_up_rounded)),
        IconButton(tooltip: '次の音', onPressed: at + 1 < order.length ? () => onSelect(sel.staff, order[at + 1], 0) : null, icon: const Icon(Icons.chevron_right_rounded)),
      ]),
      if (suspect) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 6), child: Text(
        'この高さの符頭が原譜で見つかりませんでした。原譜と見比べてください。', style: text.bodySmall!.copyWith(color: c.attention))),
      if (pitches.length > 1) Padding(padding: const EdgeInsets.only(bottom: 6), child: Wrap(spacing: 6, children: [
        for (var p = 0; p < pitches.length; p++) ChoiceChip(label: Text(spelledName(st.written(pitches[p]), st.fifths)),
          selected: p == sel.pitch, showCheckmark: false, labelStyle: TextStyle(color: p == sel.pitch ? c.onTint : c.label),
          onSelected: (_) => onSelect(sel.staff, sel.event, p)),
      ])),
      if (!rest) Wrap(spacing: 6, runSpacing: 6, children: [
        tool('', Icons.keyboard_arrow_up_rounded, () => stepBy(1), tooltip: '1つ上へ'),
        tool('', Icons.keyboard_arrow_down_rounded, () => stepBy(-1), tooltip: '1つ下へ'),
        tool('♯', null, () => shift(1), tooltip: '半音上げる'),
        tool('♭', null, () => shift(-1), tooltip: '半音下げる'),
        tool('8va', null, () => shift(12), tooltip: '1オクターブ上げる'),
        tool('8vb', null, () => shift(-12), tooltip: '1オクターブ下げる'),
      ]),
      if (rest) FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size(44, 44)),
        onPressed: grace ? null : toNote, icon: const Icon(Icons.music_note_rounded), label: const Text('音符にする')),
      if (!grace) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          if (!rest) tool('休符にする', Icons.music_off_rounded, () => onEdit((d) => d.noteToRest(sel.staff, m, sel.event), then: keep)),
          tool('分ける', Icons.call_split_rounded, duration >= 1 / 16 ? split : null, tooltip: '2つの音に分ける'),
          tool('次とつなぐ', Icons.merge_rounded, next == null ? null : () => onEdit((d) => d.mergeWithNext(sel.staff, m, sel.event), then: keep),
            tooltip: '次の音と1つにする'),
          if (!rest) tool('音を足す', Icons.library_add_rounded, () {
            final w = pitchAtStep(stepOf(written!, st.fifths) + 2, st.fifths);
            final x = BarView.eventX(event);
            final lines = st.lines;
            onEdit((d) => d.addChordTone(sel.staff, m, sel.event, st.sounding(w), head: lines == null || x == null || heads.isEmpty ? null
              : (x: heads.first.x, y: lines.yOf(stepOf(w, st.fifths), heads.first.x, st.bottomStep), written: w)));
          }, tooltip: '3度上に和音の音を足す'),
          if (pitches.length > 1) tool('この音を消す', Icons.remove_circle_outline_rounded,
            () => onEdit((d) => d.removeChordTone(sel.staff, m, sel.event, sel.pitch), then: keep)),
        ]),
      ],
      Padding(padding: const EdgeInsets.only(top: 10), child: Text(
        rest ? (st.lines != null ? '原譜の上で休符の印を上下に動かすと、その高さの音符になります。' : '音符にしたあと、▲▼で高さを合わせます。')
          : '分けると同じ高さの音が2つになります。抜けていた音は、分けてから高さを変えて入れます。',
        style: text.bodySmall!.copyWith(color: c.secondaryLabel))),
    ]));
  }
}
