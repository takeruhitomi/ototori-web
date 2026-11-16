import 'package:choir_mobile/omr_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jp.choiromr.mobile/omr');
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

  test('translates platform output into typed symbol data', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'recognizePage');
      expect(call.arguments, {'page': 1, 'dpi': 300});
      return {'width': 1920, 'height': 2485, 'warnings': ['review'], 'staves': [
        {'crop': [20, 30, 800, 150], 'reachedEos': true, 'symbols': [
          ['note_4', 'C4', '_', 'upper', '_', '_']
        ]}
      ]};
    });
    final result = await const OmrBridge().recognizePage(page: 1, dpi: 300);
    expect(result.staves.single.symbols.single.midiPitch, 60);
    expect(result.staves.single.crop, [20, 30, 800, 150]);
    expect(result.warnings, ['review']);
  });

  test('attaches the printed part names read after recognition', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readPageLabels') {
        expect(call.arguments, {'page': 0});
        return {'labels': [{'text': 'Tenor I', 'bounds': [170, 1025, 282, 1058]}], 'warnings': ['ocr note']};
      }
      return {'width': 1920, 'height': 2485, 'warnings': [], 'staves': [
        {'crop': [20, 30, 800, 150], 'reachedEos': true, 'symbols': []}
      ]};
    });
    final result = await const OmrBridge().recognizePage(page: 0, dpi: 300);
    expect(result.labels.single.text, 'Tenor I');
    expect(result.warnings, isEmpty);
  });

  test('keeps the recognised page when reading part names fails', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'readPageLabels') throw PlatformException(code: 'layout');
      return {'width': 1920, 'height': 2485, 'warnings': [], 'staves': [
        {'crop': [20, 30, 800, 150], 'reachedEos': true, 'symbols': []}
      ]};
    });
    final result = await const OmrBridge().recognizePage(page: 0, dpi: 300);
    expect(result.staves, hasLength(1));
    expect(result.labels, isEmpty);
  });

  test('rejects malformed geometry instead of consuming invalid recognition data', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (_) async =>
      {'width': 1920, 'height': 2485, 'warnings': [], 'staves': [{'crop': [1, 2, 0, 5], 'reachedEos': true, 'symbols': []}]});
    await expectLater(const OmrBridge().recognizePage(page: 0, dpi: 400), throwsFormatException);
  });
}
