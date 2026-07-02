// Dźwięk odbioru: na web używa Web Audio (js_interop), na mobile jest zaślepką.
// Warunkowy import wybiera implementację zależnie od platformy kompilacji.
export 'chime_stub.dart' if (dart.library.js_interop) 'chime_web.dart';
