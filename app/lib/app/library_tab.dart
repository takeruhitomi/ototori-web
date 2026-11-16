import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'export_sheet.dart';
import 'library.dart';
import 'practice_tab.dart' show renameDialog;
import 'scope.dart';
import 'theme.dart';
import 'widgets.dart';

/// Library: saved scores. Tap to practice; "…" to export, rename or delete.
class LibraryTab extends StatefulWidget {
  const LibraryTab({super.key});
  @override
  State<LibraryTab> createState() => _LibraryTabState();
}

class _LibraryTabState extends State<LibraryTab> {
  String _query = '';

  Future<void> _guard(Future<void> Function() action) async {
    final messenger = ScaffoldMessenger.of(context);
    try { await action(); }
    on PlatformException catch (e) { messenger.showSnackBar(SnackBar(content: Text(e.message ?? '操作できませんでした。'))); }
    on FormatException catch (e) { messenger.showSnackBar(SnackBar(content: Text(e.message))); }
  }

  Future<void> _import(String kind) => _guard(() async {
    final scope = OtotoriScope.of(context);
    final id = kind == 'backup' ? await scope.library.restoreBackup(attached: () => mounted) : await scope.library.importJson();
    if (id != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ライブラリに追加しました。')));
    }
  });

  Future<void> _actions(LibraryEntry entry) async {
    final scope = OtotoriScope.of(context);
    final c = OtotoriColors.of(context);
    final action = await showOtotoriSheet<String>(context, title: entry.title, builder: (sheet) => ListView(shrinkWrap: true,
      padding: const EdgeInsets.only(bottom: 16), children: [
        GroupedSection(children: [
          ListTile(leading: Icon(Icons.headphones_rounded, color: c.tint), title: const Text('練習で開く'), onTap: () => Navigator.pop(sheet, 'open')),
          ListTile(leading: Icon(Icons.send_rounded, color: c.tint), title: const Text('共有'),
            subtitle: const Text('直した内容と原譜をまとめて、ほかの人に送ります'), onTap: () => Navigator.pop(sheet, 'share')),
          ListTile(leading: Icon(Icons.ios_share_rounded, color: c.tint), title: const Text('書き出す'),
            subtitle: const Text('MusicXML・MIDI・バックアップ'), onTap: () => Navigator.pop(sheet, 'export')),
          ListTile(leading: Icon(Icons.drive_file_rename_outline_rounded, color: c.tint), title: const Text('名前を変更'), onTap: () => Navigator.pop(sheet, 'rename')),
        ]),
        GroupedSection(children: [
          ListTile(leading: Icon(Icons.delete_outline_rounded, color: c.destructive),
            title: Text('削除', style: TextStyle(color: c.destructive)), onTap: () => Navigator.pop(sheet, 'delete')),
        ]),
      ]));
    if (!mounted || action == null) return;
    switch (action) {
      case 'open': await scope.openProject(entry.id);
      case 'export': await _guard(() async {
        final open = scope.session.projectId == entry.id;
        final score = open ? scope.session.score! : await scope.library.load(entry.id);
        if (mounted) await showExportSheet(context, score, title: entry.title, tempo: open ? scope.session.tempo : null);
      });
      case 'share': await _guard(() async {
        final open = scope.session.projectId == entry.id;
        final score = open ? scope.session.score! : await scope.library.load(entry.id);
        await scope.library.share(score, entry.title);
      });
      case 'rename': await renameDialog(context, entry.title, (name) => _guard(() async {
        if (scope.session.projectId == entry.id) { await scope.session.rename(name); await scope.library.refresh(); }
        else { await scope.library.rename(entry.id, name); }
      }));
      case 'delete': await _delete(entry);
    }
  }

