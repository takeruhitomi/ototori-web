import 'dart:convert';
import 'package:flutter/material.dart';
import 'repeat_plan.dart';

/// Editing uses the same validated representation as playback and MIDI.
class RepeatEditor extends StatefulWidget {
  const RepeatEditor({super.key, required this.score, required this.onSave});
  final Map<String, dynamic> score;
  final void Function(bool enabled, List<Map<String, dynamic>>? regions) onSave;
  @override
  State<RepeatEditor> createState() => _RepeatEditorState();
}

class _RepeatEditorState extends State<RepeatEditor> {
  late bool enabled;
  late List<Map<String, dynamic>> regions;
  bool automatic = false;
  RepeatPlan? preview;
  String? error;
  final form = GlobalKey<FormState>();
  @override
  void initState() {
    super.initState();
    final meta = widget.score['meta'] as Map? ?? {};
    enabled = meta['repeats_enabled'] != false;
    automatic = meta['repeat_override'] == null;
    try {
      regions = (jsonDecode(jsonEncode(meta['repeat_override'] ??
        RepeatPlanner().detectedRegions(widget.score))) as List).cast<Map<String, dynamic>>();
    } on FormatException catch (e) { regions = []; error = e.message; }
  }
  RepeatPlan plan() => RepeatPlanner().build({...widget.score, 'meta': {
    ...?widget.score['meta'] as Map?, 'repeats_enabled': enabled,
    'repeat_override': automatic ? null : regions,
  }});
  Widget integer(String label, int value, void Function(int) change) => SizedBox(width: 95,
    child: TextFormField(key: ValueKey('$label-$value'), initialValue: '$value',
      decoration: InputDecoration(labelText: label), keyboardType: TextInputType.number,
      validator: (v) => int.tryParse(v ?? '') == null ? '整数を入力' : null,
      onChanged: (v) { final n = int.tryParse(v); if (n != null) { change(n); automatic = false; preview = null; } }));
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('反復・括弧の編集'),
    content: Form(key: form, child: SizedBox(width: 640, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      CheckboxListTile(title: const Text('反復を有効にする'), value: enabled,
        onChanged: (v) => setState(() { enabled = v!; preview = null; })),
      const Text('原譜の小節番号で指定します。括弧の回数は「1,2」のように入力できます。'),
      for (var i = 0; i < regions.length; i++) Card(child: Padding(padding: const EdgeInsets.all(8), child: Column(children: [
        Wrap(spacing: 8, children: [
          integer('開始', regions[i]['start'] as int, (v) => regions[i]['start'] = v),
          integer('終了', regions[i]['end'] as int, (v) => regions[i]['end'] = v),
          integer('回数', regions[i]['times'] as int, (v) => regions[i]['times'] = v),
          IconButton(tooltip: '反復を削除', onPressed: () => setState(() { regions.removeAt(i); automatic = false; preview = null; }),
            icon: const Icon(Icons.delete_outline)),
        ]),
        for (var j = 0; j < (regions[i]['endings'] as List? ?? []).length; j++)
          Builder(builder: (context) {
            final e = regions[i]['endings'][j] as Map;
            return Wrap(spacing: 8, children: [
              integer('括弧開始', e['start'] as int, (v) => e['start'] = v),
              integer('括弧終了', e['end'] as int, (v) => e['end'] = v),
              SizedBox(width: 95, child: TextFormField(initialValue: (e['passes'] as List).join(','),
                decoration: const InputDecoration(labelText: '演奏回'),
                onChanged: (v) { e['passes'] = v.split(',').map((s) => int.tryParse(s.trim()) ?? 0).toList(); automatic = false; preview = null; })),
              IconButton(tooltip: '括弧を削除', icon: const Icon(Icons.remove_circle_outline),
                onPressed: () => setState(() { (regions[i]['endings'] as List).removeAt(j); automatic = false; preview = null; })),
            ]);
          }),
        TextButton(onPressed: () => setState(() {
          (regions[i].putIfAbsent('endings', () => <dynamic>[]) as List).add({
            'start': regions[i]['end'], 'end': regions[i]['end'], 'passes': [1],
          }); automatic = false; preview = null;
        }), child: const Text('括弧を追加')),
      ]))),
      Wrap(children: [
        TextButton(onPressed: () => setState(() {
          regions.add({'start': 1, 'end': 1, 'times': 2, 'endings': <dynamic>[]}); automatic = false; preview = null;
        }), child: const Text('反復を追加')),
        TextButton(onPressed: () {
          try { setState(() { regions = RepeatPlanner().detectedRegions(widget.score); automatic = true; preview = null; error = null; }); }
          on FormatException catch (e) { setState(() => error = e.message); }
        }, child: const Text('自動検出に戻す')),
        TextButton(onPressed: () { if (form.currentState!.validate()) setState(() { preview = plan(); error = null; }); }, child: const Text('演奏順を確認')),
      ]),
      if (automatic) const Text('自動検出の反復を使用'),
      if (preview != null) ...[
        Text('演奏順: ${preview!.order.map((i) => i + 1).join(' → ')}'),
        for (final warning in preview!.warnings) Text(warning, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
      if (error != null) Text(error!),
    ])))),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('戻る')),
      FilledButton(onPressed: () {
        if (!form.currentState!.validate()) return;
        final result = plan();
        if (!result.valid) { setState(() => preview = result); return; }
        widget.onSave(enabled, automatic ? null : regions);
        Navigator.pop(context);
      }, child: const Text('反復設定を保存')),
    ],
  );
}
