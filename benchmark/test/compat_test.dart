// Legacy detection: .gs files written by gslender 1.0.5, the BOOFI fork v1
// and get_storage open in OrcaSecureStorage (this repo) with all data intact,
// are written as .oss/.ossbak, and the .gs/.bak files are left untouched.
// .oss files are not readable by 1.x (no downgrade).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orca_secure_storage/orca_secure_storage.dart' as v2;
import 'package:orca_secure_storage/src/codec.dart' show isCurrentFormat;
import 'package:get_secure_storage_fork_v1/get_secure_storage.dart' as fork_v1;
import 'package:get_secure_storage_gslender/get_secure_storage.dart' as gslender;
import 'package:get_storage/get_storage.dart' as gs;

import 'utils/accounting_data.dart';
import 'utils/mock_path_provider.dart';

const _password = 'compat-password';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final data = AccountingDataset.generate(1024 * 1024);

  setUpAll(() => dir = mockDocumentsDirectory('compat'));

  File file(String name) => File('${dir.path}/$name');

  Future<void> flushed(dynamic queue) async {
    await Future<void>.delayed(Duration.zero);
    await queue.add<void>(() async {});
  }

  /// Copies [from]'s .gs/.bak to [to], opens [to] and checks every key.
  Future<void> expectMigrated(String from, String to,
      {String? password = _password, bool migrateUnencrypted = false}) async {
    file('$from.gs').copySync('${dir.path}/$to.gs');
    if (file('$from.bak').existsSync()) file('$from.bak').copySync('${dir.path}/$to.bak');
    final legacyBytes = file('$to.gs').readAsBytesSync();

    await v2.OrcaSecureStorage.init(
        container: to, password: password, migrateUnencrypted: migrateUnencrypted);
    final box = v2.OrcaSecureStorage(container: to);
    expect(box.getKeys<Iterable>().length, data.entries.length);
    for (final e in data.entries.entries) {
      expect(json.encode(box.read(e.key)), json.encode(e.value), reason: e.key);
    }
    final main = file('$to.oss').readAsBytesSync();
    expect(isCurrentFormat(main), isTrue, reason: 'written as .oss');
    expect(file('$to.ossbak').readAsBytesSync(), main, reason: '.ossbak written too');
    expect(file('$to.gs').readAsBytesSync(), legacyBytes, reason: '.gs left untouched');
    if (password != null) expect(latin1.decode(main).contains('Cash at Bank'), isFalse);
  }

  test('gslender 1.0.5 encrypted file -> .oss', () async {
    await gslender.GetSecureStorage.init(container: 'by_gslender', password: _password);
    final w = gslender.GetSecureStorage(container: 'by_gslender');
    data.entries.forEach(w.write);
    await flushed(w.queue);
    await Future<void>.delayed(const Duration(seconds: 1)); // its async backup
    await expectMigrated('by_gslender', 'gslender_to_v2');
  });

  test('BOOFI fork v1 encrypted file -> .oss', () async {
    await fork_v1.GetSecureStorage.init(container: 'by_fork_v1', password: _password);
    final w = fork_v1.GetSecureStorage(container: 'by_fork_v1');
    data.entries.forEach(w.write);
    await flushed(w.queue);
    await Future<void>.delayed(const Duration(seconds: 1));
    await expectMigrated('by_fork_v1', 'fork_v1_to_v2');
  });

  test('get_storage file -> .oss encrypted (migrateUnencrypted)', () async {
    await gs.GetStorage.init('by_get_storage');
    final w = gs.GetStorage('by_get_storage');
    data.entries.forEach(w.write);
    await flushed(w.queue);
    await Future<void>.delayed(const Duration(seconds: 1));
    await expectMigrated('by_get_storage', 'get_storage_to_v2', migrateUnencrypted: true);
    await expectMigrated('by_get_storage', 'get_storage_to_v2_plain', password: null);
  });
}
