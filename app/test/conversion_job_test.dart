import 'dart:convert';
import 'package:choir_mobile/conversion_job.dart';
import 'package:choir_mobile/app/convert_tab.dart';
import 'package:choir_mobile/app/conversion.dart';
import 'support/harness.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> settings() => {'source_hash': 'b' * 64, 'name': 'Resume PDF', 'dpi': 400,
  'pages': 1, 'selected_page': 0, 'all_pages': true, 'piano': false, 'voice_names': ['Alto'], 'auto_ensemble': false};

void main() {
  test('restores settings and progress and rejects invalid records', () {
    final input = {'version': 1, 'settings': settings(), 'status': 'running', 'completed_pages': [0], 'error': null};
    final restored = ConversionJob.restore('existing-id', jsonEncode(input));
    expect(restored.id, 'existing-id'); expect(restored.completedPages, {0});
    expect(restored.signature, ConversionJob(settings()).signature);
    input['completed_pages'] = [1];
    expect(() => ConversionJob.restore('existing-id', jsonEncode(input)), throwsFormatException);
    expect(() => ConversionJob({...settings(), 'source_hash': '../source'}), throwsFormatException);
    expect(() => ConversionJob({...settings(), 'voice_names': []}), throwsFormatException);
    expect(() => ConversionJob({...settings(), 'dpi': 400.0}), throwsFormatException);
  });

  for (final changeSettings in [false, true]) {
  testWidgets(changeSettings ? 'creates a new job when the restored ensemble is changed' : 'restores the imported PDF and settings and resumes the same conversion', (tester) async {
    const pdf = MethodChannel('jp.choiromr.mobile/pdf');
    const omr = MethodChannel('jp.choiromr.mobile/omr');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final saved = <Map>[];
    messenger.setMockMethodCallHandler(pdf, (call) async {
      switch (call.method) {
        case 'listConversions': return [{'id': 'existing-id', 'name': 'Resume PDF', 'status': 'running', 'completed': 0}];
        case 'loadConversion': return jsonEncode({'version': 1, 'settings': settings(), 'status': 'running', 'completed_pages': [], 'error': null});
        case 'openSourcePdf':
          expect(call.arguments, {'hash': 'b' * 64, 'pages': 1});
          return {'sourceHash': 'b' * 64, 'pages': 1};
        case 'saveConversion':
          expect((call.arguments as Map)['id'], changeSettings ? (saved.isEmpty ? null : 'new-id') : 'existing-id');
          saved.add(jsonDecode((call.arguments as Map)['text'] as String) as Map);
          return changeSettings ? 'new-id' : 'existing-id';
        case 'startNativeConversion': return null;
        case 'nativeConversionState': return {'active': false, 'text': jsonEncode({
          'version': 1, 'settings': saved.isEmpty ? settings() : saved.last['settings'],
          'status': 'recognized', 'completed_pages': [0], 'error': null,
        })};
      }
      throw StateError('Unexpected ${call.method}');
    });
    messenger.setMockMethodCallHandler(omr, (call) async {
      if (call.method == 'modelsReady') return true;
      expect(call.method, 'recognizePage');
      expect(call.arguments, {'page': 0, 'dpi': 400});
      return {'width': 100, 'height': 100, 'warnings': [], 'staves': [
        {'crop': [0, 0, 100, 50], 'reachedEos': true, 'symbols': [['note_4', 'C4', '_', 'upper', '_', '_']]}
      ]};
    });
    const scoreChannel = MethodChannel('jp.choiromr.mobile/score');
    String? project;
    messenger.setMockMethodCallHandler(scoreChannel, (call) async {
      if (call.method == 'saveProject') { project = (call.arguments as Map)['text'] as String; return 'project-id'; }
      if (call.method == 'listProjects') return [];
      return null;
    });
    addTearDown(() { for (final c in [pdf, omr, scoreChannel]) { messenger.setMockMethodCallHandler(c, null); } });
    final h = Harness();
    if (changeSettings) {
      // A restored job whose ensemble is edited before starting runs as a new job.
      final job = ConversionJob.restore('existing-id', jsonEncode({'version': 1, 'settings': settings(), 'status': 'running', 'completed_pages': [], 'error': null}));
      h.conversion..setAuto(false)..setVoices('Soprano')..setPiano(false)..setDpi(400);
      h.conversion.items.add(ConversionItem(name: 'Resume PDF', hash: 'b' * 64, pages: 1, job: job));
      await h.conversion.start();
    } else {
      await h.conversion.loadUnfinished();
      await tester.pumpWidget(h.wrap(const ConvertTab()));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Resume PDF'), 200);
      await tester.tap(find.text('Resume PDF'));
      await tester.pumpAndSettle();
    }
    final result = jsonDecode(project!) as Map;
    expect(result['staves'].single['name'], changeSettings ? 'Soprano' : 'Alto');
    expect(h.conversion.items.single.status, ItemStatus.done);
    expect(saved.last['status'], 'complete');
    expect(saved.last['completed_pages'], [0]);
    expect(saved.last['settings'], {...settings(), 'voice_names': [changeSettings ? 'Soprano' : 'Alto']});
  });
  }
}
