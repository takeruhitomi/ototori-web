import 'package:flutter/material.dart';
import 'scope.dart';
import 'theme.dart';
import 'widgets.dart';

const appVersion = '0.2.4';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = OtotoriScope.of(context);
    final conv = scope.conversion;
    final settings = scope.settings;
    final c = OtotoriColors.of(context);
    final text = Theme.of(context).textTheme;
    return Scaffold(body: CustomScrollView(slivers: [
      SliverAppBar.large(title: const Text('設定'), backgroundColor: c.background),
      SliverToBoxAdapter(child: ListenableBuilder(listenable: settings, builder: (context, _) => Column(children: [
        GroupedSection(header: '外観', footer: '自動では、端末のダークモード設定に合わせます。', children: [
          Padding(padding: const EdgeInsets.all(12), child: SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('自動')),
              ButtonSegment(value: ThemeMode.light, label: Text('ライト')),
              ButtonSegment(value: ThemeMode.dark, label: Text('ダーク')),
            ],
            selected: {settings.themeMode},
            onSelectionChanged: (v) => settings.setThemeMode(v.first),
          )),
        ]),
        GroupedSection(header: 'カラー', footer: '譜面の紙は白のまま、今の小節の色と再生位置の線の色が変わります。', children: [
          for (final p in OtotoriPalette.all) _PaletteRow(palette: p, selected: settings.palette.id == p.id,
            onTap: () => settings.setPalette(p)),
        ]),
      ]))),
      SliverToBoxAdapter(child: ListenableBuilder(listenable: conv, builder: (context, _) => GroupedSection(
        header: '楽譜の読み取り',
        footer: '認識モデルはアプリに組み込まれていて、アプリの更新と一緒に新しくなります。読み取りは端末の中だけで行い、楽譜がインターネットへ送られることはありません。',
        children: [
          ListTile(leading: Icon(conv.modelsReady == false ? Icons.error_outline_rounded : Icons.check_circle_rounded,
              color: conv.modelsReady == false ? c.attention : c.parts.tenor),
            title: const Text('認識モデル'),
            subtitle: Text(switch (conv.modelsReady) {
              null => '確認しています',
              true => 'アプリに組み込み済み',
              false => '準備できませんでした。アプリを入れ直してください',
            })),
        ]))),
      SliverToBoxAdapter(child: GroupedSection(header: 'このアプリについて', children: [
        ListTile(leading: const OtotoriMark(size: 36), title: const Text('音鳥'), subtitle: const Text('合唱の音取りアプリ'),
          trailing: Text(appVersion, style: text.labelMedium)),
        const ListTile(title: Text('対応OS'), trailing: Text('Android 13以上')),
        ListTile(title: const Text('ライセンス'), trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => showLicensePage(context: context, applicationName: '音鳥', applicationVersion: appVersion,
            applicationIcon: const Padding(padding: EdgeInsets.all(12), child: OtotoriMark(size: 64)))),
      ])),
      SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(32, 0, 32, 32), child: Text(
        '自動認識の結果には誤りが含まれることがあります。練習の前に原譜と聴き比べてください。'
        '\nピアノ音源: Salamander Grand Piano / Alexander Holm（CC BY 3.0）', style: text.bodySmall))),
    ]));
  }
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({required this.palette, required this.selected, required this.onTap});
  final OtotoriPalette palette;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = OtotoriColors.of(context);
    final p = palette.of(Theme.of(context).brightness);
    Widget dot(Color color, {Color? border}) => Container(width: 22, height: 22, margin: const EdgeInsets.only(right: 4),
      decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: border ?? c.separator)));
    return Semantics(selected: selected, child: ListTile(
      onTap: onTap,
      leading: Row(mainAxisSize: MainAxisSize.min, children: [dot(p.tint), dot(p.nowFill), dot(p.background)]),
      title: Text(palette.name),
      subtitle: Text(palette.description),
      trailing: selected ? Icon(Icons.check_rounded, color: c.tint) : null,
    ));
  }
}
