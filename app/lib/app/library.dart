import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../midi_export.dart';
import '../musicxml_export.dart';
import '../project_backup.dart';
import '../project_persistence.dart';
import '../score.dart';

class LibraryEntry {
  LibraryEntry(Map raw)
    : id = raw['id'] as String,
      title = '${raw['title'] ?? '無題の楽譜'}',
      updated = DateTime.fromMillisecondsSinceEpoch((raw['updated'] as num?)?.toInt() ?? 0),
      parts = [for (final p in raw['parts'] as List? ?? const []) '$p'],
      piano = raw['piano'] == true,
      measures = (raw['measures'] as num?)?.toInt() ?? 0,
      hasSource = raw['hasSource'] == true,
      documentId = raw['documentId'] is String && (raw['documentId'] as String).isNotEmpty ? raw['documentId'] as String : null,
      warnings = (raw['warnings'] as num?)?.toInt() ?? 0;
  final String id, title;
  /// Identity kept across shares: the same song on another phone has the same one.
  final String? documentId;
  final DateTime updated;
  final List<String> parts;
  final bool piano, hasSource;
  final int measures, warnings;
}

/// Saved scores in app storage.
class Library extends ChangeNotifier {
  static const channel = MethodChannel('jp.choiromr.mobile/score');
  List<LibraryEntry> entries = const [];
  bool loading = false, loaded = false;
  String? error;

  Future<void> refresh() async {
    loading = true; error = null; notifyListeners();
    try {
      final raw = await channel.invokeListMethod<Object?>('listProjects') ?? const [];
      entries = [for (final e in raw) if (e is Map) LibraryEntry(e)];
      loaded = true;
    } on PlatformException catch (e) { error = e.message ?? 'ライブラリを読み込めませんでした。'; }
    catch (e) { error = 'ライブラリを読み込めませんでした: $e'; }
    finally { loading = false; notifyListeners(); }
  }

  Future<ScoreDocument> load(String id) async {
    final text = await channel.invokeMethod<String>('loadProject', {'id': id});
    if (text == null) throw const FormatException('楽譜を読み込めませんでした。');
    return ScoreDocument.fromProject(text);
  }

  /// Adds a score as a new entry and returns its id.
  Future<String> add(ScoreDocument document) async {
    final id = await ProjectPersistence().save(document.encodeProject());
    unawaited(refresh());
    return id;
  }

  Future<void> rename(String id, String title) async {
    final document = await load(id);
    document.data['title'] = title.trim();
    await ProjectPersistence(id: id).save(document.encodeProject());
    await refresh();
  }

  Future<void> delete(String id) async {
    await channel.invokeMethod<bool>('deleteProject', {'id': id});
    await refresh();
  }

  /// Picks a score.json and adds it. Returns the new id, or null if cancelled.
  Future<String?> importJson() async {
    final text = await channel.invokeMethod<String>('pick');
    if (text == null) return null;
    return add(ScoreDocument.parse(text));
  }

  /// Entries of the same song (shared copies), newest first.
  List<LibraryEntry> sameSong(String documentId) =>
    entries.where((e) => e.documentId == documentId).toList()..sort((a, b) => b.updated.compareTo(a.updated));

  Future<void> share(ScoreDocument score, String title) => const ProjectBackup().share(score, title);

  /// Saves a received song. Replacing keeps this phone's own practice
  /// settings (mixer, tempo, loop) of the entry it replaces.
  Future<String> accept(IncomingProject project, {String? replace}) async {
    if (replace != null) {
      try {
        final mine = await load(replace);
        final playback = (mine.data['meta'] as Map?)?['mobile_playback'];
        final meta = project.document.data.putIfAbsent('meta', () => <String, dynamic>{}) as Map;
        if (playback != null) { meta['mobile_playback'] = playback; } else { meta.remove('mobile_playback'); }
      } on FormatException { /* The old entry is unreadable: take the received settings. */ }
    }
    final id = await const ProjectBackup().accept(project, replace: replace);
    await refresh();
    return id;
  }

  /// Restores a project ZIP as a new entry. Returns its id, or null if cancelled.
  Future<String?> restoreBackup({required bool Function() attached}) async {
    final restored = await const ProjectBackup().restore(attached: attached);
    if (restored == null) return null;
    await refresh();
    return restored.persistence.id;
  }
}

/// What a MIDI export contains.
class MidiChoice {
  const MidiChoice(this.key, this.label, this.detail);
  final String key, label, detail;
}

/// File exports. Each opens the system save dialog; returns false if cancelled.
class Exporter {
  const Exporter();
  static const channel = MethodChannel('jp.choiromr.mobile/score');

  static Map<String, String> partNames(ScoreDocument score) => {for (final s in score.staves)
    if (s['role'] != 'piano_lh') (s['role'] == 'piano_rh' ? 'piano' : '${s['id']}'): s['role'] == 'piano_rh' ? 'ピアノ' : '${s['name'] ?? s['id']}'};

  static List<MidiChoice> midiChoices(ScoreDocument score) {
    final parts = partNames(score);
    final sung = parts.entries.where((e) => e.key != 'piano').toList();
    return [
      const MidiChoice('_all', 'すべてのパート', '合唱とピアノを含む全体'),
      if (parts.containsKey('piano')) const MidiChoice('_voices', '合唱のみ', 'ピアノを除く'),
      for (final e in sung) MidiChoice('_practice:${e.key}', '${e.value}を強調', 'ほかのパートを小さくした練習用'),
      for (final e in sung) MidiChoice('_minus:${e.key}', '${e.value}を抜く', 'そのパートを歌う練習用（マイナスワン）'),
      for (final e in parts.entries) MidiChoice(e.key, '${e.value}だけ', '1パートのみ'),
    ];
  }

  Future<bool> midi(ScoreDocument score, String choice, {double? tempo}) async {
    final parts = partNames(score);
    final selected = choice.startsWith('_minus:') ? parts.keys.where((k) => k != choice.substring(7)).toSet()
      : choice == '_voices' ? parts.keys.where((k) => k != 'piano').toSet()
      : choice == '_all' || choice.startsWith('_practice:') ? null : {choice};
    final bytes = MidiExporter().export(score.data, tempo: tempo, partsOnly: selected,
      velocities: choice.startsWith('_practice:') ? {for (final id in parts.keys)
        id: id == choice.substring(10) ? 110 : id == 'piano' ? 60 : 45} : {});
    String slug(String id) => id.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    final name = choice == '_all' ? 'full.mid' : choice == '_voices' ? 'voices_only.mid'
      : choice.startsWith('_practice:') ? '${slug(choice.substring(10))}_practice.mid'
      : choice.startsWith('_minus:') ? 'minus_${slug(choice.substring(7))}.mid' : '${slug(choice)}.mid';
    return await channel.invokeMethod<bool>('saveMidi', {'bytes': bytes, 'name': name}) ?? false;
  }

  Future<bool> musicXml(ScoreDocument score) async =>
    await channel.invokeMethod<bool>('saveMusicXml', {'text': MusicXmlExporter().export(score.data)}) ?? false;

  Future<bool> json(ScoreDocument score) async =>
    await channel.invokeMethod<bool>('save', {'text': score.encode()}) ?? false;

  Future<bool> backup(ScoreDocument score) => const ProjectBackup().export(score);
}
