import 'package:flutter/services.dart';
import 'omr_symbols.dart';

class RecognizedStaffSymbols {
  const RecognizedStaffSymbols({required this.symbols, required this.reachedEos, required this.crop,
    this.lines = const [], this.left, this.right});
  final List<OmrSymbol> symbols;
  final bool reachedEos;
  final List<int> crop;
  final List<double> lines;
  final int? left, right;
  double get centerY => lines.length == 5 ? lines[2] : (crop[1] + crop[3]) / 2;
  double get staffHeight => lines.length == 5 ? lines.last - lines.first : (crop[3] - crop[1]) / 3;
}

class RecognizedTextLabel {
  const RecognizedTextLabel(this.text, this.bounds);
  final String text;
  final List<int> bounds;
}

class RecognizedPageSymbols {
  const RecognizedPageSymbols({required this.staves, required this.warnings, required this.width, required this.height,
    this.labels = const [], this.pageNumber, this.systems});
  final List<RecognizedStaffSymbols> staves;
  final List<String> warnings;
  final int width, height;
  final List<RecognizedTextLabel> labels;
  final int? pageNumber;
  /// System grouping from the page image (staff indices sorted top to
  /// bottom); null when the native layout analysis is unavailable.
  final List<SystemLayout>? systems;

  RecognizedPageSymbols withPageNumber(int number) => RecognizedPageSymbols(staves: staves, warnings: warnings,
    width: width, height: height, labels: labels, pageNumber: number, systems: systems);
}

/// Image evidence for one system of a page (from the native layout
/// analysis). Indices refer to the page's staves sorted top to bottom;
/// [pianoPair] and [pianoExtra] are indices within [staves].
class SystemLayout {
  const SystemLayout(this.staves, {this.pianoPair, this.hasBrace = false, this.pianoExtra});
  final List<int> staves;
  final (int, int)? pianoPair;
  final bool hasBrace;
  final int? pianoExtra;
}

/// Parses the native `systems` list: [{staves: [..], piano_pair: [a, b]?, has_brace, piano_extra?}].
/// Staves in no system were rejected by the layout analysis (show-through,
/// cue staves) and are not assembled.
List<SystemLayout>? parseSystemLayouts(Object? value, int staffCount) {
  if (value is! List) return null;
  final out = <SystemLayout>[];
  final seen = <int>{};
  for (final item in value) {
    if (item is! Map) return null;
    final staves = [for (final s in item['staves'] as List? ?? const []) s as int];
    if (staves.isEmpty || staves.any((s) => s < 0 || s >= staffCount || !seen.add(s))) return null;
    final pair = (item['piano_pair'] as List?)?.cast<int>();
    out.add(SystemLayout(staves,
      pianoPair: pair != null && pair.length == 2 ? (pair[0], pair[1]) : null,
      hasBrace: item['has_brace'] == true, pianoExtra: item['piano_extra'] as int?));
  }
  return out;
}

/// Android adapter for the offline recognition pipeline. A PDF must first be
/// selected with the existing PDF adapter. The result is model symbols, not a
/// complete score; callers must assemble and validate parts before playback.
class OmrBridge {
  const OmrBridge();
  static const _channel = MethodChannel('jp.choiromr.mobile/omr');

  Future<bool> modelsReady() async => await _channel.invokeMethod<bool>('modelsReady') ?? false;
  Future<bool> importModels() async => await _channel.invokeMethod<bool>('importModels') ?? false;
  Future<void> cancel({String? jobId}) => _channel.invokeMethod<void>('cancel', {'jobId': jobId});

  Future<RecognizedPageSymbols> readLabels(RecognizedPageSymbols page, int index) async {
    final data = await _channel.invokeMapMethod<Object?, Object?>('readPageLabels', {'page': index});
    if (data == null) throw const FormatException('声部名の読み取り結果がありません。');
    try {
      final labels = (data['labels'] as List).map((value) {
        final bounds = (value['bounds'] as List).cast<int>();
        if (bounds.length != 4 || bounds[2] <= bounds[0] || bounds[3] <= bounds[1]) throw const FormatException('声部名の位置が不正です。');
        return RecognizedTextLabel(value['text'] as String, bounds);
      }).toList();
      return RecognizedPageSymbols(staves: page.staves, warnings: [...page.warnings, ...(data['warnings'] as List).cast<String>()],
        width: page.width, height: page.height, labels: labels, pageNumber: index + 1, systems: page.systems);
    } on TypeError { throw const FormatException('声部名の読み取り形式が不正です。'); }
  }

