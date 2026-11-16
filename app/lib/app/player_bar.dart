import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'practice_session.dart';
import 'theme.dart';
import 'widgets.dart';

/// Transport pinned under the score: scrubber, play, bar steps, loop, tempo, click.
class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key, required this.session, this.onMixer, this.mixerOpen = false});
  final PracticeSession session;
  /// Opens or closes the mixer panel.
  final VoidCallback? onMixer;
  final bool mixerOpen;
  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    final plan = s.plan;
    final from = s.rangeFrom, to = s.rangeTo > s.rangeFrom ? s.rangeTo : s.rangeFrom + 1;
    final value = (_drag ?? s.position).clamp(from, to);
    int barAt(double beat) => plan == null || plan.order.isEmpty ? 0
      : plan.order[plan.measureStarts.lastIndexWhere((b) => b <= beat + 1e-6).clamp(0, plan.order.length - 1)];
    final bar = _drag == null ? s.currentMeasure : barAt(_drag!);
    // Phones in portrait: the chord name gives way to the tempo and click.
    final narrow = MediaQuery.sizeOf(context).width < 420;
    return Material(
      color: c.surface,
      child: Container(
        decoration: BoxDecoration(border: Border(top: BorderSide(color: c.separator, width: 0.5))),
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
            Text('${s.measureLabel(bar)}小節', style: text.titleSmall!.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
            Text(' / ${s.measureCount}', style: text.labelMedium),
            if (s.loop) ...[
              const SizedBox(width: 8),
              Icon(Icons.repeat_rounded, size: 16, color: c.attention),
              Text(' ループ中', style: text.labelMedium!.copyWith(color: c.attention)),
            ],
            const Spacer(),
            if (!narrow) _ChordLabel(label: s.chordLabelAt(value), tuned: s.justIntonation),
            _JustButton(session: s, compact: narrow),
            _TempoButton(session: s),
            _ToggleIcon(icon: const MetronomeIcon(), label: s.metronome ? 'メトロノームを止める' : 'メトロノームを鳴らす',
              active: s.metronome, activeColor: c.tint, onPressed: () => s.setMetronome(!s.metronome)),
          ])),
          if (s.transport.interruption != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(s.transport.interruption!, maxLines: 2, overflow: TextOverflow.ellipsis,
              style: text.labelMedium!.copyWith(color: c.attention))),
          SizedBox(height: 32, child: Slider(
            value: value, min: from, max: to,
            semanticFormatterCallback: (v) => '${s.measureLabel(barAt(v))}小節',
            onChanged: plan == null ? null : (v) => setState(() => _drag = v),
            onChangeEnd: (v) { setState(() => _drag = null); s.seekBeat(v); },
          )),
          // Transport centered between loop (left) and mixer (right).
          Row(children: [
            Expanded(child: Align(alignment: Alignment.centerLeft, child: _ToggleIcon(icon: const Icon(Icons.repeat_rounded),
              label: 'ループ', active: s.loop, activeColor: c.attention, onPressed: () => showLoopSheet(context, s)))),
            IconButton(tooltip: '前の小節', iconSize: 30, icon: const Icon(Icons.skip_previous_rounded),
              onPressed: plan == null ? null : () => s.stepMeasure(-1)),
            const SizedBox(width: 4),
            _PlayButton(playing: s.playing, onPressed: plan == null ? null : () { HapticFeedback.lightImpact(); s.togglePlay(); }),
            const SizedBox(width: 4),
            IconButton(tooltip: '次の小節', iconSize: 30, icon: const Icon(Icons.skip_next_rounded),
              onPressed: plan == null ? null : () => s.stepMeasure(1)),
            Expanded(child: Align(alignment: Alignment.centerRight, child: widget.onMixer == null ? null
              : _ToggleIcon(icon: const Icon(Icons.tune_rounded), label: 'ミキサー', active: widget.mixerOpen, activeColor: c.tint, onPressed: widget.onMixer!))),
          ]),
        ]),
      ),
    );
  }
}

