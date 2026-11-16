import 'package:flutter/material.dart';
import '../score.dart';
import 'library.dart';
import 'theme.dart';
import 'widgets.dart';

enum ReceiveChoice { add, replace }

/// Asks what to do with a song file someone sent: add it, or replace the
/// copy of the same song already in the library.
Future<ReceiveChoice?> showReceiveSheet(BuildContext context, ScoreDocument document, LibraryEntry? same) {
  final staves = document.staves;
  final parts = [for (final s in staves) if (s['role'] != 'piano_lh') s['role'] == 'piano_rh' ? 'ピアノ' : '${s['name'] ?? s['id']}'];
  final bars = staves.isEmpty ? 0 : (staves.first['measures'] as List).length;
  final meta = document.data['meta'];
  final hasSource = meta is Map && meta['source_hash'] is String;
  final title = '${document.data['title'] ?? '無題の楽譜'}';
  return showOtotoriSheet<ReceiveChoice>(context, title: '曲を受け取りました', builder: (sheet) {
    final c = OtotoriColors.of(sheet);
    final text = Theme.of(sheet).textTheme;
    return Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(title, style: text.titleLarge),
        const SizedBox(height: 4),
        Text('${parts.join('・')}　$bars小節　${hasSource ? '原譜PDFつき' : '原譜PDFなし'}',
          style: text.bodyMedium!.copyWith(color: c.secondaryLabel)),
        const SizedBox(height: 16),
        if (same != null) ...[
          Text('ライブラリに同じ曲「${same.title}」があります。受け取った内容に置き換えると、直された音符がそのまま入ります。'
            'ミキサーやテンポなど、この端末での練習の設定は残ります。', style: text.bodyMedium),
          const SizedBox(height: 16),
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(sheet, ReceiveChoice.replace), child: const Text('置き換える')),
          const SizedBox(height: 8),
          OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(sheet, ReceiveChoice.add), child: const Text('別の曲として追加')),
        ] else
          FilledButton(style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            onPressed: () => Navigator.pop(sheet, ReceiveChoice.add), child: const Text('ライブラリに追加')),
        const SizedBox(height: 4),
        TextButton(style: TextButton.styleFrom(minimumSize: const Size.fromHeight(44)),
          onPressed: () => Navigator.pop(sheet), child: const Text('受け取らない')),
      ]));
  });
}
