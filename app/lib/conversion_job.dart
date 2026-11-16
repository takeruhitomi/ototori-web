import 'dart:convert';
import 'package:flutter/services.dart';

class ConversionJob {
  ConversionJob(Map<String, dynamic> settings, {this.id}) : signature = jsonEncode(_validate(settings));
  String? id;
  final String signature;
  Map<String, dynamic> get settings => jsonDecode(signature) as Map<String, dynamic>;
  final completedPages = <int>{};
  String status = 'pending';
  String? error;
  static const channel = MethodChannel('jp.choiromr.mobile/pdf');

  factory ConversionJob.restore(String id, String text) {
    try {
      final data = jsonDecode(text) as Map;
      if (data['version'] != 1) throw const FormatException('変換ジョブの形式が未対応です。');
      final job = ConversionJob(Map<String, dynamic>.from(data['settings'] as Map), id: id);
      final status = data['status'];
      if (!['pending', 'running', 'recognized', 'cancelled', 'failed', 'complete'].contains(status)) throw const FormatException('変換状態が不正です。');
      job.status = status as String;
      job.error = data['error'] as String?;
      for (final page in data['completed_pages'] as List) {
        if (page is! int || page < 0 || page >= job.settings['pages'] ||
            (job.settings['all_pages'] != true && page != job.settings['selected_page'])) {
          throw const FormatException('保存されたページ進捗が不正です。');
        }
        job.completedPages.add(page);
      }
      return job;
    } on TypeError { throw const FormatException('変換ジョブの形式が不正です。'); }
  }

  Future<void> save(String nextStatus, {String? error}) async {
    if (!['pending', 'running', 'recognized', 'cancelled', 'failed', 'complete'].contains(nextStatus)) throw ArgumentError(nextStatus);
    status = nextStatus; this.error = error;
    final pages = completedPages.toList()..sort();
    final saved = await channel.invokeMethod<String>('saveConversion', {'id': id, 'text': jsonEncode({
      'version': 1, 'settings': settings, 'status': status, 'completed_pages': pages, 'error': error,
    })});
    if (saved == null) throw const FormatException('変換ジョブの保存結果を確認できませんでした。');
    id = saved;
  }

  static Map<String, dynamic> _validate(Map<String, dynamic> data) {
    final hash = data['source_hash'], name = data['name'], dpi = data['dpi'], pages = data['pages'];
    final selected = data['selected_page'], all = data['all_pages'], piano = data['piano'], voices = data['voice_names'];
    if (data.containsKey('auto_ensemble') && data['auto_ensemble'] is! bool) throw const FormatException('編成の自動判定設定が不正です。');
    if (hash is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) || name is! String ||
        dpi is! int || (dpi != 300 && dpi != 400) || pages is! int || pages < 1 || selected is! int || selected < 0 || selected >= pages ||
        all is! bool || piano is! bool || voices is! List || voices.isEmpty || voices.length > 12 ||
        voices.any((v) => v is! String || v.trim().isEmpty)) { throw const FormatException('変換設定が不正です。'); }
    return {'source_hash': hash, 'name': name, 'dpi': dpi, 'pages': pages,
      'selected_page': selected, 'all_pages': all, 'piano': piano, 'voice_names': List.of(voices),
      if (data.containsKey('auto_ensemble')) 'auto_ensemble': data['auto_ensemble']};
  }
}
