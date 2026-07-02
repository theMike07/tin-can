import 'dart:js_interop';

// „Ding" zdefiniowany w web/index.html (Web Audio).
@JS('tinCanChime')
external void _tinCanChime();

void playChime() {
  try {
    _tinCanChime();
  } catch (_) {}
}
