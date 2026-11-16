import 'package:flutter/widgets.dart';
import 'app_settings.dart';
import 'conversion.dart';
import 'library.dart';
import 'practice_session.dart';

enum OtotoriTab { convert, library, practice, settings }

/// App-wide services, reachable from every tab.
class OtotoriScope extends InheritedWidget {
  const OtotoriScope({super.key, required this.session, required this.library, required this.conversion, required this.settings,
    required this.select, required this.openProject, required super.child});
  final PracticeSession session;
  final Library library;
  final ConversionController conversion;
  final AppSettings settings;
  /// Switches the tab bar.
  final void Function(OtotoriTab tab) select;
  /// Opens a library entry for practice and shows the practice tab.
  final Future<void> Function(String id) openProject;

  static OtotoriScope of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<OtotoriScope>()!;

  @override
  bool updateShouldNotify(OtotoriScope old) => old.session != session || old.library != library || old.conversion != conversion || old.settings != settings;
}
