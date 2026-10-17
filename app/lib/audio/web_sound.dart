/// The browser's sound engine (web builds only; a stub elsewhere).
library;

export 'web_sound_stub.dart' if (dart.library.js_interop) 'web_sound_web.dart';
