import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../repeat_editor.dart';
import 'export_sheet.dart';
import 'bar_editor.dart';
import 'player_bar.dart';
import 'practice_session.dart';
import 'scope.dart';
import 'side_panel.dart';
import 'score_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

/// Practice: the original score as large as possible, a playback bar below
/// and the mixer in a panel that slides in from the right.
class PracticeTab extends StatefulWidget {
  const PracticeTab({super.key});
  @override
  State<PracticeTab> createState() => _PracticeTabState();
}

class _PracticeTabState extends State<PracticeTab> {
  final _mixerOpen = ValueNotifier<bool>(false);

  @override
  void dispose() { _mixerOpen.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final scope = OtotoriScope.of(context);
    final s = scope.session;
    return ListenableBuilder(listenable: Listenable.merge([s, _mixerOpen, scope.settings]), builder: (context, _) {
      if (!s.hasScore) {
        return Scaffold(appBar: AppBar(title: const Text('練習')), body: EmptyState(
          icon: Icons.headphones_rounded,
          title: '練習する曲を開きましょう',
          message: 'ライブラリの曲を開くと、譜面を見ながら自分のパートを聴けます。',
          actions: [
            FilledButton.icon(onPressed: () => scope.select(OtotoriTab.library),
              icon: const Icon(Icons.library_music_rounded), label: const Text('ライブラリから選ぶ')),
            TextButton(onPressed: () => scope.select(OtotoriTab.convert), child: const Text('PDFから音源を作る')),
          ],
        ));
      }
      return LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= 840;
        final sheet = s.sourceHash != null ? ScoreSheet(session: s, onEditBar: (m) => openBarEditor(context, s, m), showNotes: scope.settings.showRecognized) : _NoSource(session: s);
        return Scaffold(
          appBar: _PracticeAppBar(session: s),
          body: Column(children: [
            if (s.warnings.isNotEmpty) _WarningBanner(session: s),
            Expanded(child: SidePanel(
              open: _mixerOpen, docked: wide, width: wide ? 380 : 340,
              title: 'ミキサー', edgeLabel: 'ミキサーを開く',
              panel: MixerPanel(session: s, padding: const EdgeInsets.only(top: 4)),
              child: sheet,
            )),
            PlayerBar(session: s, mixerOpen: _mixerOpen.value,
              onMixer: () => _mixerOpen.value = !_mixerOpen.value),
          ]),
        );
      });
    });
  }
}

class _PracticeAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _PracticeAppBar({required this.session});
  final PracticeSession session;
  @override
  Size get preferredSize => const Size.fromHeight(60);

  @override
  Widget build(BuildContext context) {
    final s = session;
    final settings = OtotoriScope.of(context).settings;
    final text = Theme.of(context).textTheme;
    final parts = s.parts.map((p) => partAbbreviation(p.id, p.name)).join(' ');
    return AppBar(
      toolbarHeight: 60,
      title: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleLarge),
        Text('$parts・${s.measureCount}小節${s.saving ? '・保存中…' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: text.labelMedium),
      ]),
      actions: [
        IconButton(tooltip: '音を直す', icon: const Icon(Icons.edit_note_rounded),
          onPressed: () => openBarEditor(context, s, s.currentMeasure)),
        PopupMenuButton<String>(
          tooltip: 'その他',
          icon: const Icon(Icons.more_horiz_rounded),
          onSelected: (v) async {
            switch (v) {
              case 'undo': s.undo();
              case 'redo': s.redo();
              case 'repeats':
                await showDialog<void>(context: context, builder: (context) => RepeatEditor(score: s.score!.data,
                  onSave: (enabled, regions) => s.applyRepeats(enabled, regions)));
              case 'notes': settings.setShowRecognized(!settings.showRecognized);
              case 'source': await s.attachSource();
              case 'share':
                try { await OtotoriScope.of(context).library.share(s.score!, s.title); }
                on PlatformException catch (e) { s.notice(e.message ?? '共有できませんでした。'); }
              case 'export': if (context.mounted) await showExportSheet(context, s.score!, title: s.title, tempo: s.tempo);
              case 'rename': if (context.mounted) await renameDialog(context, s.title, s.rename);
            }
          },
          itemBuilder: (context) => [
            PopupMenuItem(value: 'undo', enabled: s.score?.canUndo == true, child: const ListTile(leading: Icon(Icons.undo_rounded), title: Text('元に戻す'))),
            PopupMenuItem(value: 'redo', enabled: s.score?.canRedo == true, child: const ListTile(leading: Icon(Icons.redo_rounded), title: Text('やり直す'))),
            const PopupMenuDivider(),
            CheckedPopupMenuItem(value: 'notes', checked: settings.showRecognized, child: const Text('認識した音符を重ねる')),
            const PopupMenuItem(value: 'repeats', child: ListTile(leading: Icon(Icons.repeat_on_rounded), title: Text('繰り返しを編集'))),
            const PopupMenuItem(value: 'source', child: ListTile(leading: Icon(Icons.picture_as_pdf_rounded), title: Text('原譜PDFを関連付ける'))),
            const PopupMenuItem(value: 'rename', child: ListTile(leading: Icon(Icons.drive_file_rename_outline_rounded), title: Text('名前を変更'))),
            const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.send_rounded), title: Text('共有'))),
            const PopupMenuItem(value: 'export', child: ListTile(leading: Icon(Icons.ios_share_rounded), title: Text('書き出す'))),
          ],
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}

