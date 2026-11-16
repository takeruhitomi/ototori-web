import 'package:flutter/material.dart';
import 'conversion.dart';
import 'scope.dart';
import 'theme.dart';
import 'widgets.dart';

/// Convert: choose PDFs → parts → create practice audio.
class ConvertTab extends StatefulWidget {
  const ConvertTab({super.key});
  @override
  State<ConvertTab> createState() => _ConvertTabState();
}

class _ConvertTabState extends State<ConvertTab> {
  final _voices = TextEditingController();
  bool _advanced = false;

  @override
  void dispose() { _voices.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final scope = OtotoriScope.of(context);
    final conv = scope.conversion;
    return ListenableBuilder(listenable: conv, builder: (context, _) {
      if (_voices.text != conv.voiceText) _voices.text = conv.voiceText;
      final c = OtotoriColors.of(context);
      final text = Theme.of(context).textTheme;
      final waiting = conv.items.where((i) => i.status == ItemStatus.waiting).length;
      final locked = conv.running;
      return Scaffold(
        body: CustomScrollView(slivers: [
          SliverAppBar.large(title: const Text('変換'), backgroundColor: c.background),
          SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(32, 0, 32, 12), child: Text(
            '合唱の楽譜PDFを読み取り、パートごとに聴ける音取り音源を作ります。', style: text.bodyMedium!.copyWith(color: c.secondaryLabel)))),
          if (conv.modelsReady == false) SliverToBoxAdapter(child: GroupedSection(children: [
            ListTile(leading: Icon(Icons.error_outline_rounded, color: c.attention),
              title: const Text('認識モデルを準備できませんでした'),
              subtitle: const Text('アプリを入れ直すと直ることがあります。'),
              trailing: TextButton(onPressed: conv.checkModels, child: const Text('再確認'))),
          ])),
          SliverToBoxAdapter(child: _Step(number: 1, title: '楽譜')),
          SliverToBoxAdapter(child: conv.items.isEmpty
            ? _PickArea(onPick: conv.pickPdfs)
            : GroupedSection(
                footer: conv.batch ? '${conv.items.length}件のPDFを順番に変換します。' : null,
                children: [
                  for (final item in conv.items) _ItemRow(item: item, conv: conv),
                  if (!locked) ListTile(leading: Icon(Icons.add_rounded, color: c.tint),
                    title: Text('PDFを追加', style: TextStyle(color: c.tint)), onTap: conv.pickPdfs),
                ])),
          SliverToBoxAdapter(child: _Step(number: 2, title: 'パート構成')),
          SliverToBoxAdapter(child: GroupedSection(
            footer: conv.autoEnsemble
              ? '譜面の段組みと音部記号から、合唱パートとピアノ伴奏を見分けます。'
              : '上の段から順に、カンマ区切りで入力してください。',
            children: [
              SwitchListTile(title: const Text('自動で認識する'), value: conv.autoEnsemble, onChanged: locked ? null : conv.setAuto),
              if (!conv.autoEnsemble) ...[
                Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final p in EnsemblePreset.all) ChoiceChip(label: Text(p.label),
                    selected: conv.voiceText == p.voices.join(', '),
                    labelStyle: TextStyle(color: conv.voiceText == p.voices.join(', ') ? c.onTint : c.label),
                    onSelected: locked ? null : (_) => conv.setPreset(p)),
                ])),
                Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 12), child: TextField(
                  controller: _voices, enabled: !locked, onChanged: conv.setVoices,
                  decoration: const InputDecoration(labelText: '合唱パート（上から順に）', hintText: 'Soprano, Alto, Tenor, Bass'))),
                SwitchListTile(title: const Text('ピアノ伴奏（2段）がある'), value: conv.piano, onChanged: locked ? null : conv.setPiano),
              ],
            ])),
          if (!conv.batch && conv.items.isNotEmpty) ...[
            SliverToBoxAdapter(child: _Step(number: 3, title: '範囲')),
            SliverToBoxAdapter(child: _RangeSection(conv: conv, locked: locked)),
          ],
          SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: TextButton.icon(
            onPressed: () => setState(() => _advanced = !_advanced),
            icon: Icon(_advanced ? Icons.expand_less_rounded : Icons.expand_more_rounded),
            label: const Text('詳細設定')))),
          if (_advanced) SliverToBoxAdapter(child: GroupedSection(
            footer: '高精細は小さな音符の読み取りが良くなることがありますが、時間とメモリを多く使います。',
            children: [Padding(padding: const EdgeInsets.all(12), child: Row(children: [
              const Expanded(child: Text('読み取りの解像度')),
              SegmentedButton<int>(showSelectedIcon: false,
                segments: const [ButtonSegment(value: 300, label: Text('標準')), ButtonSegment(value: 400, label: Text('高精細'))],
                selected: {conv.dpi}, onSelectionChanged: locked ? null : (v) => conv.setDpi(v.first)),
            ]))])),
          if (conv.unfinished.isNotEmpty && !locked) ...[
            SliverToBoxAdapter(child: GroupedSection(header: '途中で止まった変換',
              footer: '再開すると、読み取り済みのページはそのまま使います。削除しても、同じPDFを変換し直すときは読み取り済みのページを使います。',
              children: [for (final e in conv.unfinished.take(5)) ListTile(
                leading: const Icon(Icons.pause_circle_outline_rounded),
                title: Text('${e['name']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${e['completed']}ページ読み取り済み・${_statusLabel('${e['status']}')}'),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(onPressed: () => conv.resume('${e['id']}'), child: const Text('再開')),
                  IconButton(tooltip: '削除', icon: Icon(Icons.delete_outline_rounded, color: c.destructive),
                    onPressed: () async {
                      final ok = await confirmDestructive(context, title: '途中の変換を削除',
                        message: '「${e['name']}」をこの一覧から削除します。',
                        action: '削除');
                      if (ok) await conv.deleteUnfinished('${e['id']}');
                    }),
                ]),
                onTap: () => conv.resume('${e['id']}'))])),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
        ]),
        bottomNavigationBar: _ActionBar(conv: conv, waiting: waiting),
      );
    });
  }

  static String _statusLabel(String status) => const {'pending': '未開始', 'running': '中断', 'recognized': '組み立て前',
    'cancelled': '中止', 'failed': '要確認'}[status] ?? '要確認';
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.title});
  final int number;
  final String title;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return Padding(padding: const EdgeInsets.fromLTRB(32, 12, 32, 0), child: Row(children: [
      Container(width: 22, height: 22, alignment: Alignment.center,
        decoration: BoxDecoration(color: c.tint, shape: BoxShape.circle),
        child: Text('$number', style: TextStyle(color: c.onTint, fontSize: 12, fontWeight: FontWeight.w700))),
      const SizedBox(width: 8),
      Text(title, style: Theme.of(context).textTheme.titleMedium),
    ]));
  }
}