class _PlayButton extends StatelessWidget {
  const _PlayButton({required this.playing, required this.onPressed});
  final bool playing;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return Semantics(button: true, label: playing ? '一時停止' : '再生', child: Tooltip(message: playing ? '一時停止' : '再生',
      child: Material(color: onPressed == null ? c.separator : c.nowFill, shape: const CircleBorder(),
        child: InkWell(customBorder: const CircleBorder(), onTap: onPressed, child: SizedBox(width: 60, height: 60,
          child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 36, color: c.onNow))))));
  }
}

class _ToggleIcon extends StatelessWidget {
  const _ToggleIcon({required this.icon, required this.label, required this.active, required this.activeColor, required this.onPressed});
  final Widget icon;
  final String label;
  final bool active;
  final Color activeColor;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return IconButton(tooltip: label, onPressed: onPressed, isSelected: active,
      style: IconButton.styleFrom(backgroundColor: active ? activeColor.withValues(alpha: 0.14) : null,
        foregroundColor: active ? activeColor : c.secondaryLabel),
      icon: icon);
  }
}

/// Chord under the playhead (complete major/minor triads of the sung parts).
class _ChordLabel extends StatelessWidget {
  const _ChordLabel({required this.label, required this.tuned});
  final String? label;
  final bool tuned;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(label: label == null ? '和音なし' : '和音 $label', child: ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 44),
      child: Text(label ?? '—', textAlign: TextAlign.center,
        style: text.titleSmall!.copyWith(color: label != null && tuned ? c.tint : c.secondaryLabel,
          fontWeight: label != null ? FontWeight.w700 : FontWeight.w400))));
  }
}

/// Trial switch between equal temperament and just intonation.
class _JustButton extends StatelessWidget {
  const _JustButton({required this.session, this.compact = false});
  final PracticeSession session;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final on = session.justIntonation;
    return Tooltip(message: on ? '平均律に戻す' : '純正律で鳴らす（試作）', child: TextButton(
      style: TextButton.styleFrom(foregroundColor: on ? c.tint : c.secondaryLabel,
        backgroundColor: on ? c.tint.withValues(alpha: 0.14) : null,
        padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 10), minimumSize: Size(compact ? 40 : 48, 36)),
      onPressed: () { HapticFeedback.selectionClick(); session.setJustIntonation(!on); },
      child: Text(compact ? (on ? '純正' : '平均') : (on ? '純正律' : '平均律')),
    ));
  }
}

class _TempoButton extends StatelessWidget {
  const _TempoButton({required this.session});
  final PracticeSession session;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return Tooltip(message: 'テンポ', child: TextButton(
      style: TextButton.styleFrom(foregroundColor: c.tint, padding: const EdgeInsets.symmetric(horizontal: 8)),
      onPressed: () => showTempoSheet(context, session),
      child: Text('♩=${session.tempo.round()}', style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()])),
    ));
  }
}

/// Tempo is set by the singer: the recognizer does not read tempo marks.
Future<void> showTempoSheet(BuildContext context, PracticeSession s) => showOtotoriSheet<void>(context, title: 'テンポ',
  builder: (context) => _TempoSheet(session: s));

class _TempoSheet extends StatefulWidget {
  const _TempoSheet({required this.session});
  final PracticeSession session;
  @override
  State<_TempoSheet> createState() => _TempoSheetState();
}

class _TempoSheetState extends State<_TempoSheet> {
  final _taps = <int>[];

