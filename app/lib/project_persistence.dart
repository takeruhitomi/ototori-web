import 'package:flutter/services.dart';

/// Serializes snapshots per document, including its first id allocation.
class ProjectPersistence {
  ProjectPersistence({this.id});
  String? id;
  Future<void> _tail = Future.value();
  static const _channel = MethodChannel('jp.choiromr.mobile/score');

  Future<String> save(String snapshot) {
    final operation = _tail.then((_) async {
      final saved = await _channel.invokeMethod<String>('saveProject', {'id': id, 'text': snapshot});
      if (saved == null) throw const FormatException('保存結果を確認できませんでした。');
      id = saved;
      return saved;
    });
    // A failed write is reported to its caller; subsequent saves may retry.
    _tail = operation.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return operation;
  }
}
