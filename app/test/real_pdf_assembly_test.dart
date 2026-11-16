import 'dart:convert';
import 'dart:io';
import 'package:choir_mobile/omr_bridge.dart';
import 'package:choir_mobile/browser_assembly.dart';
import 'package:choir_mobile/omr_symbols.dart';
import 'package:choir_mobile/score_structure.dart' show EnsembleLayout;
import 'package:choir_mobile/score.dart';
import 'package:choir_mobile/playback_timeline.dart';
import 'package:choir_mobile/midi_export.dart';
import 'package:choir_mobile/musicxml_export.dart';
import 'package:flutter_test/flutter_test.dart';

// Real user scores remain outside the repository. Export model symbols from
// the emulator's debug harness and opt in with MOBILE_RECOGNIZED_PAGES.
void main() {
  final source = Platform.environment['MOBILE_RECOGNIZED_PAGES'];
  test('real multi-page symbols assemble into a validated playable score', () {
    final values = jsonDecode(File(source!).readAsStringSync()) as List;
    final labelSource = Platform.environment['MOBILE_RECOGNIZED_LABELS'];
    final labels = labelSource == null ? null : jsonDecode(File(labelSource).readAsStringSync()) as List;
    final pages = [for (var page = 0; page < values.length; page++) RecognizedPageSymbols(
      staves: (values[page]['staves'] as List).map((s) => RecognizedStaffSymbols(
        symbols: (s['symbols'] as List).map((v) => OmrSymbol.fromList(v as List)).toList(),
        reachedEos: s['reachedEos'] as bool, crop: (s['crop'] as List).cast<int>(),
        lines: [for (final line in s['lines'] as List? ?? []) (line as num).toDouble()],
        left: s['left'] as int?, right: s['right'] as int?,
      )).toList(), warnings: (values[page]['warnings'] as List).cast<String>(),
      width: values[page]['width'] as int, height: values[page]['height'] as int,
      pageNumber: page + 1,
      labels: [for (final label in labels?[page] as List? ?? [])
        RecognizedTextLabel(label['text'] as String, (label['bounds'] as List).cast<int>())],
      systems: parseSystemLayouts(values[page]['systems'], (values[page]['staves'] as List).length),
    )];
    expect(pages.length, greaterThan(1));
    final voiceConfig = Platform.environment['MOBILE_VOICE_NAMES'];
    final voiceNames = voiceConfig == null ? ['Soprano', 'Alto', 'Tenor', 'Bass']
        : (jsonDecode(voiceConfig) as List).cast<String>();
    final output = Platform.environment['MOBILE_ASSEMBLED_SCORE'];
    final diagnostics = {
      'physical_staves_by_page': [for (final page in pages) page.staves.length],
      'unfinished_staves_by_page': [for (final page in pages)
        page.staves.where((s) => !s.reachedEos).length],
      'recognition_warnings': [for (final page in pages) page.warnings],
    };
    if (output != null) {
      File('$output.layout.json').writeAsStringSync(jsonEncode(diagnostics));
    }
    // Production path: the browser-equivalent system grouping, structure and
    // post-processing (automatic ensemble, or the given voice names + piano).
    final automatic = Platform.environment['MOBILE_AUTO_ENSEMBLE'] == 'true';
    final result = assembleLikeBrowser(pages,
      layout: automatic ? EnsembleLayout() : EnsembleLayout(voiceNames: voiceNames, piano: true));
    final score = result.json;
    if (output != null) {
      File('$output.layout.json').writeAsStringSync(jsonEncode({
        ...diagnostics, 'voice_names': score['meta']['voice_names'], 'piano': score['meta']['piano'],
        'ensemble': score['meta']['ensemble'], 'warnings': score['warnings'],
        'systems_by_page': [for (final page in pages) page.systems?.map((s) => s.staves.length).toList()],
      }));
    }
    final document = ScoreDocument.parse(jsonEncode(score));
    final expectedCounts = Platform.environment['MOBILE_EXPECTED_PAGE_MEASURES'];
    if (expectedCounts != null) {
      final counts = (jsonDecode(expectedCounts) as List).cast<int>();
      expect(counts, hasLength(pages.length));
      for (final staff in document.data['staves'] as List) {
        final measures = staff['measures'] as List;
        expect(measures, hasLength(counts.reduce((a, b) => a + b)), reason: staff['name']);
        for (var page = 0; page < counts.length; page++) {
          expect(measures.where((m) => m['page'] == page + 1), hasLength(counts[page]),
            reason: '${staff['name']}, page ${page + 1}');
        }
      }
    }
    final project = document.encodeProject();
    final restored = ScoreDocument.fromProject(project);
    expect(restored.encode(), document.encode());
    expect(restored.identity.toJson(), document.identity.toJson());
    expect(utf8.encode(project).length, lessThanOrEqualTo(10000000));
    final timeline = PlaybackTimelineBuilder().build(document.data);
    final voiceCount = (score['meta']['voice_names'] as List).length;
    expect(document.staves, hasLength(voiceCount + (score['meta']['piano'] == true ? 2 : 0)));
    if (!automatic) expect(voiceCount, voiceNames.length);
    expect(timeline.notes, isNotEmpty);
    expect(timeline.events(tempo: 80), isNotEmpty);
    expect(timeline.notes.every((n) => n.start.isFinite && n.duration.isFinite && n.duration > 0), isTrue);
    if (output != null) {
      File(output).writeAsStringSync(document.encode());
      File('$output.xml.musicxml').writeAsStringSync(MusicXmlExporter().export(document.data));
      File('$output.xml.json').writeAsStringSync(document.encode());
      File('$output.midi.mid').writeAsBytesSync(MidiExporter().export(document.data));
      File('$output.midi.json').writeAsStringSync(jsonEncode({
        'tempo': document.data['tempo_bpm'],
        'total_beats': timeline.totalBeats, 'measure_starts': timeline.measureStarts, 'measure_order': timeline.order,
        'notes': [for (final n in timeline.notes)
          if (n.start < timeline.totalBeats)
            {'part': n.partId, 'pitch': n.pitch,
              'start': (n.start * MidiExporter.ticksPerBeat).round(),
              'end': ((n.start + n.duration).clamp(0, timeline.totalBeats) * MidiExporter.ticksPerBeat).round()}],
      }));
    }
    // This validates pipeline completion, not recognition accuracy.
  }, skip: source == null ? 'Set MOBILE_RECOGNIZED_PAGES to local exported model symbols' : false);
}
