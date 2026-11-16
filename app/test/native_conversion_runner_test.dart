import 'dart:convert';
import 'package:choir_mobile/conversion_job.dart';
import 'package:choir_mobile/native_conversion_runner.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

ConversionJob job() => ConversionJob({'source_hash': 'a' * 64, 'name': 'Test', 'dpi': 300,
  'pages': 2, 'selected_page': 0, 'all_pages': true, 'piano': false, 'voice_names': ['Alto']}, id: 'job-id');
String record(ConversionJob job, String status, List<int> pages, {String? error}) => jsonEncode({
  'version': 1, 'settings': job.settings, 'status': status, 'completed_pages': pages, 'error': error,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('jp.choiromr.mobile/pdf');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('waits for the native owner to finish before reading recognized pages', () async {
    final input = job();
    var polls = 0;
    final progress = <int>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'startNativeConversion') return null;
      expect(call.method, 'nativeConversionState');
      polls++;
      return {'active': polls < 3, 'text': record(input, polls == 1 ? 'running' : 'recognized', polls == 1 ? [0] : [0, 1])};
    });
    final complete = await const NativeConversionRunner(pollInterval: Duration.zero).run(input,
      attached: () => true, onProgress: (job) => progress.add(job.completedPages.length));
    expect(complete, true); expect(polls, 3); expect(progress, [1, 2, 2]);
    expect(input.status, 'recognized'); expect(input.completedPages, {0, 1});
  });
  test('detaching the screen leaves the Android job alone', () async {
    final calls = <String>[];
    var attached = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method); attached = false; return null;
    });
    expect(await const NativeConversionRunner().run(job(), attached: () => attached, onProgress: (_) => fail('Detached UI updated')), false);
    expect(calls, ['startNativeConversion']);
  });
  for (final status in ['running', 'cancelled', 'failed']) {
    test('reports inactive $status while preserving completed pages', () async {
      final input = job();
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startNativeConversion') return null;
        return {'active': false, 'text': record(input, status, [0], error: status == 'running' ? null : 'Saved failure')};
      });
      await expectLater(const NativeConversionRunner().run(input, attached: () => true, onProgress: (_) {}),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', status == 'cancelled' ? 'cancelled' : 'conversion')));
      expect(input.completedPages, {0}); expect(input.status, status);
    });
  }
}