class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.session});
  final PracticeSession session;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final w = session.warnings;
    return Material(color: c.attentionWash, child: InkWell(
      onTap: () => showOtotoriSheet<void>(context, title: '要確認（${w.length}件）', expand: w.length > 6, builder: (context) => ListView(
        shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
          Text('自動認識で確信が持てなかった箇所です。原譜と聴き比べて、違っていたら小節を選んで直してください。',
            style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          for (final line in w) () {
            final bar = _barOf(session, line);
            final row = Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 3), child: Icon(Icons.error_outline_rounded, size: 18, color: c.attention)),
              const SizedBox(width: 8),
              Expanded(child: Text(line)),
              if (bar != null) Icon(Icons.chevron_right_rounded, color: c.tertiaryLabel),
            ]));
            return bar == null ? row : InkWell(borderRadius: BorderRadius.circular(8), onTap: () {
              Navigator.of(context).pop();
              openBarEditor(context, session, bar);
            }, child: row);
          }(),
        ])),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Row(children: [
        Icon(Icons.error_outline_rounded, size: 18, color: c.attention),
        const SizedBox(width: 8),
        Expanded(child: Text('要確認の箇所が${w.length}件あります', style: Theme.of(context).textTheme.labelLarge!.copyWith(color: c.attention))),
        Icon(Icons.chevron_right_rounded, color: c.attention),
      ])),
    ));
  }
}

/// Bar index of the first bar a warning names ("12小節", "3・5小節目").
int? _barOf(PracticeSession session, String line) {
  final match = RegExp(r'(\d+)(?:[・、,]\d+)*小節').firstMatch(line);
  if (match == null) return null;
  final number = int.parse(match.group(1)!);
  final bars = session.measures;
  final i = bars.indexWhere((m) => m['number'] == number);
  if (i >= 0) return i;
  return number >= 1 && number <= bars.length ? number - 1 : null;
}

/// Opens the bar editor at bar index [measure].
void openBarEditor(BuildContext context, PracticeSession session, int measure) {
  if (session.score == null) return;
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BarEditorPage(session: session, measure: measure)));
}

class _NoSource extends StatelessWidget {
  const _NoSource({required this.session});
  final PracticeSession session;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    return Column(children: [
      Material(color: c.surface, child: ListTile(
        leading: const Icon(Icons.picture_as_pdf_outlined),
        title: const Text('原譜PDFが関連付けられていません'),
        subtitle: const Text('関連付けると譜面を見ながら練習できます。いまは小節番号で移動できます。'),
        trailing: TextButton(onPressed: session.attachSource, child: const Text('関連付ける')),
      )),
      Expanded(child: MeasureGrid(session: session)),
    ]);
  }
}

Future<void> renameDialog(BuildContext context, String current, Future<void> Function(String) apply) async {
  final controller = TextEditingController(text: current);
  final name = await showDialog<String>(context: context, builder: (context) => AlertDialog(
    title: const Text('名前を変更'),
    content: TextField(controller: controller, autofocus: true, textInputAction: TextInputAction.done,
      decoration: const InputDecoration(hintText: '曲名'),
      onSubmitted: (v) => Navigator.pop(context, v)),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
      TextButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('変更')),
    ],
  ));
  controller.dispose();
  if (name != null && name.trim().isNotEmpty && name.trim() != current) await apply(name.trim());
}
