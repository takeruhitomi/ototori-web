import 'package:choir_mobile/app/app_settings.dart';
import 'package:choir_mobile/app/conversion.dart';
import 'package:choir_mobile/app/library.dart';
import 'package:choir_mobile/app/practice_session.dart';
import 'package:choir_mobile/app/scope.dart';
import 'package:choir_mobile/app/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Services of the tab shell, for pumping one tab or page on its own.
class Harness {
  final session = PracticeSession();
  final library = Library();
  late final conversion = ConversionController(library: library);
  final settings = AppSettings();
  final selected = <OtotoriTab>[];

  Widget wrap(Widget child) => MaterialApp(
    theme: ototoriTheme(Brightness.light),
    home: OtotoriScope(session: session, library: library, conversion: conversion, settings: settings,
      select: selected.add,
      openProject: (id) async { await session.openProject(id); selected.add(OtotoriTab.practice); },
      child: child),
  );
}

/// Selects the first note of the bar editor's notation strip.
Future<void> selectFirstNote(WidgetTester tester) async {
  final strip = tester.getRect(find.bySemanticsLabel(RegExp('認識結果')));
  await tester.tapAt(Offset(strip.left + 34, strip.center.dy));
  await tester.pumpAndSettle();
}
