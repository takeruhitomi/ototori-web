import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/browser_assembly.dart';
import 'package:choir_mobile/grand_staff_timing.dart';
import 'package:choir_mobile/omr_bridge.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:flutter_test/flutter_test.dart';

// Full on-device assembly from exported Android recognition pages.
// MOBILE_PARITY_PAGES=<comparison dir with android300/<song>/recognized-pages.json>
// MOBILE_PARITY_OUT=<output dir>; writes <song><suffix>.json.
void main() {
  final dir = Platform.environment['MOBILE_PARITY_PAGES'];
  final out = Platform.environment['MOBILE_PARITY_OUT'];
  final suffix = Platform.environment['MOBILE_PARITY_SUFFIX'] ?? '.dart-pages';
  test('recognised pages assemble like the browser version', () {
    grandStaffTimingEnabled = Platform.environment['MOBILE_PARITY_NO_GST'] == null;    final reasons = <String, int>{};
    if (Platform.environment['MOBILE_PARITY_GST_DEBUG'] != null) {
      var shown = 0;
      grandStaffDebug = (r) {
        reasons[r.split(' R=').first] = (reasons[r.split(' R=').first] ?? 0) + 1;
        // ignore: avoid_print
        if (r.contains('\n') && shown++ < 40) print(r);
      };
    }
    addTearDown(() {
      // ignore: avoid_print
      if (reasons.isNotEmpty) print('grand staff: $reasons');
    });
    for (final song in Directory('$dir/android300').listSync().whereType<Directory>()) {
      final name = song.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final file = File('${song.path}/recognized-pages.json');
      if (!file.existsSync()) continue;
      final values = jsonDecode(file.readAsStringSync()) as List;
      // Part-name OCR exported by the emulator run (MOBILE_PARITY_NO_LABELS skips it).
      final labelFile = File('${song.path}/native-labels.json');
      final labels = labelFile.existsSync() && Platform.environment['MOBILE_PARITY_NO_LABELS'] == null
          ? jsonDecode(labelFile.readAsStringSync()) as List : const [];
      final pages = [for (var p = 0; p < values.length; p++)
        _page(values[p] as Map, p, p < labels.length ? labels[p] as Map : null)];
      try {
        final result = assembleLikeBrowser(pages);
        File('$out/$name$suffix.json').writeAsStringSync(jsonEncode(result.json));
        // ignore: avoid_print
        print('$name: ${result.score.measureCount()} measures, ${result.score.meta['ensemble']}, '
          '${result.score.meta['voice_names']} (${result.score.meta['voice_names_source'] ?? 'clefs'})');
      } on FormatException catch (e) {
        // ignore: avoid_print
        print('$name: FAILED ${e.message}');
      }
    }
  }, skip: dir == null || out == null ? 'Set MOBILE_PARITY_PAGES and MOBILE_PARITY_OUT' : false);
}

RecognizedPageSymbols _page(Map value, int index, Map? labels) {
  final staves = [for (final s in value['staves'] as List) RecognizedStaffSymbols(
    symbols: [for (final v in s['symbols'] as List) OmrSymbol.fromList(v as List)],
    reachedEos: s['reachedEos'] as bool, crop: (s['crop'] as List).cast<int>(),
    lines: [for (final l in s['lines'] as List? ?? []) (l as num).toDouble()],
    left: s['left'] as int?, right: s['right'] as int?)];
  return RecognizedPageSymbols(staves: withPlaces(staves, value['places']), warnings: (value['warnings'] as List).cast<String>(),
    width: value['width'] as int, height: value['height'] as int, pageNumber: index + 1,
    labels: [for (final l in labels?['labels'] as List? ?? const [])
      RecognizedTextLabel((l as Map)['text'] as String, (l['bounds'] as List).cast<int>())],
    systems: parseSystemLayouts(value['systems'], staves.length));
}
