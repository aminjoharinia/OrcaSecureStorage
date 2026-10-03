import 'dart:ffi';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// e.g. `macos_arm64`, `android_arm64`, `windows_x64`.
String platformName() => Abi.current().toString();

void exitApp(int code) => exit(code);

/// Writes [bytes] to the system temp folder (inside the sandbox on macOS)
/// and returns the path.
Future<String?> saveFile(String name, List<int> bytes) async {
  final file = File('${Directory.systemTemp.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

// get_storage-style containers live in the documents folder as <name><ext>.
Future<String> _documents() async =>
    (await getApplicationDocumentsDirectory()).path;

/// Copies container [from] to [to] (for cold reads).
Future<void> copyStore(String from, String to, String ext) async {
  final dir = await _documents();
  final source = File('$dir/$from$ext');
  if (source.existsSync()) await source.copy('$dir/$to$ext');
}

Future<void> deleteStore(String name, List<String> exts) async {
  final dir = await _documents();
  for (final ext in exts) {
    final f = File('$dir/$name$ext');
    if (f.existsSync()) await f.delete();
  }
}

/// Gives the event loop one turn.
Future<void> yieldToEventLoop() => Future<void>.delayed(Duration.zero);
