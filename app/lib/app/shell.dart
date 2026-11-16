import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_settings.dart';
import 'conversion.dart';
import 'convert_tab.dart';
import '../project_backup.dart';
import 'share_sheet.dart';
import 'library.dart';
import 'library_tab.dart';
import 'practice_session.dart';
import 'practice_tab.dart';
import 'scope.dart';
import 'settings_tab.dart';
import 'theme.dart';

class OtotoriApp extends StatefulWidget {
  const OtotoriApp({super.key, this.initialTab});
  final OtotoriTab? initialTab;
  @override
  State<OtotoriApp> createState() => _OtotoriAppState();
}

class _OtotoriAppState extends State<OtotoriApp> {
  final settings = AppSettings();
  @override
  void initState() { super.initState(); settings.load(); }
  @override
  void dispose() { settings.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: settings, builder: (context, _) => MaterialApp(
    title: '音鳥',
    debugShowCheckedModeBanner: false,
    theme: ototoriTheme(Brightness.light, settings.palette),
    darkTheme: ototoriTheme(Brightness.dark, settings.palette),
    themeMode: settings.themeMode,
    home: HomeShell(initialTab: widget.initialTab, settings: settings),
  ));
}

/// Tab bar shell: 変換 / ライブラリ / 練習 / 設定.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, this.initialTab, required this.settings});
  final OtotoriTab? initialTab;
  final AppSettings settings;
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final library = Library();
  final session = PracticeSession();
  late final conversion = ConversionController(library: library);
  OtotoriTab tab = OtotoriTab.convert;
  StreamSubscription<String>? _notices;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    tab = widget.initialTab ?? OtotoriTab.convert;
    _notices = session.notices.listen(_snack);
    conversion.onNotice = _snack;
    conversion.onFinished = _converted;
    session.libraryChanged.addListener(() {
      _refresh?.cancel();
      _refresh = Timer(const Duration(milliseconds: 400), library.refresh);
    });
    // The app always opens on 変換, the first step of the workflow.
    library.refresh();
    conversion.checkModels();
    conversion.loadUnfinished();
    // Song files from other apps: one may have arrived with the launch.
    ProjectBackup.incoming.setMethodCallHandler((call) async { if (call.method == 'incomingProject') unawaited(_receive()); });
    WidgetsBinding.instance.addPostFrameCallback((_) => _receive());
  }

  bool _receiving = false;

  Future<void> _receive() async {
    if (_receiving || !mounted) return;
    _receiving = true;
    try {
      while (mounted) {
        final project = await const ProjectBackup().takeIncoming();
        if (project == null || !mounted) return;
        if (!library.loaded) await library.refresh();
        final same = library.sameSong(project.document.identity.documentId).firstOrNull;
        if (!mounted) return;
        final choice = await showReceiveSheet(context, project.document, same);
        if (choice == null) { await const ProjectBackup().discard(project.token); continue; }
        final replace = choice == ReceiveChoice.replace ? same!.id : null;
        // The open copy is replaced: save its settings first, then let go of it.
        if (replace != null && session.projectId == replace) { await session.save(quiet: true); await session.close(); }
        final id = await library.accept(project, replace: replace);
        final title = '${project.document.data['title'] ?? '曲'}';
        await openProject(id);
        _snack(replace != null ? '「$title」を受け取った内容に置き換えました。' : '「$title」をライブラリに追加しました。');
      }
    } on FormatException catch (e) { _snack(e.message);
    } on PlatformException catch (e) { _snack(e.message ?? '曲ファイルを受け取れませんでした。');
    } on MissingPluginException { /* Tests and other hosts. */
    } finally { _receiving = false; }
  }

  @override
  void dispose() {
    ProjectBackup.incoming.setMethodCallHandler(null);
    _notices?.cancel();
    _refresh?.cancel();
    conversion.dispose();
    session.dispose();
    library.dispose();
    super.dispose();
  }

  void _snack(String message, {SnackBarAction? action}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(message), action: action));
  }

  void _converted(ConversionItem item, dynamic score, {required bool last}) {
    if (!mounted) return;
    final done = conversion.items.where((i) => i.status == ItemStatus.done).length;
    if (!conversion.batch) {
      session.open(score, projectId: item.projectId).then((_) {
        if (!mounted) return;
        setState(() => tab = OtotoriTab.practice);
        final warnings = session.warnings.length;
        _snack(warnings == 0 ? '「${item.title}」ができました。' : '「${item.title}」ができました。要確認の箇所が$warnings件あります。');
      });
    } else if (last) {
      _snack('$done件の変換が終わりました。', action: SnackBarAction(label: 'ライブラリ', onPressed: () => select(OtotoriTab.library)));
    }
  }

  void select(OtotoriTab next) {
    if (next == tab) return;
    HapticFeedback.selectionClick();
    setState(() => tab = next);
  }

  Future<void> openProject(String id) async {
    try {
      if (session.projectId != id) await session.openProject(id);
      if (mounted) setState(() => tab = OtotoriTab.practice);
    } on PlatformException catch (e) { _snack(e.message ?? '楽譜を開けませんでした。'); }
    on FormatException catch (e) { _snack(e.message); }
  }

  @override
  Widget build(BuildContext context) {
    return OtotoriScope(
      session: session, library: library, conversion: conversion, settings: widget.settings, select: select, openProject: openProject,
      child: Scaffold(
        body: IndexedStack(index: tab.index, children: [
          // Hidden tabs keep their state but stop animating.
          for (final (i, page) in const [ConvertTab(), LibraryTab(), PracticeTab(), SettingsTab()].indexed)
            TickerMode(enabled: i == tab.index, child: page),
        ]),
        bottomNavigationBar: ListenableBuilder(listenable: Listenable.merge([conversion, session]), builder: (context, _) {
          final c = OtotoriColors.of(context);
          return DecoratedBox(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: c.separator, width: 0.5))),
            child: NavigationBar(
              selectedIndex: tab.index,
              onDestinationSelected: (i) => select(OtotoriTab.values[i]),
              destinations: [
                NavigationDestination(
                  icon: Badge(isLabelVisible: conversion.running, backgroundColor: OtotoriColors.of(context).attention, smallSize: 8,
                    child: const Icon(Icons.document_scanner_outlined)),
                  selectedIcon: Badge(isLabelVisible: conversion.running, backgroundColor: OtotoriColors.of(context).attention, smallSize: 8,
                    child: const Icon(Icons.document_scanner_rounded)),
                  label: '変換'),
                const NavigationDestination(icon: Icon(Icons.library_music_outlined), selectedIcon: Icon(Icons.library_music_rounded), label: 'ライブラリ'),
                NavigationDestination(
                  icon: Icon(session.playing ? Icons.graphic_eq_rounded : Icons.headphones_outlined),
                  selectedIcon: Icon(session.playing ? Icons.graphic_eq_rounded : Icons.headphones_rounded),
                  label: '練習'),
                const NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings_rounded), label: '設定'),
              ],
            ),
          );
        }),
      ),
    );
  }
}
