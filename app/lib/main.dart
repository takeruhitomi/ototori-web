import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'app/shell.dart';
import 'web_bridge_stub.dart' if (dart.library.js_interop) 'web_bridge.dart';

export 'app/shell.dart' show OtotoriApp;

void main() {
  registerPlatformBridge();
  LicenseRegistry.addLicense(() => Stream.fromIterable(const [
    LicenseEntryWithLineBreaks(['Salamander Grand Piano'],
      'Salamander Grand Piano by Alexander Holm, licensed under CC BY 3.0 '
      '(https://creativecommons.org/licenses/by/3.0/). '
      'Selected notes were converted to mono 22,050 Hz and shortened to at most 8 seconds. '
      'Source: https://github.com/Tonejs/audio/tree/master/salamander'),
    LicenseEntryWithLineBreaks(['homr'],
      'Optical music recognition models and code derived from homr '
      '(https://github.com/liebharc/homr), licensed under the GNU Affero General Public License v3.0. '
      'See third_party/homr in the source distribution for the license text.'),
  ]));
  runApp(const OtotoriApp());
}
