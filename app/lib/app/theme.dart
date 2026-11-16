import 'package:flutter/material.dart';

/// Semantic colors of one color set in one brightness.
///
/// Roles: [tint] marks what can be operated; [nowFill] is "now" (the play
/// button); [attention] marks things to check and the loop range. The score
/// page stays white paper in every set, so [markFill], [markLine] and
/// [playhead] are chosen to read on white.
@immutable
class OtotoriColors extends ThemeExtension<OtotoriColors> {
  const OtotoriColors({
    required this.tint,
    required this.onTint,
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.separator,
    required this.nowFill,
    required this.onNow,
    required this.nowWash,
    required this.attention,
    required this.attentionWash,
    required this.destructive,
    required this.markFill,
    required this.markLine,
    required this.playhead,
    required this.tile,
    required this.tileIcon,
    required this.snack,
    required this.parts,
  });

  // Brand values of the app icon.
  static const navy = Color(0xFF1E2A6E);
  static const gold = Color(0xFFF2C12E);
  static const beak = Color(0xFFE39A1C);

  final Color tint, onTint;
  final Color background, surface, surfaceRaised;
  final Color label, secondaryLabel, tertiaryLabel, separator;
  final Color nowFill, onNow, nowWash;
  final Color attention, attentionWash;
  final Color destructive;
  /// Current bar on the score: fill, outline and the moving playhead line.
  final Color markFill, markLine, playhead;
  /// Library row artwork.
  final Color tile, tileIcon;
  final Color snack;
  /// Part identification: soprano, alto, tenor, bass, piano.
  final PartPalette parts;

  static OtotoriColors of(BuildContext context) => Theme.of(context).extension<OtotoriColors>()!;

  @override
  OtotoriColors copyWith() => this;

  @override
  OtotoriColors lerp(OtotoriColors? other, double t) => t < 0.5 || other == null ? this : other;
}

const _lightParts = PartPalette(soprano: Color(0xFFCF4A62), alto: Color(0xFF8459C4),
  tenor: Color(0xFF23896A), bass: Color(0xFF3567C8), piano: Color(0xFF6B7290));
const _darkParts = PartPalette(soprano: Color(0xFFF07C90), alto: Color(0xFFB394F0),
  tenor: Color(0xFF5CC9A2), bass: Color(0xFF7FA6F5), piano: Color(0xFFA3A9C9));

/// A selectable color set (設定 › カラー).
class OtotoriPalette {
  const OtotoriPalette(this.id, this.name, this.description, this.light, this.dark);
  final String id, name, description;
  final OtotoriColors light, dark;
  OtotoriColors of(Brightness b) => b == Brightness.light ? light : dark;

  // 'otori' is the id saved before the app name was corrected to ototori.
  static OtotoriPalette byId(String? id) => all.firstWhere((p) => p.id == (id == 'otori' ? 'ototori' : id), orElse: () => all.first);

  static const all = [ototori, contrast, midori, sakura];

  /// The app icon: navy and gold. Dark mode inverts it.
  static const ototori = OtotoriPalette('ototori', '音鳥', 'アイコンの紺と金', OtotoriColors(
    tint: OtotoriColors.navy, onTint: Colors.white,
    background: Color(0xFFF4F5FA), surface: Colors.white, surfaceRaised: Colors.white,
    label: Color(0xFF141A3C), secondaryLabel: Color(0xFF5B6283), tertiaryLabel: Color(0xFF9398B3), separator: Color(0xFFDADDEA),
    nowFill: OtotoriColors.gold, onNow: OtotoriColors.navy, nowWash: Color(0x40F2C12E),
    attention: Color(0xFFB86E00), attentionWash: Color(0xFFFDF0D9), destructive: Color(0xFFD13438),
    markFill: Color(0x38F2C12E), markLine: OtotoriColors.beak, playhead: OtotoriColors.navy,
    tile: OtotoriColors.navy, tileIcon: OtotoriColors.gold, snack: OtotoriColors.navy, parts: _lightParts,
  ), OtotoriColors(
    tint: OtotoriColors.gold, onTint: OtotoriColors.navy,
    background: Color(0xFF0D1230), surface: Color(0xFF182052), surfaceRaised: Color(0xFF222B63),
    label: Color(0xFFF2F3FA), secondaryLabel: Color(0xFFA3A9C9), tertiaryLabel: Color(0xFF6E76A0), separator: Color(0xFF2E3870),
    nowFill: OtotoriColors.gold, onNow: OtotoriColors.navy, nowWash: Color(0x40F2C12E),
    attention: Color(0xFFF0AE45), attentionWash: Color(0xFF3A2E1A), destructive: Color(0xFFFF6B6B),
    markFill: Color(0x38F2C12E), markLine: OtotoriColors.beak, playhead: OtotoriColors.navy,
    tile: Color(0xFF2B3780), tileIcon: OtotoriColors.gold, snack: Color(0xFF222B63), parts: _darkParts,
  ));