  Future<void> _delete(LibraryEntry entry) async {
    final scope = OtotoriScope.of(context);
    final ok = await confirmDestructive(context, title: '「${entry.title}」を削除しますか？',
      message: '楽譜と編集内容、練習の設定が削除されます。元に戻せません。', action: '削除');
    if (!ok || !mounted) return;
    await _guard(() async {
      if (scope.session.projectId == entry.id) await scope.session.close();
      await scope.library.delete(entry.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = OtotoriScope.of(context);
    final library = scope.library;
    final c = OtotoriColors.of(context);
    return ListenableBuilder(listenable: Listenable.merge([library, scope.session]), builder: (context, _) {
      final q = _query.trim().toLowerCase();
      final entries = q.isEmpty ? library.entries : library.entries.where((e) => e.title.toLowerCase().contains(q)).toList();
      final empty = library.loaded && library.entries.isEmpty;
      return Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () { scope.select(OtotoriTab.convert); scope.conversion.pickPdfs(); },
          icon: const Icon(Icons.add_rounded), label: const Text('新しく変換')),
        body: RefreshIndicator(onRefresh: library.refresh, child: CustomScrollView(slivers: [
          SliverAppBar.large(title: const Text('ライブラリ'), backgroundColor: c.background, actions: [
            PopupMenuButton<String>(tooltip: '読み込む', icon: const Icon(Icons.file_download_outlined), onSelected: _import, itemBuilder: (context) => const [
              PopupMenuItem(value: 'backup', child: ListTile(leading: Icon(Icons.unarchive_rounded), title: Text('バックアップから復元'))),
              PopupMenuItem(value: 'json', child: ListTile(leading: Icon(Icons.data_object_rounded), title: Text('score.jsonを読み込む'))),
            ]),
            const SizedBox(width: 4),
          ]),
          if (!empty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: SearchBar(
            hintText: '曲名で検索', leading: Icon(Icons.search_rounded, color: c.secondaryLabel),
            elevation: const WidgetStatePropertyAll(0), backgroundColor: WidgetStatePropertyAll(c.surface),
            constraints: const BoxConstraints(minHeight: 44),
            onChanged: (v) => setState(() => _query = v)))),
          if (library.error != null) SliverToBoxAdapter(child: GroupedSection(children: [
            ListTile(leading: Icon(Icons.error_outline_rounded, color: c.destructive), title: Text(library.error!),
              trailing: TextButton(onPressed: library.refresh, child: const Text('再試行'))),
          ])),
          if (!library.loaded && library.loading) const SliverFillRemaining(child: Center(child: CircularProgressIndicator())),
          if (empty) SliverFillRemaining(hasScrollBody: false, child: EmptyState(
            image: const OtotoriMark(size: 88),
            title: 'まだ曲がありません',
            message: '合唱の楽譜PDFを変換すると、ここに並びます。',
            actions: [FilledButton.icon(onPressed: () { scope.select(OtotoriTab.convert); scope.conversion.pickPdfs(); },
              icon: const Icon(Icons.picture_as_pdf_rounded), label: const Text('PDFを選んで変換'))],
          )),
          if (!empty && entries.isEmpty && q.isNotEmpty) SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.all(32),
            child: Text('「$_query」に一致する曲はありません。', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium))),
          if (entries.isNotEmpty) SliverToBoxAdapter(child: GroupedSection(children: [
            for (final e in entries) Dismissible(
              key: ValueKey(e.id),
              direction: DismissDirection.endToStart,
              confirmDismiss: (_) async { await _delete(e); return false; },
              background: Container(color: c.destructive, alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 24),
                child: const Icon(Icons.delete_rounded, color: Colors.white)),
              child: _EntryRow(entry: e, open: scope.session.projectId == e.id,
                onTap: () => scope.openProject(e.id), onMore: () => _actions(e)),
            ),
          ])),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ])),
      );
    });
  }
}

class _EntryRow extends StatelessWidget {
  const _EntryRow({required this.entry, required this.open, required this.onTap, required this.onMore});
  final LibraryEntry entry;
  final bool open;
  final VoidCallback onTap, onMore;

  static String _date(DateTime d) {
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
    if (days == 0) return '今日 ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
    if (days == 1) return '昨日';
    if (days < 7) return '$days日前';
    return d.year == now.year ? '${d.month}月${d.day}日' : '${d.year}/${d.month}/${d.day}';
  }

  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    final details = [
      if (entry.measures > 0) '${entry.measures}小節',
      _date(entry.updated),
    ].join('・');
    final status = [if (open) '練習中', if (entry.warnings > 0) '要確認${entry.warnings}件'];
    return InkWell(onTap: onTap, child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 4, 12), child: Row(children: [
      Container(width: 44, height: 44, decoration: BoxDecoration(color: c.tile, borderRadius: BorderRadius.circular(10)),
        child: Icon(open ? Icons.graphic_eq_rounded : Icons.music_note_rounded, color: c.tileIcon)),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(entry.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.titleMedium),
        if (entry.parts.isNotEmpty || entry.piano) Padding(padding: const EdgeInsets.only(top: 6), child: Wrap(spacing: 4, runSpacing: 4, children: [
          for (final p in entry.parts.take(8)) PartBadge(id: p, name: p, size: 20),
          if (entry.piano) const PartBadge(id: 'piano', name: 'ピアノ', size: 20),
        ])),
        const SizedBox(height: 4),
        Text.rich(TextSpan(style: text.labelMedium, children: [
          TextSpan(text: details),
          if (status.isNotEmpty) TextSpan(text: '・${status.join('・')}',
            style: TextStyle(color: open ? c.tint : c.attention)),
        ]), maxLines: 2, overflow: TextOverflow.ellipsis),
      ])),
      IconButton(tooltip: '${entry.title}の操作', onPressed: onMore, icon: Icon(Icons.more_horiz_rounded, color: c.secondaryLabel)),
    ])));
  }
}
