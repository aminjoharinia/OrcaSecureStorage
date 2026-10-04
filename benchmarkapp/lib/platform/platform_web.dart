import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// No process environment on the web.
Map<String, String> environment() => const {};

String platformName() => const bool.fromEnvironment('dart.tool.dart2wasm')
    ? 'web (wasm)'
    : 'web (js)';

void exitApp(int code) {}

Future<String?> saveFile(String name, List<int> bytes) async => null;

// get_storage-style containers live in localStorage under their name.

/// Copies container [from] to [to] (for cold reads).
Future<void> copyStore(String from, String to, String ext) async {
  final value = web.window.localStorage.getItem(from);
  if (value != null) web.window.localStorage.setItem(to, value);
}

Future<void> deleteStore(String name, List<String> exts) async =>
    web.window.localStorage.removeItem(name);

/// Gives the event loop one turn. A zero-delay timer would do, but browsers
/// clamp nested timers to 4 ms; a MessageChannel message is not clamped.
Future<void> yieldToEventLoop() {
  final done = Completer<void>();
  final channel = web.MessageChannel();
  channel.port1.onmessage = ((web.MessageEvent _) {
    channel.port1.close();
    done.complete();
  }).toJS;
  channel.port2.postMessage(null);
  return done.future;
}