  /// Pages whose printed text is read for part names: the cover ("男声合唱")
  /// and the first music pages, where the first system names the parts.
  static const labelPages = 3;

  /// System sizes (staves per system) seen on the pages read so far in this
  /// pass; restarted at page 0. See [recognizePage].
  static final _sizesSeen = <int, int>{};

  /// Recognised page plus the printed text (OCR, cached natively): part
  /// names and the tempo mark. Read for the first [labelPages] pages, and
  /// for a later page whose systems differ in size from those seen so far
  /// (a solo staff joins: its name is printed there). The text only names
  /// parts and sets the tempo, so an OCR failure keeps the page without it.
  Future<RecognizedPageSymbols> recognizePage({required int page, required int dpi}) async {
    final symbols = await _recognizePage(page: page, dpi: dpi);
    if (page == 0) _sizesSeen.clear();
    final sizes = [for (final s in symbols.systems ?? const <SystemLayout>[]) s.staves.length];
    final usual = _sizesSeen.isEmpty ? null : _sizesSeen.entries.reduce((a, b) => b.value > a.value ? b : a).key;
    final changed = usual != null && sizes.any((n) => n > usual);
    for (final n in sizes) { _sizesSeen[n] = (_sizesSeen[n] ?? 0) + 1; }
    if (page >= labelPages && !changed) return symbols;
    try {
      final labelled = await readLabels(symbols, page);
      return RecognizedPageSymbols(staves: symbols.staves, warnings: symbols.warnings, width: symbols.width,
        height: symbols.height, labels: labelled.labels, pageNumber: symbols.pageNumber, systems: symbols.systems);
    } on PlatformException {
      return symbols;
    } on FormatException {
      return symbols;
    }
  }

  Future<RecognizedPageSymbols> _recognizePage({required int page, required int dpi}) async {
    if (page < 0 || (dpi != 300 && dpi != 400)) throw ArgumentError('Invalid page or DPI');
    final data = await _channel.invokeMapMethod<Object?, Object?>('recognizePage', {'page': page, 'dpi': dpi});
    if (data == null) throw const FormatException('認識結果が空です。');
    try {
      final staves = (data['staves'] as List).map((item) {
        final map = item as Map;
        final crop = (map['crop'] as List).cast<int>();
        if (crop.length != 4 || crop[2] <= crop[0] || crop[3] <= crop[1]) throw const FormatException('五線の範囲が不正です。');
        return RecognizedStaffSymbols(
          symbols: (map['symbols'] as List).map((v) => OmrSymbol.fromList(v as List)).toList(),
          reachedEos: map['reachedEos'] as bool,
          crop: List<int>.unmodifiable(crop),
          lines: (map['lines'] as List? ?? []).map((v) => (v as num).toDouble()).toList(),
          left: map['left'] as int?, right: map['right'] as int?,
        );
      }).toList();
      final width = data['width'] as int;
      final height = data['height'] as int;
      if (width <= 0 || height <= 0) throw const FormatException('ページのサイズが不正です。');
      return RecognizedPageSymbols(staves: withPlaces(staves, data['places']), warnings: (data['warnings'] as List).cast<String>(),
        width: width, height: height, pageNumber: page + 1, systems: parseSystemLayouts(data['systems'], staves.length));
    } on TypeError {
      throw const FormatException('認識結果の形式が不正です。');
    }
  }
}

/// Attaches the native token positions (`places`: per staff, per token) to
/// the symbols. Positions are optional: a missing or malformed list leaves
/// the staff as it is (older pages, staves recognised without attention x).
List<RecognizedStaffSymbols> withPlaces(List<RecognizedStaffSymbols> staves, Object? places) {
  if (places is! List || places.length != staves.length) return staves;
  return [
    for (var i = 0; i < staves.length; i++)
      if (places[i] is List && (places[i] as List).length == staves[i].symbols.length)
        RecognizedStaffSymbols(
          symbols: [
            for (var j = 0; j < staves[i].symbols.length; j++)
              staves[i].symbols[j].withPlace(SymbolPlace.tryParse((places[i] as List)[j])),
          ],
          reachedEos: staves[i].reachedEos, crop: staves[i].crop, lines: staves[i].lines,
          left: staves[i].left, right: staves[i].right)
      else staves[i],
  ];
}