  /// Black text on white, strong blue controls, a highlighter-yellow bar
  /// and a red playhead: the easiest to read in a bright rehearsal room.
  static const contrast = OtotoriPalette('contrast', 'くっきり', '文字と線を濃くした見やすい配色', OtotoriColors(
    tint: Color(0xFF0040DD), onTint: Colors.white,
    background: Color(0xFFF2F2F7), surface: Colors.white, surfaceRaised: Colors.white,
    label: Colors.black, secondaryLabel: Color(0xFF3A3A44), tertiaryLabel: Color(0xFF6C6C78), separator: Color(0xFFB8B8C2),
    nowFill: Color(0xFF0040DD), onNow: Colors.white, nowWash: Color(0x330040DD),
    attention: Color(0xFFA34700), attentionWash: Color(0xFFFFEAD6), destructive: Color(0xFFC00018),
    markFill: Color(0x66FFE14D), markLine: Colors.black, playhead: Color(0xFFD00020),
    tile: Color(0xFF0040DD), tileIcon: Colors.white, snack: Color(0xFF1C1C1E), parts: _lightParts,
  ), OtotoriColors(
    tint: Color(0xFF5AA9FF), onTint: Colors.black,
    background: Colors.black, surface: Color(0xFF1C1C1E), surfaceRaised: Color(0xFF2C2C2E),
    label: Colors.white, secondaryLabel: Color(0xFFD1D1D6), tertiaryLabel: Color(0xFF9A9AA2), separator: Color(0xFF48484A),
    nowFill: Color(0xFF5AA9FF), onNow: Colors.black, nowWash: Color(0x335AA9FF),
    attention: Color(0xFFFFB340), attentionWash: Color(0xFF3A2A10), destructive: Color(0xFFFF6961),
    markFill: Color(0x66FFE14D), markLine: Colors.black, playhead: Color(0xFFD00020),
    tile: Color(0xFF5AA9FF), tileIcon: Colors.black, snack: Color(0xFF2C2C2E), parts: _darkParts,
  ));

  static const midori = OtotoriPalette('midori', 'みどり', '目にやさしい深緑', OtotoriColors(
    tint: Color(0xFF1E6B47), onTint: Colors.white,
    background: Color(0xFFF2F6F3), surface: Colors.white, surfaceRaised: Colors.white,
    label: Color(0xFF14261C), secondaryLabel: Color(0xFF4E6357), tertiaryLabel: Color(0xFF8FA096), separator: Color(0xFFD6E0DA),
    nowFill: Color(0xFFF5B83D), onNow: Color(0xFF1E3326), nowWash: Color(0x40F5B83D),
    attention: Color(0xFFB25E00), attentionWash: Color(0xFFFCEFD9), destructive: Color(0xFFCC3333),
    markFill: Color(0x40F5B83D), markLine: Color(0xFFD08A00), playhead: Color(0xFF1E6B47),
    tile: Color(0xFF1E6B47), tileIcon: Color(0xFFF5B83D), snack: Color(0xFF1E3326), parts: _lightParts,
  ), OtotoriColors(
    tint: Color(0xFF7FD3A5), onTint: Color(0xFF0E2016),
    background: Color(0xFF0D1A13), surface: Color(0xFF16271D), surfaceRaised: Color(0xFF1F3428),
    label: Color(0xFFEFF5F1), secondaryLabel: Color(0xFFA3B9AC), tertiaryLabel: Color(0xFF6F8679), separator: Color(0xFF2A4235),
    nowFill: Color(0xFFF5B83D), onNow: Color(0xFF1E3326), nowWash: Color(0x40F5B83D),
    attention: Color(0xFFF0AE45), attentionWash: Color(0xFF3A2E1A), destructive: Color(0xFFFF7A7A),
    markFill: Color(0x40F5B83D), markLine: Color(0xFFD08A00), playhead: Color(0xFF1E6B47),
    tile: Color(0xFF1E6B47), tileIcon: Color(0xFFF5B83D), snack: Color(0xFF1F3428), parts: _darkParts,
  ));

