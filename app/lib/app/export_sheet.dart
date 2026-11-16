import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../score.dart';
import 'library.dart';
import 'theme.dart';
import 'widgets.dart';

/// Export: MusicXML, MIDI (with choir practice variants), backup and JSON.
Future<void> showExportSheet(BuildContext context, ScoreDocument score, {required String title, double? tempo}) {
  final messenger = ScaffoldMessenger.of(context);
  Future<void> run(BuildContext sheet, Future<bool> Function() action, String done) async {
    Navigator.pop(sheet);
    try {
      if (await action()) messenger.showSnackBar(SnackBar(content: Text(done)));
    } on PlatformException catch (e) { messenger.showSnackBar(SnackBar(content: Text(e.message ?? '書き出せませんでした。'))); }
    on FormatException catch (e) { messenger.showSnackBar(SnackBar(content: Text(e.message))); }
  }
  return showOtotoriSheet<void>(context, title: '「$title」を書き出す', builder: (sheet) {
    final c = OtotoriColors.of(sheet);
    return ListView(shrinkWrap: true, padding: const EdgeInsets.only(bottom: 16), children: [
      GroupedSection(header: '楽譜', children: [
        ListTile(leading: Icon(Icons.description_rounded, color: c.tint), title: const Text('MusicXML'),
          subtitle: const Text('MuseScore などの楽譜ソフトで開けます'),
          onTap: () => run(sheet, () => const Exporter().musicXml(score), 'MusicXMLを書き出しました。')),
      ]),
      GroupedSection(header: 'MIDI（音源）', footer: tempo == null ? null : 'テンポは${tempo.round()} BPMで書き出します。ミキサーの音量は反映されません。', children: [
        for (final choice in Exporter.midiChoices(score))
          ListTile(leading: Icon(Icons.audio_file_rounded, color: c.tint), title: Text(choice.label), subtitle: Text(choice.detail),
            onTap: () => run(sheet, () => const Exporter().midi(score, choice.key, tempo: tempo), 'MIDIを書き出しました。')),
      ]),
      GroupedSection(header: 'バックアップ', footer: 'バックアップには編集履歴と原譜PDFも含まれます。別の端末へ移すときに使います。', children: [
        ListTile(leading: Icon(Icons.archive_rounded, color: c.tint), title: const Text('バックアップ（ZIP）'),
          onTap: () => run(sheet, () => const Exporter().backup(score), 'バックアップを書き出しました。')),
        ListTile(leading: Icon(Icons.data_object_rounded, color: c.tint), title: const Text('score.json'),
          subtitle: const Text('楽譜データのみ'),
          onTap: () => run(sheet, () => const Exporter().json(score), 'score.jsonを書き出しました。')),
      ]),
    ]);
  }, expand: true);
}
