import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Same mock as get_storage's test folder, but each test file gets its own
/// directory so files running in parallel never share a container on disk.
Directory mockDocumentsDirectory(String name) {
  final dir = Directory('test_data/$name');
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (MethodCall methodCall) async {
      if (methodCall.method == 'getApplicationDocumentsDirectory') {
        return dir.path;
      }
      return null;
    },
  );
  return dir;
}