  static const sakura = OtotoriPalette('sakura', 'さくら', 'やわらかい桜色', OtotoriColors(
    tint: Color(0xFFB0305A), onTint: Colors.white,
    background: Color(0xFFFAF3F5), surface: Colors.white, surfaceRaised: Colors.white,
    label: Color(0xFF2B141C), secondaryLabel: Color(0xFF6E4E59), tertiaryLabel: Color(0xFFA88E97), separator: Color(0xFFEAD9DF),
    nowFill: Color(0xFFF4A3BC), onNow: Color(0xFF4A1023), nowWash: Color(0x40F4A3BC),
    attention: Color(0xFFB25E00), attentionWash: Color(0xFFFCEFD9), destructive: Color(0xFFC62828),
    markFill: Color(0x40F48FB1), markLine: Color(0xFFB0305A), playhead: Color(0xFF4A1023),
    tile: Color(0xFFB0305A), tileIcon: Colors.white, snack: Color(0xFF4A1023), parts: _lightParts,
  ), OtotoriColors(
    tint: Color(0xFFF5A3BE), onTint: Color(0xFF3A0D1C),
    background: Color(0xFF1B0F14), surface: Color(0xFF2A1820), surfaceRaised: Color(0xFF36212B),
    label: Color(0xFFF8EEF2), secondaryLabel: Color(0xFFC9AEB8), tertiaryLabel: Color(0xFF8E727C), separator: Color(0xFF46303A),
    nowFill: Color(0xFFF5A3BE), onNow: Color(0xFF3A0D1C), nowWash: Color(0x40F5A3BE),
    attention: Color(0xFFF0AE45), attentionWash: Color(0xFF3A2E1A), destructive: Color(0xFFFF7A7A),
    markFill: Color(0x40F48FB1), markLine: Color(0xFFB0305A), playhead: Color(0xFF4A1023),
    tile: Color(0xFFB0305A), tileIcon: Colors.white, snack: Color(0xFF36212B), parts: _darkParts,
  ));
}

@immutable
class PartPalette {
  const PartPalette({required this.soprano, required this.alto, required this.tenor,
    required this.bass, required this.piano});
  final Color soprano, alto, tenor, bass, piano;

  /// Color for a part by its name (Soprano, Alto I, テノール, Bass…).
  Color forPart(String id, String name) {
    if (id == 'piano') return piano;
    final n = name.toLowerCase();
    if (n.startsWith('s') || n.contains('ソプラノ') || n.contains('mezzo') || n.contains('メゾ')) return soprano;
    if (n.startsWith('a') || n.contains('アルト') || n.startsWith('c')) return alto;
    if (n.startsWith('t') || n.contains('テノール') || n.contains('テナー')) return tenor;
    if (n.startsWith('b') || n.contains('バス') || n.contains('バリトン')) return bass;
    return piano;
  }
}

/// Short badge text for a part: S, A2, T1, Br, Pf…
String partAbbreviation(String id, String name) {
  if (id == 'piano') return 'Pf';
  final n = name.trim();
  final lower = n.toLowerCase();
  final number = RegExp(r'(\d+|I{1,3}|IV)\s*$').firstMatch(n)?.group(1);
  final suffix = switch (number) { null => '', 'I' => '1', 'II' => '2', 'III' => '3', 'IV' => '4', final d => d };
  String base;
  if (lower.startsWith('mezzo') || n.startsWith('メゾ')) { base = 'Mz'; }
  else if (lower.startsWith('bari') || n.startsWith('バリトン')) { base = 'Br'; }
  else if (lower.startsWith('sop') || n.startsWith('ソプラノ')) { base = 'S'; }
  else if (lower.startsWith('alt') || n.startsWith('アルト')) { base = 'A'; }
  else if (lower.startsWith('ten') || n.startsWith('テノール') || n.startsWith('テナー')) { base = 'T'; }
  else if (lower.startsWith('bas') || n.startsWith('バス')) { base = 'B'; }
  else { base = n.isEmpty ? '?' : n.characters.first.toUpperCase(); }
  return '$base$suffix';
}

/// HIG-like type ramp. Sizes are a touch smaller than iOS points because
/// Japanese glyphs read larger than Latin at the same size.
TextTheme _textTheme(Color label, Color secondary) => TextTheme(
  // Large Title
  headlineLarge: TextStyle(fontSize: 32, fontWeight: FontWeight.w700, height: 1.2, color: label, letterSpacing: 0.2),
  // Title 1 / 2 / 3
  headlineMedium: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, height: 1.25, color: label),
  headlineSmall: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, height: 1.3, color: label),
  titleLarge: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, height: 1.3, color: label),
  // Headline
  titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, height: 1.4, color: label),
  // Subheadline
  titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, height: 1.4, color: label),
  // Body / Callout / Footnote
  bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, height: 1.5, color: label),
  bodyMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w400, height: 1.5, color: label),
  bodySmall: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, height: 1.45, color: secondary),
  labelLarge: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, height: 1.3, color: label),
  labelMedium: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, height: 1.3, color: secondary),
  // Caption
  labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, height: 1.3, color: secondary),
);

