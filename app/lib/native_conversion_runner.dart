import 'package:flutter/services.dart';
import 'conversion_job.dart';

/// Observes an Android-owned job. Detaching the UI never cancels inference.
class NativeConversionRunner {
  const NativeConversionRunner({this.pollInterval = const Duration(milliseconds: 500)});
  final Duration pollInterval;
  static const channel = MethodChannel('jp.choiromr.mobile/pdf');

  Future<bool> run(ConversionJob job, {required bool Function() attached,
    required void Function(ConversionJob) onProgress}) async {
    final id = job.id;
    if (id == null) throw const FormatException('保存した変換ジョブが必要です。');
    await channel.invokeMethod<void>('startNativeConversion', {'id': id});
    while (attached()) {
      final state = await channel.invokeMapMethod<Object?, Object?>('nativeConversionState', {'id': id});
      if (!attached()) return false;
      if (state == null || state['text'] is! String || state['active'] is! bool) throw const FormatException('変換の実行状態が不正です。');
      final saved = ConversionJob.restore(id, state['text'] as String);
      if (saved.signature != job.signature) throw const FormatException('実行中の変換設定が変更されています。');
      job.completedPages..clear()..addAll(saved.completedPages);
      job.status = saved.status; job.error = saved.error;
      onProgress(job);
      if (state['active'] != true) {
        if (job.status == 'recognized' || job.status == 'complete') return true;
        throw PlatformException(code: job.status == 'cancelled' ? 'cancelled' : 'conversion',
          message: job.error ?? '認識が中断されています。保存済みページから再開してください。');
      }
      await Future<void>.delayed(pollInterval);
    }
    return false;
  }
}