  /// Tap tempo: the average of the last few intervals sets the BPM.
  void _tap() {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_taps.isNotEmpty && now - _taps.last > 2000) _taps.clear();
    _taps.add(now);
    if (_taps.length > 6) _taps.removeAt(0);
    if (_taps.length >= 3) {
      final span = (_taps.last - _taps.first) / (_taps.length - 1);
      widget.session.setTempo(60000 / span);
    }
    HapticFeedback.selectionClick();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: widget.session, builder: (context, _) {
    final s = widget.session;
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    return SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 8, 20, 24), child: Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        IconButton.outlined(tooltip: '1下げる', onPressed: () => s.setTempo(s.tempo - 1), icon: const Icon(Icons.remove_rounded)),
        const SizedBox(width: 20),
        Column(children: [
          Text('${s.tempo.round()}', style: text.headlineLarge!.copyWith(fontSize: 48, fontFeatures: const [FontFeature.tabularFigures()])),
          Text('4分音符 / 分', style: text.labelMedium),
        ]),
        const SizedBox(width: 20),
        IconButton.outlined(tooltip: '1上げる', onPressed: () => s.setTempo(s.tempo + 1), icon: const Icon(Icons.add_rounded)),
      ]),
      Slider(value: s.tempo.clamp(30, 240), min: 30, max: 240, divisions: 210, onChanged: s.setTempo,
        semanticFormatterCallback: (v) => '${v.round()} BPM'),
      Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
        for (final bpm in const [60, 72, 80, 92, 104, 120])
          ChoiceChip(label: Text('$bpm'), selected: s.tempo.round() == bpm,
            labelStyle: TextStyle(color: s.tempo.round() == bpm ? c.onTint : c.label),
            onSelected: (_) => s.setTempo(bpm.toDouble())),
      ]),
      const SizedBox(height: 16),
      SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: _tap,
        style: OutlinedButton.styleFrom(minimumSize: const Size(44, 52)),
        icon: const Icon(Icons.touch_app_rounded),
        label: Text(_taps.length < 3 ? '拍に合わせて3回以上タップ' : 'タップしてテンポを合わせる'))),
      const SizedBox(height: 8),
      Text('楽譜のテンポ記号は読み取っていません。楽譜や指揮に合わせて設定してください。', textAlign: TextAlign.center, style: text.bodySmall),
    ]));
  });
}

/// Metronome glyph: a pyramid case with a swinging pendulum and weight.
class MetronomeIcon extends StatelessWidget {
  const MetronomeIcon({super.key, this.size});
  final double? size;
  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final s = size ?? theme.size ?? 24;
    return SizedBox(width: s, height: s, child: CustomPaint(painter: _MetronomePainter(theme.color ?? Colors.black)));
  }
}

class _MetronomePainter extends CustomPainter {
  _MetronomePainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final stroke = Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = w * 0.085
      ..strokeJoin = StrokeJoin.round..strokeCap = StrokeCap.round;
    // Case: a tall trapezoid narrowing to the top.
    final body = Path()
      ..moveTo(w * 0.22, h * 0.90)
      ..lineTo(w * 0.40, h * 0.12)
      ..lineTo(w * 0.60, h * 0.12)
      ..lineTo(w * 0.78, h * 0.90)
      ..close();
    canvas.drawPath(body, stroke);
    // Base line inside the case.
    canvas.drawLine(Offset(w * 0.30, h * 0.72), Offset(w * 0.70, h * 0.72), stroke);
    // Pendulum swung to the right, with its sliding weight.
    final pivot = Offset(w * 0.50, h * 0.72);
    final tip = Offset(w * 0.84, h * 0.22);
    canvas.drawLine(pivot, tip, stroke);
    canvas.drawCircle(Offset.lerp(pivot, tip, 0.55)!, w * 0.075, Paint()..color = color);
  }
  @override
  bool shouldRepaint(_MetronomePainter old) => old.color != color;
}

