import 'omr_bridge.dart';

/// The opening metronome mark (♩ = ca. 92) read from the printed text (the
/// same OCR as the part names, first pages only).
///
/// ML Kit reads the note glyph as "J" (sometimes "d" or nothing) and "ca." as
/// "ca", "ca," or "Cn、", so the mark is recognised by its shape: a note
/// glyph or "=" or "ca." directly before a number of 30–240. Only the first
/// mark counts (later marks are tempo changes, not handled yet).
class TempoMark {
  const TempoMark({required this.bpm, required this.printed, required this.unit, required this.text,
    required this.page, this.assumedUnit = false});
  /// Quarter notes per minute (the unit of `tempo_bpm`).
  final double bpm;
  final int printed;
  /// 'quarter', 'dotted-quarter' or 'eighth'.
  final String unit;
  final String text;
  final int page;
  /// The unit was not printed legibly and comes from the time signature.
  final bool assumedUnit;

  Map<String, dynamic> toJson() => {
    'bpm': bpm, 'printed': printed, 'unit': unit, 'text': text, 'page': page,
    'unit_from_time_signature': assumedUnit, 'source': 'ocr',
  };
}

const _glyph = r'(?:[J♩]|(?<![A-Za-z])d)';
const _ca = r'c\s*[an]\s*[.,]';
final _patterns = [
  // J = ca. 92 / J- ca. 52 / J.=76 / J=120
  RegExp('($_glyph)\\s*(\\.)?\\s*[=\\-–—]\\s*(?:$_ca\\s*|ca\\s*)?(\\d{2,3})(?!\\d)', caseSensitive: false),
  // J ca, 108
  RegExp('($_glyph)\\s*(\\.)?\\s*$_ca\\s*(\\d{2,3})(?!\\d)', caseSensitive: false),
  // .-76 (♩.=76 with the note lost, its dot kept)
  RegExp('()(?:^|\\s)(\\.)\\s*[=\\-–—]\\s*(?:$_ca\\s*|ca\\s*)?(\\d{2,3})(?!\\d)', caseSensitive: false),
  // =ca.72 (glyph lost)
  RegExp('()()=\\s*(?:$_ca\\s*|ca\\s*)?(\\d{2,3})(?!\\d)', caseSensitive: false),
  // ca. 120 / Cn、108 (glyph and "=" lost)
  RegExp('()()(?<![A-Za-z])$_ca\\s*(\\d{2,3})(?!\\d)', caseSensitive: false),
];

String _normalize(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    if (rune >= 0xFF10 && rune <= 0xFF19) { out.writeCharCode(rune - 0xFF10 + 0x30); continue; }
    out.write(switch (rune) { 0xFF1D => '=', 0x3001 || 0xFF0C => ',', 0xFF0E || 0x3002 => '.', _ => String.fromCharCode(rune) });
  }
  return out.toString();
}

/// (printed number, glyph seen, dot seen) of the first mark in [text].
(int, bool, bool)? parseTempoText(String text) {
  final t = _normalize(text);
  (int, int, bool, bool)? best;
  for (final pattern in _patterns) {
    for (final m in pattern.allMatches(t)) {
      final n = int.parse(m.group(3)!);
      if (n < 30 || n > 240) continue;
      if (best == null || m.start < best.$1) {
        best = (m.start, n, (m.group(1) ?? '').isNotEmpty, (m.group(2) ?? '').isNotEmpty);
      }
    }
  }
  return best == null ? null : (best.$2, best.$3, best.$4);
}

/// The first metronome mark on the first pages with staves, or null.
/// [timeSig] is the opening time signature: in 6/8, 9/8 and 12/8 the beat is
/// a dotted quarter, which OCR often reads without its dot.
TempoMark? tempoFromLabels(List<RecognizedPageSymbols> pages, (int, int) timeSig) {
  for (var p = 0; p < pages.length; p++) {
    final page = pages[p];
    if (page.labels.isEmpty || page.staves.isEmpty) continue;
    final bottom = page.staves.map((s) => s.crop[3]).reduce((a, b) => a > b ? a : b);
    final found = <(int, RecognizedTextLabel, (int, bool, bool))>[];
    for (final label in page.labels) {
      if (label.bounds[1] > bottom) continue; // footers, copyright lines
      final parsed = parseTempoText(label.text);
      if (parsed != null) found.add((label.bounds[1], label, parsed));
    }
    if (found.isEmpty) continue;
    found.sort((a, b) => a.$1.compareTo(b.$1));
    final (_, label, (n, _, dotted)) = found.first;
    final compound = timeSig.$2 == 8 && timeSig.$1 % 3 == 0 && timeSig.$1 >= 6;
    final String unit;
    if (dotted) {
      unit = 'dotted-quarter';
    } else if (compound) {
      unit = n >= 150 ? 'eighth' : 'dotted-quarter';
    } else {
      unit = 'quarter';
    }
    final bpm = switch (unit) { 'dotted-quarter' => n * 1.5, 'eighth' => n / 2, _ => n.toDouble() };
    return TempoMark(bpm: bpm, printed: n, unit: unit, text: label.text, page: page.pageNumber ?? p + 1,
      assumedUnit: !dotted && compound);
  }
  return null;
}

String tempoUnitSymbol(String unit) => switch (unit) { 'dotted-quarter' => '♩.', 'eighth' => '♪', _ => '♩' };