class _PickArea extends StatelessWidget {
  const _PickArea({required this.onPick});
  final VoidCallback onPick;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), child: Material(
      color: c.surface, borderRadius: BorderRadius.circular(14),
      child: InkWell(borderRadius: BorderRadius.circular(14), onTap: onPick, child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        child: Column(children: [
          Icon(Icons.picture_as_pdf_rounded, size: 44, color: c.tint),
          const SizedBox(height: 10),
          Text('PDFを選ぶ', style: text.titleMedium!.copyWith(color: c.tint)),
          const SizedBox(height: 4),
          Text('複数選ぶと、まとめて順番に変換します', style: text.bodySmall),
        ]),
      )),
    ));
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.conv});
  final ConversionItem item;
  final ConversionController conv;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final scope = OtotoriScope.of(context);
    final (IconData icon, Color color, String status) = switch (item.status) {
      ItemStatus.waiting => (Icons.picture_as_pdf_outlined, c.secondaryLabel, '${item.pages}ページ'),
      ItemStatus.running => (Icons.sync_rounded, c.tint, '${item.completedPages} / ${item.pages}ページ読み取り済み'),
      ItemStatus.done => (Icons.check_circle_rounded, c.parts.tenor, '完了・ライブラリに保存しました'),
      ItemStatus.failed => (Icons.error_rounded, c.destructive, item.detail ?? '変換できませんでした'),
      ItemStatus.cancelled => (Icons.cancel_rounded, c.tertiaryLabel, '中止しました'),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ListTile(
        leading: Icon(icon, color: color),
        title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(status, maxLines: 3, overflow: TextOverflow.ellipsis),
        trailing: switch (item.status) {
          ItemStatus.waiting when !conv.running => IconButton(tooltip: '${item.title}を外す', onPressed: () => conv.remove(item), icon: const Icon(Icons.close_rounded)),
          ItemStatus.done when item.projectId != null => TextButton(onPressed: () => scope.openProject(item.projectId!), child: const Text('練習')),
          _ => null,
        },
      ),
      if (item.status == ItemStatus.running) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: LinearProgressIndicator(value: item.pages == 0 ? null : (item.completedPages / item.pages).clamp(0.02, 1.0),
          borderRadius: BorderRadius.circular(2))),
    ]);
  }
}

class _RangeSection extends StatelessWidget {
  const _RangeSection({required this.conv, required this.locked});
  final ConversionController conv;
  final bool locked;
  @override
  Widget build(BuildContext context) {
    final pages = conv.items.first.pages;
    final single = conv.singlePage;
    return GroupedSection(footer: single != null ? '試しに1ページだけ読み取るときに使います。' : null, children: [
      Padding(padding: const EdgeInsets.all(12), child: SegmentedButton<bool>(showSelectedIcon: false,
        segments: const [ButtonSegment(value: false, label: Text('すべてのページ')), ButtonSegment(value: true, label: Text('1ページだけ'))],
        selected: {single != null},
        onSelectionChanged: locked ? null : (v) => conv.setSinglePage(v.first ? 0 : null))),
      if (single != null) ListTile(title: const Text('ページ'), trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(tooltip: '前のページ', onPressed: !locked && single > 0 ? () => conv.setSinglePage(single - 1) : null, icon: const Icon(Icons.remove_rounded)),
        Text('${single + 1} / $pages', style: Theme.of(context).textTheme.titleMedium),
        IconButton(tooltip: '次のページ', onPressed: !locked && single + 1 < pages ? () => conv.setSinglePage(single + 1) : null, icon: const Icon(Icons.add_rounded)),
      ])),
    ]);
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.conv, required this.waiting});
  final ConversionController conv;
  final int waiting;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    final current = conv.current;
    return Material(color: c.background, child: SafeArea(top: false, child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: conv.running
        ? Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(current == null ? '準備しています' : current.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
              Text(conv.stage ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelMedium),
              if (conv.batch) Text('残り${conv.pendingCount}件', style: text.labelMedium),
            ])),
            const SizedBox(width: 12),
            OutlinedButton(onPressed: conv.cancelRequested ? null : conv.cancel,
              style: OutlinedButton.styleFrom(foregroundColor: c.destructive), child: const Text('中止')),
          ])
        : FilledButton.icon(
            onPressed: waiting == 0 ? null : conv.start,
            icon: const Icon(Icons.graphic_eq_rounded),
            label: Text(waiting > 1 ? '$waiting件をまとめて変換' : '音取り音源を作る')),
    )));
  }
}
