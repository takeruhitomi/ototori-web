import 'package:flutter/services.dart';
import 'score.dart';
import 'project_persistence.dart';

/// A song file received from another app: checked, staged natively, not yet
/// in the library.
class IncomingProject {
  const IncomingProject(this.token, this.document);
  final String token;
  final ScoreDocument document;
}

class RestoredProject {
  const RestoredProject(this.score, this.persistence);
  final ScoreDocument score;
  final ProjectPersistence persistence;
}

/// Validates shared score/history before native source files are published.
class ProjectBackup {
  const ProjectBackup();
  static const channel = MethodChannel('jp.choiromr.mobile/score');
  static const incoming = MethodChannel('jp.choiromr.mobile/incoming');

  /// Opens the system share sheet with the song as one file (.ototori): score,
  /// edits and history, the original PDF and its recognition.
  Future<void> share(ScoreDocument document, String title) =>
      channel.invokeMethod<bool>('shareProject', {'text': document.encodeProject(), 'title': title});

  /// The song file another app handed over, if any (each is returned once).
  Future<IncomingProject?> takeIncoming() async {
    final value = await incoming.invokeMapMethod<String, String>('takeIncomingProject');
    if (value == null) return null;
    final error = value['error'];
    if (error != null) throw FormatException(error);
    final token = value['token'], text = value['text'];
    if (token == null || token.isEmpty || text == null) throw const FormatException('曲ファイルの内容がありません。');
    try {
      return IncomingProject(token, ScoreDocument.fromProject(text));
    } on FormatException {
      await discard(token);
      rethrow;
    }
  }

  /// Publishes the staged files and saves the song, as a new entry or over
  /// [replace]. Returns the library id.
  Future<String> accept(IncomingProject project, {String? replace}) async {
    try {
      await channel.invokeMethod<void>('commitProjectBackup', {'token': project.token});
      return await ProjectPersistence(id: replace).save(project.document.encodeProject());
    } finally { await discard(project.token); }
  }

  Future<void> discard(String token) async {
    try { await channel.invokeMethod<void>('discardProjectBackup', {'token': token}); }
    on PlatformException { /* Temporary files can be removed on a later run. */ }
  }

  Future<bool> export(ScoreDocument document) async =>
      await channel.invokeMethod<bool>('exportProjectBackup', {'text': document.encodeProject()}) ?? false;

  Future<RestoredProject?> restore({required bool Function() attached}) async {
    final value = await channel.invokeMapMethod<Object?, Object?>('pickProjectBackup');
    if (value == null) return null;
    final token = value['token'];
    if (token is! String || token.isEmpty) throw const FormatException('バックアップの参照が不正です。');
    try {
      final text = value['text'];
      if (text is! String) throw const FormatException('バックアップの楽譜がありません。');
      final document = ScoreDocument.fromProject(text);
      if (!attached()) return null;
      await channel.invokeMethod<void>('commitProjectBackup', {'token': token});
      if (!attached()) return null;
      final persistence = ProjectPersistence();
      await persistence.save(document.encodeProject());
      return RestoredProject(document, persistence);
    } finally {
      // Commit also releases staging. Discard is idempotent and cleans failures.
      try { await channel.invokeMethod<void>('discardProjectBackup', {'token': token}); }
      on PlatformException { /* Temporary files can be removed on a later run. */ }
    }
  }
}
