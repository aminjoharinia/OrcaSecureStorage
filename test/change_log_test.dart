import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orca_secure_storage/orca_secure_storage.dart';

// The change log (<container>.osslog): updates are appended and fsynced, and
// folded into the snapshot when idle. These tests simulate crashes and damage
// by copying and editing the files, then opening them as a new container.

final _key = List<int>.generate(32, (i) => i * 3 + 1);
const _idle = Duration(milliseconds: 700); // > the 300 ms idle delay

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('oss_log_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  File file(String name) => File('${dir.path}/$name');
  List<int> bytes(String name) => file(name).readAsBytesSync();
  int logLength(String c) => file('$c.osslog').lengthSync();
  const header = 21;

  void copy(String from, String to, {List<String> exts = const ['.oss', '.ossbak', '.osslog']}) {
    for (final ext in exts) {
      if (file('$from$ext').existsSync()) file('$from$ext').copySync('${dir.path}/$to$ext');
    }
  }

  Future<OrcaSecureStorage> open(String c, {List<int>? key, String? password}) async {
    key ??= password == null ? _key : null;
    await OrcaSecureStorage.init(container: c, encryptionKey: key, password: password);
    return OrcaSecureStorage(container: c, encryptionKey: key, password: password);
  }

  Future<void> flushed(OrcaSecureStorage box) async {
    await Future<void>.delayed(Duration.zero);
    await box.queue.add<void>(() async {});
  }

  Future<void> put(OrcaSecureStorage box, String key, Object? value) async {
    box.write(key, value);
    await flushed(box);
  }

  test('an update appends to the log and leaves the snapshot alone', () async {
    final box = await open('lg');
    await put(box, 'a', 1);
    await Future<void>.delayed(_idle);
    final snapshot = bytes('lg.oss');

    await put(box, 'b', {'nested': [1, 2]});
    expect(bytes('lg.oss'), snapshot);
    expect(logLength('lg'), greaterThan(header));

    copy('lg', 'lg_r');
    final r = await open('lg_r');
    expect(r.read('a'), 1);
    expect(r.read('b'), {'nested': [1, 2]});
  });

  test('when idle, the log is folded into the snapshot and backup', () async {
    final box = await open('idle');
    await put(box, 'x', 'first');
    await put(box, 'x', 'second');
    await Future<void>.delayed(_idle);

    expect(logLength('idle'), header);
    expect(bytes('idle.ossbak'), bytes('idle.oss'));
    copy('idle', 'idle_r', exts: ['.oss']); // the snapshot alone is complete
    expect((await open('idle_r')).read('x'), 'second');
  });

  test('a torn last record is dropped; earlier changes survive; log kept aside', () async {
    final box = await open('torn');
    await Future<void>.delayed(_idle);
    await put(box, 'v', 1);
    await put(box, 'v', 2);
    await put(box, 'v', 3);
    copy('torn', 'torn_r');
    final full = bytes('torn_r.osslog');
    file('torn_r.osslog').writeAsBytesSync(full.sublist(0, full.length - 5));

    final r = await open('torn_r');
    expect(r.read('v'), 2);
    expect(bytes('torn_r.osslog.rejected'), full.sublist(0, full.length - 5));
    await Future<void>.delayed(const Duration(milliseconds: 200)); // tidy-up after open
    expect(logLength('torn_r'), header, reason: 'repaired: changes are in the snapshot now');
  });

  test('a log from before the current snapshot is not applied again', () async {
    final box = await open('stale');
    await Future<void>.delayed(_idle);
    await put(box, 'zombie', true);
    final oldLog = bytes('stale.osslog'); // belongs to the snapshot without zombie
    await Future<void>.delayed(_idle);
    box.remove('zombie');
    await flushed(box);
    await Future<void>.delayed(_idle); // snapshot now has no zombie

    // Crash between writing that snapshot and resetting the log:
    copy('stale', 'stale_r', exts: ['.oss', '.ossbak']);
    file('stale_r.osslog').writeAsBytesSync(oldLog);
    expect((await open('stale_r')).read('zombie'), isNull);
    // Recognised as already included (a normal state after a crash), not as
    // damage: nothing is set aside.
    expect(file('stale_r.osslog.rejected').existsSync(), isFalse);
  });

  test('without encryption, a stale log is not applied either', () async {
    await OrcaSecureStorage.init(container: 'pstale');
    final box = OrcaSecureStorage(container: 'pstale');
    await Future<void>.delayed(_idle);
    await put(box, 'zombie', true);
    final oldLog = bytes('pstale.osslog');
    await Future<void>.delayed(_idle);
    box.remove('zombie');
    await flushed(box);
    await Future<void>.delayed(_idle);

    copy('pstale', 'pstale_r', exts: ['.oss', '.ossbak']);
    file('pstale_r.osslog').writeAsBytesSync(oldLog);
    await OrcaSecureStorage.init(container: 'pstale_r');
    expect(OrcaSecureStorage(container: 'pstale_r').read('zombie'), isNull);
    expect(file('pstale_r.osslog.rejected').existsSync(), isFalse);
  });

  test('main snapshot damaged: backup + its log give the latest state', () async {
    final box = await open('dmg');
    await put(box, 'a', 1);
    await Future<void>.delayed(_idle);
    await put(box, 'b', 2);
    copy('dmg', 'dmg_r');
    file('dmg_r.oss').writeAsStringSync('garbage');

    final r = await open('dmg_r');
    expect(r.read('a'), 1);
    expect(r.read('b'), 2);
  });

  test('crash after the new snapshot but before the backup', () async {
    final box = await open('half');
    await put(box, 'a', 1);
    await Future<void>.delayed(_idle);
    await put(box, 'b', 2); // in the log of snapshot 1
    copy('half', 'half_old'); // snapshot 1, backup 1, log with b
    await Future<void>.delayed(_idle); // snapshot 2 contains a and b

    // New main, old backup, old log.
    file('half.oss').copySync('${dir.path}/half_r.oss');
    file('half_old.ossbak').copySync('${dir.path}/half_r.ossbak');
    file('half_old.osslog').copySync('${dir.path}/half_r.osslog');
    var r = await open('half_r');
    expect([r.read('a'), r.read('b')], [1, 2]);

    // Same, and the new main is unreadable: old backup + old log.
    copy('half_old', 'half_r2', exts: ['.ossbak', '.osslog']);
    file('half_r2.oss').writeAsStringSync('garbage');
    r = await open('half_r2');
    expect([r.read('a'), r.read('b')], [1, 2]);
  });

  test('a wrong key never destroys the snapshot or the log', () async {
    final box = await open('wk');
    await Future<void>.delayed(_idle);
    await put(box, 'secret', 'kept');
    copy('wk', 'wk_r');
    final snapshot = bytes('wk_r.oss');
    final log = bytes('wk_r.osslog');

    final r = await open('wk_r', key: List.filled(32, 9));
    expect(r.read('secret'), isNull);
    expect(bytes('wk_r.oss.rejected'), snapshot);
    expect(bytes('wk_r.osslog.rejected'), log);
  });

  test('a tampered record stops the replay there; the log is kept aside', () async {
    final box = await open('tamper');
    await Future<void>.delayed(_idle);
    await put(box, 'k1', 'one');
    final afterFirst = logLength('tamper');
    await put(box, 'k2', 'two');
    await put(box, 'k3', 'three');
    copy('tamper', 'tamper_r');
    final log = bytes('tamper_r.osslog');
    final edited = List<int>.of(log)..[afterFirst + 20] ^= 0x01; // inside record 2
    file('tamper_r.osslog').writeAsBytesSync(edited);

    final r = await open('tamper_r');
    expect([r.read('k1'), r.read('k2'), r.read('k3')], ['one', null, null]);
    expect(bytes('tamper_r.osslog.rejected'), edited);
  });

  test('without encryption, a checksum catches a damaged record', () async {
    await OrcaSecureStorage.init(container: 'plainlog');
    final box = OrcaSecureStorage(container: 'plainlog');
    await Future<void>.delayed(_idle);
    await put(box, 'k1', 'one');
    final afterFirst = logLength('plainlog');
    await put(box, 'k2', 'two');
    copy('plainlog', 'plainlog_r');
    final edited = List<int>.of(bytes('plainlog_r.osslog'))..[afterFirst + 10] ^= 0x01;
    file('plainlog_r.osslog').writeAsBytesSync(edited);

    await OrcaSecureStorage.init(container: 'plainlog_r');
    final r = OrcaSecureStorage(container: 'plainlog_r');
    expect([r.read('k1'), r.read('k2')], ['one', null]);
    expect(file('plainlog_r.osslog.rejected').existsSync(), isTrue);
  });

  test('the log stays bounded under continuous writes', () async {
    final box = await open('busy');
    final big = 'x' * 20000;
    for (var i = 0; i < 20; i++) {
      await put(box, 'k$i', '$big$i'); // never idle
    }
    // Folded into the snapshot whenever it outgrew it.
    expect(logLength('busy'), lessThan(file('busy.oss').lengthSync() + 64 * 1024));
    copy('busy', 'busy_r');
    final r = await open('busy_r');
    expect(r.read('k19'), '${big}19');
    expect(r.getKeys<Iterable>().length, 20);
  });

  test('the encrypted log contains no plaintext', () async {
    final box = await open('enc');
    await Future<void>.delayed(_idle);
    await put(box, 'note', 'visible-secret-text');
    expect(latin1.decode(bytes('enc.osslog')).contains('visible-secret-text'), isFalse);
  });

  test('password-protected log converts to a key on open', () async {
    final box = await open('pwlog', password: 'pw');
    await Future<void>.delayed(_idle);
    await put(box, 'ledger', [1, 2, 3]); // in the log, encrypted with the password key
    copy('pwlog', 'pwlog_r');

    await OrcaSecureStorage.init(container: 'pwlog_r', password: 'pw', encryptionKey: _key);
    expect(OrcaSecureStorage(container: 'pwlog_r').read('ledger'), [1, 2, 3]);
    copy('pwlog_r', 'pwlog_k');
    expect((await open('pwlog_k')).read('ledger'), [1, 2, 3]);
  });

  test('deleteContainer removes the log too', () async {
    file('gone2.osslog').writeAsStringSync('x');
    expect(await OrcaSecureStorage.hasContainer('gone2'), isTrue);
    await OrcaSecureStorage.deleteContainer('gone2');
    expect(file('gone2.osslog').existsSync(), isFalse);
  });
}
