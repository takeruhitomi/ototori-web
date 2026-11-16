import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';

/// Display preferences, saved in app storage.
class AppSettings extends ChangeNotifier {
  static const channel = MethodChannel('jp.choiromr.mobile/score');
  OtotoriPalette palette = OtotoriPalette.ototori;
  ThemeMode themeMode = ThemeMode.system;
  /// Draw the recognized notes over the original in practice.
  bool showRecognized = true;

  Future<void> load() async {
    try {
      final text = await channel.invokeMethod<String>('loadAppSettings');
      if (text == null) return;
      final data = jsonDecode(text) as Map;
      palette = OtotoriPalette.byId(data['palette'] as String?);
      themeMode = switch (data['themeMode']) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system };
      showRecognized = data['showRecognized'] != false;
      notifyListeners();
    } on PlatformException { /* Defaults stay. */ }
    on MissingPluginException { /* Tests and other hosts. */ }
    on FormatException { /* A damaged file falls back to defaults. */ }
    on TypeError { /* Same. */ }
  }

  void setPalette(OtotoriPalette value) { palette = value; notifyListeners(); _save(); }
  void setThemeMode(ThemeMode value) { themeMode = value; notifyListeners(); _save(); }
  void setShowRecognized(bool value) { showRecognized = value; notifyListeners(); _save(); }

  Future<void> _save() async {
    try {
      await channel.invokeMethod<void>('saveAppSettings', {'text': jsonEncode({
        'palette': palette.id, 'themeMode': themeMode.name, 'showRecognized': showRecognized})});
    } on PlatformException { /* Kept for this session. */ }
    on MissingPluginException { /* Same. */ }
  }
}