/// Loop range in performed order (repeats count separately).
Future<void> showLoopSheet(BuildContext context, PracticeSession s) {
  final plan = s.plan;
  if (plan == null || plan.order.isEmpty) return Future.value();
  if (!s.loop) {
    // Start from the current bar, four bars long.
    final from = s.performedIndex.clamp(0, plan.order.length - 1);
    s.loopFrom = from; s.loopTo = (from + 3).clamp(from, plan.order.length - 1);
  }
  return showOtotoriSheet<void>(context, title: '区間ループ', builder: (context) => ListenableBuilder(listenable: s, builder: (context, _) {
    final text = Theme.of(context).textTheme;
    final c = OtotoriColors.of(context);
    String label(int i) {
      final source = plan.order[i];
      final repeated = plan.order.where((m) => m == source).length > 1;
      final nth = plan.order.sublist(0, i + 1).where((m) => m == source).length;
      return '${s.measureLabel(source)}小節${repeated ? '（$nth回目）' : ''}';
    }
    Widget picker(String title, int value, void Function(int) onChanged) => ListTile(
      title: Text(title),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(tooltip: '$titleを前へ', onPressed: value > 0 ? () => onChanged(value - 1) : null, icon: const Icon(Icons.chevron_left_rounded)),
        ConstrainedBox(constraints: const BoxConstraints(minWidth: 96),
          child: Text(label(value), textAlign: TextAlign.center, style: text.titleMedium)),
        IconButton(tooltip: '$titleを後へ', onPressed: value < plan.order.length - 1 ? () => onChanged(value + 1) : null, icon: const Icon(Icons.chevron_right_rounded)),
      ]),
    );
    return SingleChildScrollView(padding: const EdgeInsets.only(bottom: 24), child: Column(children: [
      GroupedSection(footer: '繰り返し記号のある曲では、演奏する順番で数えます。', children: [
        SwitchListTile(title: const Text('ループする'), value: s.loop, onChanged: (v) => s.setLoop(v)),
        picker('開始', s.loopFrom, (v) => s.setLoop(s.loop, from: v, to: s.loopTo < v ? v : s.loopTo)),
        picker('終了', s.loopTo, (v) => s.setLoop(s.loop, from: s.loopFrom > v ? v : s.loopFrom, to: v)),
        ListTile(leading: Icon(Icons.my_location_rounded, color: c.tint),
          title: Text('今の小節から4小節', style: TextStyle(color: c.tint)),
          onTap: () {
            final from = s.performedIndex.clamp(0, plan.order.length - 1);
            s.setLoop(true, from: from, to: (from + 3).clamp(from, plan.order.length - 1));
          }),
      ]),
    ]));
  }));
}

/// Part volumes, mute/solo, the choir focus shortcut and the metronome.
class MixerPanel extends StatelessWidget {
  const MixerPanel({super.key, required this.session, this.padding = EdgeInsets.zero});
  final PracticeSession session;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: session, builder: (context, _) {
    final s = session;
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    final sung = s.parts.where((p) => !p.isPiano).toList();
    return ListView(padding: padding, children: [
      GroupedSection(header: '自分のパートで練習', footer: s.focusPart == null
          ? 'パートを選ぶと、そのパートを大きく（または抜いて）再生します。'
          : s.focusMode == FocusMode.emphasis ? '選んだパートを大きく、ほかを小さくしています。' : '選んだパートを消して、ほかのパートと合わせられます。',
        children: [Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(label: const Text('全員'), selected: s.focusPart == null,
              labelStyle: TextStyle(color: s.focusPart == null ? c.onTint : c.label),
              onSelected: (_) => s.setFocus(null)),
            for (final p in sung) ChoiceChip(
              avatar: PartBadge(id: p.id, name: p.name, size: 22),
              label: Text(p.name), selected: s.focusPart == p.id,
              labelStyle: TextStyle(color: s.focusPart == p.id ? c.onTint : c.label),
              onSelected: (_) => s.setFocus(p.id)),
          ]),
          if (s.focusPart != null) Padding(padding: const EdgeInsets.only(top: 12), child: SegmentedButton<FocusMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: FocusMode.emphasis, label: Text('強調'), icon: Icon(Icons.campaign_rounded)),
              ButtonSegment(value: FocusMode.minusOne, label: Text('抜く'), icon: Icon(Icons.voice_over_off_rounded)),
            ],
            selected: {s.focusMode},
            onSelectionChanged: (v) => s.setFocus(s.focusPart, v.first),
          )),
        ]))]),
      GroupedSection(header: 'パート', children: [
        for (final p in s.parts) _PartRow(session: s, part: p),
      ]),
      GroupedSection(header: 'メトロノーム', children: [
        SwitchListTile(title: const Text('クリックを鳴らす'), value: s.metronome, onChanged: s.setMetronome),
        _SliderRow(icon: const MetronomeIcon(size: 22), label: 'クリック音量', value: s.metroVolume,
          onChanged: s.metronome ? s.setMetroVolume : null),
        SwitchListTile(title: const Text('再生前に1小節カウント'), subtitle: const Text('曲の頭や区間の始めから再生するとき'),
          value: s.countIn, onChanged: s.setCountIn),
      ]),
      GroupedSection(header: '全体', footer: 'ミキサーの設定は楽譜ごとに保存されます。', children: [
        _SliderRow(icon: const Icon(Icons.volume_up_rounded, size: 22), label: '全体の音量', value: s.masterVolume, onChanged: s.setMaster),
        SwitchListTile(title: const Text('再生位置を譜面で追う'), value: s.follow, onChanged: s.setFollow),
        ListTile(title: Text('ミキサーを元に戻す', style: TextStyle(color: c.tint)), onTap: s.resetMixer),
      ]),
      Padding(padding: const EdgeInsets.fromLTRB(32, 0, 32, 24), child: Text(
        '合唱パートは簡易合成音、ピアノは録音音源（Salamander Grand Piano）です。', style: text.bodySmall)),
    ]);
  });
}

