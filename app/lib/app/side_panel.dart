import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';

/// A panel that slides in from the right edge over (or beside) [child].
///
/// [docked]: the panel takes its width from the content when open (tablets),
/// otherwise it slides over the content with a dimmed backdrop (phones).
/// Both open by dragging from the right edge or by setting [open], and close
/// by dragging the panel header to the right, the close button or the backdrop.
class SidePanel extends StatefulWidget {
  const SidePanel({super.key, required this.open, required this.panel, required this.child,
    this.docked = false, this.width = 360, this.title = '', this.edgeLabel = ''});
  final ValueNotifier<bool> open;
  final Widget panel;
  final Widget child;
  final bool docked;
  final double width;
  final String title;
  /// Accessibility label of the edge handle.
  final String edgeLabel;
  @override
  State<SidePanel> createState() => _SidePanelState();
}

class _SidePanelState extends State<SidePanel> with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(vsync: this,
    duration: const Duration(milliseconds: 260), value: widget.open.value ? 1 : 0);
  double _width = 360;
  bool _dragging = false;
  final _edgeKey = GlobalKey();
  String _excluded = '';
  static const _channel = MethodChannel('jp.choiromr.mobile/score');

  /// Android gesture navigation treats edge swipes as "back". While the panel
  /// is closed and this tab is visible, reserve the handle area (Android
  /// allows up to 200dp per edge) so the swipe reaches the panel.
  void _updateExclusion() {
    if (!mounted) return;
    final visible = TickerMode.valuesOf(context).enabled && _t.value == 0;
    final box = _edgeKey.currentContext?.findRenderObject() as RenderBox?;
    var rects = <List<double>>[];
    if (visible && box != null && box.hasSize && box.attached) {
      final origin = box.localToGlobal(Offset.zero);
      final mid = origin.dy + box.size.height / 2;
      final half = math.min(100.0, box.size.height / 2);
      rects = [[origin.dx - 8, mid - half, origin.dx + box.size.width, mid + half]];
    }
    final key = rects.toString();
    if (key == _excluded) return;
    _excluded = key;
    _channel.invokeMethod<void>('setGestureExclusion', {'rects': rects}).catchError((Object _) {});
  }

  @override
  void initState() {
    super.initState();
    widget.open.addListener(_sync);
    // Re-measure after the frame in which the panel settled.
    _t.addStatusListener((_) => WidgetsBinding.instance.addPostFrameCallback((_) => _updateExclusion()));
  }

  @override
  void didUpdateWidget(covariant SidePanel old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open) { old.open.removeListener(_sync); widget.open.addListener(_sync); _sync(); }
  }

  @override
  void dispose() {
    if (_excluded.isNotEmpty && _excluded != '[]') {
      _channel.invokeMethod<void>('setGestureExclusion', {'rects': <List<double>>[]}).catchError((Object _) {});
    }
    widget.open.removeListener(_sync); _t.dispose(); super.dispose();
  }

  void _sync() {
    // A programmatic open/close also ends a drag the system never finished.
    _dragging = false;
    final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final target = widget.open.value ? 1.0 : 0.0;
    if (reduce) { _t.value = target; } else { _t.animateTo(target, curve: Curves.easeOutCubic); }
  }

  void _dragStart(DragStartDetails _) { _dragging = true; _t.stop(); }
  void _dragUpdate(DragUpdateDetails d) => _t.value = (_t.value - d.delta.dx / _width).clamp(0.0, 1.0);
  /// A drag taken over by another gesture (or the system) settles by position.
  void _dragCancel() => _dragEnd(DragEndDetails());
  void _dragEnd(DragEndDetails d) {
    _dragging = false;
    final v = d.velocity.pixelsPerSecond.dx;
    final open = v.abs() > 300 ? v < 0 : _t.value > 0.5;
    if (open != widget.open.value) HapticFeedback.selectionClick();
    if (widget.open.value == open) { _sync(); } else { widget.open.value = open; }
  }

  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return LayoutBuilder(builder: (context, constraints) {
      _width = widget.docked ? widget.width : math.min(widget.width, constraints.maxWidth * 0.88);
      final panel = Material(
        color: c.background,
        child: SafeArea(left: false, top: false, bottom: false, child: Column(children: [
          // Header: drag right to close.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: _dragStart, onHorizontalDragUpdate: _dragUpdate, onHorizontalDragEnd: _dragEnd, onHorizontalDragCancel: _dragCancel,
            child: Padding(padding: const EdgeInsets.fromLTRB(20, 8, 4, 0), child: Row(children: [
              Expanded(child: Text(widget.title, style: Theme.of(context).textTheme.headlineSmall)),
              IconButton(tooltip: '${widget.title}を閉じる', onPressed: () => widget.open.value = false,
                icon: const Icon(Icons.keyboard_double_arrow_right_rounded)),
            ])),
          ),
          Expanded(child: widget.panel),
        ])),
      );
      WidgetsBinding.instance.addPostFrameCallback((_) => _updateExclusion());
      return AnimatedBuilder(animation: _t, builder: (context, _) {
        final t = _t.value;
        // The edge strip stays mounted (same key, same slot) so a drag that
        // starts on it survives the panel beginning to move.
        final edge = Positioned(key: _edgeKey, right: 0, top: 0, bottom: 0, width: 24, child: IgnorePointer(
          ignoring: t > 0 && !_dragging,
          child: Semantics(
            button: true, label: widget.edgeLabel,
            onTap: () => widget.open.value = true,
            child: GestureDetector(
              // Opaque: the score's pinch/pan below must not compete for this touch.
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: _dragStart, onHorizontalDragUpdate: _dragUpdate, onHorizontalDragEnd: _dragEnd, onHorizontalDragCancel: _dragCancel,
              child: Align(alignment: Alignment.centerRight, child: Opacity(opacity: t == 0 ? 1 : 0, child: Container(
                width: 5, height: 56, margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(color: c.tertiaryLabel.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(3))))),
            ),
          ),
        ));
        if (widget.docked) {
          return Row(children: [
            Expanded(child: Stack(children: [Positioned.fill(child: widget.child), edge])),
            SizedBox(width: _width * t, child: ClipRect(child: OverflowBox(
              alignment: Alignment.centerLeft, minWidth: _width, maxWidth: _width,
              child: Offstage(offstage: t == 0, child: DecoratedBox(
                decoration: BoxDecoration(border: Border(left: BorderSide(color: c.separator, width: 0.5))),
                child: panel))))),
          ]);
        }
        return Stack(children: [
          Positioned.fill(child: widget.child),
          Positioned.fill(child: IgnorePointer(ignoring: t == 0, child: GestureDetector(
            onTap: () => widget.open.value = false,
            onHorizontalDragStart: _dragStart, onHorizontalDragUpdate: _dragUpdate, onHorizontalDragEnd: _dragEnd, onHorizontalDragCancel: _dragCancel,
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.28 * t))))),
          Positioned(top: 0, bottom: 0, right: -_width * (1 - t), width: _width,
            child: Offstage(offstage: t == 0, child: DecoratedBox(
              decoration: BoxDecoration(boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.18 * t), blurRadius: 16)]),
              child: panel))),
          edge,
        ]);
      });
    });
  }
}
