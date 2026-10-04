@TestOn('browser')
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orca_secure_storage/orca_secure_storage.dart';
import 'package:web/web.dart' as web;

// flutter test --platform chrome test/web_storage_test.dart
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? stored(String container) => web.window.localStorage.getItem(container);

  test('saves are delayed so a burst is stored once; flush() stores at once', () async {
    await OrcaSecureStorage.init(container: 'deb', password: 'pw');
    final box = OrcaSecureStorage(container: 'deb');
    final initial = stored('deb');
    expect(initial, isNotNull);

    // A save happens at most saveDelay (75 ms) after the first unsaved
    // change; writes made meanwhile join it.
    for (var i = 0; i < 20; i++) {
      await box.write('k$i', i);
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(stored('deb'), initial, reason: 'not stored before the delay');
    box.write('late', 1); // joins the pending save

    await Future<void>.delayed(const Duration(milliseconds: 150));
    final afterBurst = stored('deb');
    expect(afterBurst, isNot(initial), reason: 'stored once the delay passed');
    final copy = 'deb_copy';
    web.window.localStorage.setItem(copy, afterBurst!);
    await OrcaSecureStorage.init(container: copy, password: 'pw');
    final reopened = OrcaSecureStorage(container: copy);
    expect(reopened.read('k19'), 19);
    expect(reopened.read('late'), 1);

    box.write('now', true);
    final sw = Stopwatch()..start();
    await box.flush();
    expect(sw.elapsedMilliseconds, lessThan(60), reason: 'flush() does not wait');
    expect(stored('deb'), isNot(afterBurst));
  });

  test('writeAll stores every value and refuses a bad batch', () async {
    web.window.localStorage.removeItem('wall');
    await OrcaSecureStorage.init(container: 'wall', password: 'pw');
    final box = OrcaSecureStorage(container: 'wall');
    await box.writeAll({'a': 1, 'b': {'x': 2}});
    expect(() => box.writeAll({'ok': 1, 'bad': Object()}), throwsA(isA<JsonUnsupportedObjectError>()));
    expect(box.read('ok'), isNull);
    await box.flush();
    web.window.localStorage.setItem('wall_copy', web.window.localStorage.getItem('wall')!);
    await OrcaSecureStorage.init(container: 'wall_copy', password: 'pw');
    final copy = OrcaSecureStorage(container: 'wall_copy');
    expect(copy.read('a'), 1);
    expect(copy.read('b'), {'x': 2});
  });

  test('stored data reads back after reopening', () async {
    web.window.localStorage.removeItem('reopen');
    await OrcaSecureStorage.init(container: 'reopen', password: 'pw');
    final box = OrcaSecureStorage(container: 'reopen');
    box.write('a', {'x': 1});
    await box.flush();
    final copy = web.window.localStorage.getItem('reopen')!;
    web.window.localStorage.setItem('reopen_copy', copy);
    await OrcaSecureStorage.init(container: 'reopen_copy', password: 'pw');
    expect(OrcaSecureStorage(container: 'reopen_copy').read('a'), {'x': 1});
  });
}