class _PartRow extends StatelessWidget {
  const _PartRow({required this.session, required this.part});
  final PracticeSession session;
  final PartInfo part;
  // 'choir' is a sine with soft overtones (it does not imitate voices), named for how it sounds.
  static const _instruments = {'choir': 'やわらかい音', 'piano': 'ピアノ', 'organ': 'オルガン', 'sine': 'サイン波'};
  @override
  Widget build(BuildContext context) {
    final s = session;
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    final muted = s.muted.contains(part.id);
    final solo = s.solos.contains(part.id);
    final silenced = muted || (s.solos.isNotEmpty && !solo);
    return Padding(padding: const EdgeInsets.fromLTRB(12, 8, 4, 4), child: Column(children: [
      Row(children: [
        PartBadge(id: part.id, name: part.name, dimmed: silenced),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(part.name, style: text.titleMedium!.copyWith(color: silenced ? c.tertiaryLabel : c.label)),
          PopupMenuButton<String>(
            tooltip: '${part.name}の音色',
            initialValue: s.instrumentOf(part),
            onSelected: (v) => s.setInstrument(part.id, v),
            itemBuilder: (context) => [for (final e in _instruments.entries) PopupMenuItem(value: e.key, child: Text(e.value))],
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_instruments[s.instrumentOf(part)] ?? '', style: text.labelMedium!.copyWith(color: c.tint)),
              Icon(Icons.expand_more_rounded, size: 16, color: c.tint),
            ])),
          ),
        ])),
        _SmallToggle(label: 'ソロ', tooltip: '${part.name}をソロ', active: solo, color: c.tint, onPressed: () => s.toggleSolo(part.id)),
        IconButton(tooltip: muted ? '${part.name}のミュートを解除' : '${part.name}をミュート', isSelected: muted,
          onPressed: () => s.toggleMute(part.id),
          icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: muted ? c.destructive : c.secondaryLabel)),
      ]),
      Slider(value: s.volumeOf(part.id), onChanged: (v) => s.setVolume(part.id, v),
        semanticFormatterCallback: (v) => '${part.name}の音量 ${(v * 100).round()}%'),
    ]));
  }
}

class _SmallToggle extends StatelessWidget {
  const _SmallToggle({required this.label, required this.tooltip, required this.active, required this.color, required this.onPressed});
  final String label, tooltip;
  final bool active;
  final Color color;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return Tooltip(message: tooltip, child: Semantics(button: true, toggled: active, label: tooltip, child: InkWell(
      borderRadius: BorderRadius.circular(8), onTap: onPressed,
      child: Container(constraints: const BoxConstraints(minWidth: 48, minHeight: 44), alignment: Alignment.center,
        child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: active ? color : Colors.transparent, borderRadius: BorderRadius.circular(6),
            border: Border.all(color: active ? color : c.separator)),
          child: Text(label, style: Theme.of(context).textTheme.labelMedium!.copyWith(
            color: active ? c.onTint : c.secondaryLabel, fontWeight: FontWeight.w700)))))));
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.icon, required this.label, required this.value, required this.onChanged});
  final Widget icon;
  final String label;
  final double value;
  final ValueChanged<double>? onChanged;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return Padding(padding: const EdgeInsets.fromLTRB(16, 4, 8, 4), child: Row(children: [
      IconTheme(data: IconThemeData(color: c.secondaryLabel, size: 22), child: icon),
      const SizedBox(width: 8),
      Text(label, style: Theme.of(context).textTheme.bodyLarge),
      Expanded(child: Slider(value: value, onChanged: onChanged,
        semanticFormatterCallback: (v) => '$label ${(v * 100).round()}%')),
    ]));
  }
}