ThemeData ototoriTheme(Brightness brightness, [OtotoriPalette palette = OtotoriPalette.ototori]) {
  final c = palette.of(brightness);
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.tint,
    onPrimary: c.onTint,
    primaryContainer: c.nowWash,
    onPrimaryContainer: c.label,
    secondary: c.nowFill,
    onSecondary: c.onNow,
    secondaryContainer: c.nowWash,
    onSecondaryContainer: c.label,
    tertiary: c.attention,
    onTertiary: Colors.white,
    error: c.destructive,
    onError: Colors.white,
    surface: c.surface,
    onSurface: c.label,
    onSurfaceVariant: c.secondaryLabel,
    surfaceContainerLowest: c.background,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface,
    surfaceContainerHigh: c.surfaceRaised,
    surfaceContainerHighest: c.surfaceRaised,
    outline: c.tertiaryLabel,
    outlineVariant: c.separator,
  );
  final text = _textTheme(c.label, c.secondaryLabel);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    canvasColor: c.background,
    textTheme: text,
    extensions: [c],
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: DividerThemeData(color: c.separator, thickness: 0.5, space: 0.5),
    appBarTheme: AppBarTheme(
      backgroundColor: c.background,
      surfaceTintColor: Colors.transparent,
      foregroundColor: c.label,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
    ),
    // HIG tab bar: tint-only selection, small labels, no pill indicator.
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      height: 62,
      elevation: 0,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
        size: 26, color: states.contains(WidgetState.selected) ? c.tint : c.tertiaryLabel)),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => text.labelSmall!.copyWith(
        color: states.contains(WidgetState.selected) ? c.tint : c.tertiaryLabel)),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: c.surface,
      indicatorColor: Colors.transparent,
      selectedIconTheme: IconThemeData(color: c.tint, size: 26),
      unselectedIconTheme: IconThemeData(color: c.tertiaryLabel, size: 26),
      selectedLabelTextStyle: text.labelSmall!.copyWith(color: c.tint),
      unselectedLabelTextStyle: text.labelSmall!.copyWith(color: c.tertiaryLabel),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      backgroundColor: c.tint, foregroundColor: c.onTint,
      minimumSize: const Size(64, 50),
      textStyle: text.titleMedium,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      foregroundColor: c.tint, minimumSize: const Size(44, 44),
      side: BorderSide(color: c.separator),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    )),
    textButtonTheme: TextButtonThemeData(style: TextButton.styleFrom(
      foregroundColor: c.tint, minimumSize: const Size(44, 44), textStyle: text.labelLarge)),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(
      foregroundColor: c.tint, minimumSize: const Size(44, 44))),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.tint, foregroundColor: c.onTint,
      extendedTextStyle: text.titleMedium!.copyWith(color: c.onTint),
      shape: const StadiumBorder(), elevation: 2, highlightElevation: 4),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.onTint : c.surface),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? c.tint : c.separator),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: c.tint,
      inactiveTrackColor: c.separator,
      thumbColor: c.tint,
      overlayColor: c.tint.withValues(alpha: 0.12),
      trackHeight: 4,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(style: SegmentedButton.styleFrom(
      selectedBackgroundColor: c.tint, selectedForegroundColor: c.onTint,
      foregroundColor: c.label, side: BorderSide(color: c.separator),
      minimumSize: const Size(44, 40), visualDensity: VisualDensity.compact)),
    chipTheme: ChipThemeData(
      backgroundColor: c.surface,
      selectedColor: c.tint,
      labelStyle: text.labelLarge,
      secondaryLabelStyle: text.labelLarge!.copyWith(color: c.onTint),
      side: BorderSide(color: c.separator),
      shape: const StadiumBorder(),
      showCheckmark: false,
    ),
    listTileTheme: ListTileThemeData(
      tileColor: c.surface,
      iconColor: c.secondaryLabel,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall,
      minVerticalPadding: 10,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.background,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: c.tertiaryLabel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
    ),
    dialogTheme: DialogThemeData(backgroundColor: c.surfaceRaised, surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
    popupMenuTheme: PopupMenuThemeData(color: c.surfaceRaised, surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating,
      backgroundColor: c.snack,
      contentTextStyle: text.bodyMedium!.copyWith(color: Colors.white),
      actionTextColor: brightness == Brightness.light ? c.nowFill : c.tint,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: c.surface,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c.separator)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c.separator)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: c.tint, width: 1.5)),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.tint, linearTrackColor: c.separator),
  );
}
