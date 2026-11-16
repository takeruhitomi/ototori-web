/// Web build only: answers the app's platform channels in the browser.
///
/// The Android app implements these channels in Kotlin (MainActivity). On
/// the web the same calls go to `globalThis.ototoriPlatform.call(channel,
/// method, args)` (web/js/platform.js), so the Flutter UI is shared as is.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

const _channels = [
  'jp.choiromr.mobile/pdf',
  'jp.choiromr.mobile/omr',
  'jp.choiromr.mobile/score',
  'jp.choiromr.mobile/incoming',
];

@JS('ototoriPlatform')
external JSObject? get _platform;

@JS('ototoriNotifyIncoming')
external set _notifyIncoming(JSFunction value);

void registerPlatformBridge() {
  for (final name in _channels) {
    final channel = MethodChannel(name, const StandardMethodCodec(), webPluginRegistrar);
    channel.setMethodCallHandler((call) => _call(name, call));
  }
  webPluginRegistrar.registerMessageHandler();
  // Calls from the page to the app (a received song file).
  final incoming = MethodChannel(_channels[3], const StandardMethodCodec(), webPluginRegistrar);
  _notifyIncoming = (() { incoming.invokeMethod<void>('incomingProject'); }).toJS;
}

Future<Object?> _call(String channel, MethodCall call) async {
  final platform = _platform;
  if (platform == null) {
    throw PlatformException(code: 'web', message: 'ブラウザ版の機能を読み込めませんでした。ページを再読み込みしてください。');
  }
  // platform.js resolves with {ok: true, value} or {ok: false, code, message}.
  final promise = platform.callMethod<JSPromise<JSObject>>('call'.toJS, channel.toJS, call.method.toJS, _toJs(call.arguments));
  final reply = await promise.toDart;
  if (reply['ok']?.dartify() == true) return _toDart(reply['value']);
  final code = reply['code']?.dartify();
  final message = reply['message']?.dartify();
  if (code == 'notImplemented') throw MissingPluginException('${call.method} is not available on the web');
  throw PlatformException(code: code is String ? code : 'web', message: message is String ? message : null);
}

JSAny? _toJs(Object? value) {
  if (value == null) return null;
  if (value is Uint8List) return value.toJS;
  if (value is Map) return {for (final e in value.entries) '${e.key}': _toJs(e.value)}.jsify();
  if (value is List) return [for (final v in value) _toJs(v)].toJS;
  return value.jsify();
}

/// JS -> values the StandardMethodCodec would deliver: Uint8Array stays
/// Uint8List, integral numbers are ints, objects are `Map<Object?, Object?>`.
Object? _toDart(JSAny? value) {
  if (value == null || value.isUndefinedOrNull) return null;
  if (value.isA<JSUint8Array>()) return (value as JSUint8Array).toDart;
  if (value.isA<JSArray>()) return [for (final v in (value as JSArray<JSAny?>).toDart) _toDart(v)];
  if (value.typeofEquals('object')) {
    final object = value as JSObject;
    final keys = (globalContext['Object'] as JSObject).callMethod<JSArray<JSString>>('keys'.toJS, object).toDart;
    return <Object?, Object?>{for (final k in keys) k.toDart: _toDart(object[k.toDart])};
  }
  final plain = value.dartify();
  if (plain is double && plain == plain.truncateToDouble() && plain.abs() < 9007199254740992) return plain.toInt();
  return plain;
}
