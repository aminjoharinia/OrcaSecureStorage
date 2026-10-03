import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orca_secure_storage/orca_secure_storage.dart';
import 'package:orca_secure_storage/src/codec.dart';

const _password = 'p4ssw0rd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('oss_io_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async =>
          call.method == 'getApplicationDocumentsDirectory' ? dir.path : null,
    );
  });
  tearDownAll(() => dir.deleteSync(recursive: true));

  File file(String name) => File('${dir.path}/$name');
  List<int> bytes(String name) => file(name).readAsBytesSync();
  bool isV2(String name) => isCurrentFormat(bytes(name));
  bool containsText(String name, String text) =>
      latin1.decode(bytes(name)).contains(text);

  /// Copies a container's current files (snapshot, backup, change log).
  void copyContainer(String from, String to) {
    for (final ext in ['.oss', '.ossbak', '.osslog']) {
      if (file('$from$ext').existsSync()) file('$from$ext').copySync('${dir.path}/$to$ext');
    }
  }

  /// Opens a fresh instance on a copy of [container]'s files, so the data
  /// really comes from disk.
  Future<OrcaSecureStorage> reopen(String container, String copy,
      {String? password = _password, bool migrateUnencrypted = false}) async {
    copyContainer(container, copy);
    await OrcaSecureStorage.init(
        container: copy, password: password, migrateUnencrypted: migrateUnencrypted);
    return OrcaSecureStorage(container: copy);
  }

  /// Waits until every write so far is on disk. `write()` queues its flush in
  /// a microtask, so let that run before queueing the marker behind it.
  Future<void> flushed(OrcaSecureStorage box) async {
    await Future<void>.delayed(Duration.zero);
    await box.queue.add<void>(() async {});
  }

  /// The 1.x key: PBKDF2-HMAC-SHA256, 1000 iterations, reversed password as
  /// salt, 128 bits.
  Future<List<int>> legacyKey(String password) async {
    final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 1000, bits: 128)
        .deriveKeyFromPassword(
            password: password, nonce: password.runes.toList().reversed.toList());
    return key.extractBytes();
  }

  test('single-key writes, removes and erase persist', () async {
    await OrcaSecureStorage.init(container: 'inc', password: _password);
    final box = OrcaSecureStorage(container: 'inc');
    for (var i = 0; i < 100; i++) {
      box.write('k$i', {'i': i, 'name': 'entry $i'});
    }
    await flushed(box);
    box.write('k5', 'changed');
    box.remove('k7');
    await flushed(box);

    var r = await reopen('inc', 'inc_r1');
    expect(r.getKeys<Iterable>().length, 99);
    expect(r.read('k5'), 'changed');
    expect(r.read('k7'), isNull);
    expect(r.read('k99'), {'i': 99, 'name': 'entry 99'});

    await box.erase();
    box.write('after', 1);
    await flushed(box);
    r = await reopen('inc', 'inc_r2');
    expect(r.getKeys<Iterable>().toList(), ['after']);

    expect(isV2('inc.oss'), isTrue);
    expect(containsText('inc.oss', 'entry'), isFalse);
    expect(bytes('inc.ossbak'), bytes('inc.oss'));
    expect(dir.listSync().where((f) => f.path.endsWith('.tmp')), isEmpty);
  });

  test('save() persists values mutated in place', () async {
    await OrcaSecureStorage.init(container: 'mut', password: _password);
    final box = OrcaSecureStorage(container: 'mut');
    box.write('list', [1, 2]);
    await flushed(box);
    box.read<List>('list')!.add(3);
    await box.save();
    await flushed(box);
    expect((await reopen('mut', 'mut_r')).read('list'), [1, 2, 3]);
  });

  test('1.x .gs file is converted to .oss and left in place', () async {
    final legacy = await encodeLegacyDocument(
        await legacyKey(_password), json.encode({'balance': 1234.5, 'ok': true}));
    file('v1.gs').writeAsStringSync(legacy);
    file('v1.bak').writeAsStringSync(legacy);

    await OrcaSecureStorage.init(container: 'v1', password: _password);
    final box = OrcaSecureStorage(container: 'v1');
    expect(box.read('balance'), 1234.5);
    expect(isV2('v1.oss'), isTrue);
    expect(bytes('v1.ossbak'), bytes('v1.oss'));
    expect(file('v1.gs').readAsStringSync(), legacy);
    expect(file('v1.bak').readAsStringSync(), legacy);
    expect((await reopen('v1', 'v1_r')).read('ok'), true);
  });

  test('a corrupted .gs falls back to the legacy .bak', () async {
    final legacy = await encodeLegacyDocument(
        await legacyKey(_password), json.encode({'from': 'bak'}));
    file('v1b.gs').writeAsStringSync('ndj323e');
    file('v1b.bak').writeAsStringSync(legacy);
    await OrcaSecureStorage.init(container: 'v1b', password: _password);
    expect(OrcaSecureStorage(container: 'v1b').read('from'), 'bak');
    expect(isV2('v1b.oss'), isTrue);
  });

  test('default container converts the old GetSecureStorage.gs', () async {
    final legacy = await encodeLegacyDocument(
        await legacyKey(_password), json.encode({'old': 'default'}));
    file('GetSecureStorage.gs').writeAsStringSync(legacy);
    await OrcaSecureStorage.init(password: _password);
    expect(OrcaSecureStorage().read('old'), 'default');
    expect(isV2('OrcaSecureStorage.oss'), isTrue);
    expect(file('GetSecureStorage.gs').readAsStringSync(), legacy);
  });

  test('deleteContainer removes current and legacy files', () async {
    file('gone.gs').writeAsStringSync('{}');
    file('gone.oss').writeAsStringSync('x');
    file('gone.ossbak').writeAsStringSync('x');
    expect(await OrcaSecureStorage.hasContainer('gone'), isTrue);
    await OrcaSecureStorage.deleteContainer('gone');
    expect(await OrcaSecureStorage.hasContainer('gone'), isFalse);
  });

  test('1.x unencrypted file is not loaded and left untouched', () async {
    file('plain.gs').writeAsStringSync(json.encode({'injected': true}));
    await OrcaSecureStorage.init(container: 'plain', password: _password);
    final box = OrcaSecureStorage(container: 'plain');
    expect(box.read('injected'), isNull);
    expect(file('plain.gs').readAsStringSync(), '{"injected":true}');
    expect(isV2('plain.oss'), isTrue);
    expect(containsText('plain.oss', 'injected'), isFalse);
  });

  test('migrateUnencrypted loads a plain .gs file and encrypts it', () async {
    file('legacy.gs').writeAsStringSync(json.encode({'kept': 'yes'}));
    await OrcaSecureStorage.init(
        container: 'legacy', password: _password, migrateUnencrypted: true);
    expect(OrcaSecureStorage(container: 'legacy').read('kept'), 'yes');
    expect(isV2('legacy.oss'), isTrue);
    expect(containsText('legacy.oss', 'kept'), isFalse);
    expect((await reopen('legacy', 'legacy_r')).read('kept'), 'yes');
  });

  test('unencrypted .oss file is rejected and kept aside', () async {
    await OrcaSecureStorage.init(container: 'nopw_src');
    final src = OrcaSecureStorage(container: 'nopw_src');
    src.write('injected', true);
    await flushed(src);
    copyContainer('nopw_src', 'swap');

    await OrcaSecureStorage.init(container: 'swap', password: _password);
    expect(OrcaSecureStorage(container: 'swap').read('injected'), isNull);
    expect(file('swap.oss.rejected').existsSync(), isTrue);
  });

  test('corrupted main file recovers from backup', () async {
    await OrcaSecureStorage.init(container: 'corrupt', password: _password);
    final box = OrcaSecureStorage(container: 'corrupt');
    box.write('a', 'abc');
    await flushed(box);

    copyContainer('corrupt', 'corrupt_r');
    file('corrupt_r.oss').writeAsStringSync('ndj323e');
    await OrcaSecureStorage.init(container: 'corrupt_r', password: _password);
    expect(OrcaSecureStorage(container: 'corrupt_r').read('a'), 'abc');
    // The main file was rewritten from the backup.
    expect(isV2('corrupt_r.oss'), isTrue);
  });

  test('wrong password keeps the encrypted file aside', () async {
    await OrcaSecureStorage.init(container: 'pw', password: _password);
    final box = OrcaSecureStorage(container: 'pw');
    box.write('secret', 1);
    await flushed(box);
    final original = bytes('pw.oss');

    final r = await reopen('pw', 'pw_r', password: 'wrong');
    expect(r.read('secret'), isNull);
    expect(bytes('pw_r.oss.rejected'), original);
  });

  test('password container converts to an encryption key', () async {
    final key = OrcaSecureStorage.generateKey();
    await OrcaSecureStorage.init(container: 'pk', password: _password);
    final box = OrcaSecureStorage(container: 'pk');
    box.write('ledger', [1, 2, 3]);
    await flushed(box);

    // Key alone cannot open a password file: kept aside, starts empty.
    copyContainer('pk', 'pk_keyonly');
    await OrcaSecureStorage.init(container: 'pk_keyonly', encryptionKey: key);
    expect(OrcaSecureStorage(container: 'pk_keyonly').read('ledger'), isNull);
    expect(file('pk_keyonly.oss.rejected').existsSync(), isTrue);

    // Password + key: read with the password, rewritten with the key.
    copyContainer('pk', 'pk_both');
    await OrcaSecureStorage.init(container: 'pk_both', password: _password, encryptionKey: key);
    expect(OrcaSecureStorage(container: 'pk_both').read('ledger'), [1, 2, 3]);
    expect(bytes('pk_both.oss')[5], 2, reason: 'now a raw-key file');

    // From now on the key alone is enough.
    copyContainer('pk_both', 'pk_after');
    await OrcaSecureStorage.init(container: 'pk_after', encryptionKey: key);
    expect(OrcaSecureStorage(container: 'pk_after').read('ledger'), [1, 2, 3]);
  });

  test('1.x .gs file converts straight to an encryption key', () async {
    final key = OrcaSecureStorage.generateKey();
    final legacy = await encodeLegacyDocument(
        await legacyKey(_password), json.encode({'v': 'one'}));
    file('v1k.gs').writeAsStringSync(legacy);
    await OrcaSecureStorage.init(container: 'v1k', password: _password, encryptionKey: key);
    expect(OrcaSecureStorage(container: 'v1k').read('v'), 'one');
    expect(bytes('v1k.oss')[5], 2);
  });

  test('encryptionKey must be 32 bytes', () {
    expect(() => OrcaSecureStorage(container: 'badkey', encryptionKey: [1, 2, 3]),
        throwsArgumentError);
  });

  test('container without password is a compressed .oss file', () async {
    await OrcaSecureStorage.init(container: 'nopw');
    final box = OrcaSecureStorage(container: 'nopw');
    box.write('x', [1, 'two']);
    await flushed(box);
    expect(isV2('nopw.oss'), isTrue);
    expect((await reopen('nopw', 'nopw_r', password: null)).read('x'), [1, 'two']);
  });
}
