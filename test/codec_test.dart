import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orca_secure_storage/src/codec.dart';

// The 1.x codec, kept verbatim: 1.x files must still be readable.
String oldHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final legacyKey = List<int>.generate(16, (i) => i * 7 + 3);
  final plain = jsonEncode({
    'MainDB': {'Places': List.generate(200, (i) => {'Name': 'Room $i', 'v': i})}
  });
  // Low iteration count keeps the tests fast; the format stores the count.
  StorageCodec codec({String? password = 'pw', bool migrate = false, bool gzipOn = true}) =>
      StorageCodec(
        StorageCodecConfig(
          password: password,
          legacyKeyBytes: password == null ? null : legacyKey,
          migrateUnencrypted: migrate,
          kdfIterations: 1000,
        ),
        compress: gzipOn ? GZipCodec(level: 1).encode : null,
        decompress: gzip.decode,
      );

  group('format 2', () {
    test('round trip, encrypted and compressed', () async {
      final bytes = await codec().encode(plain);
      expect(isCurrentFormat(bytes), isTrue);
      expect(bytes.length, lessThan(plain.length));
      expect(utf8.decode(bytes, allowMalformed: true), isNot(contains('Room')));
      final doc = await codec().decode(bytes);
      expect(doc.plaintext, plain);
      expect(doc.needsRewrite, isFalse);
    });

    test('round trip without password or compression', () async {
      for (final gzipOn in [true, false]) {
        final c = codec(password: null, gzipOn: gzipOn);
        expect((await c.decode(await c.encode(plain))).plaintext, plain);
      }
    });

    test('each write uses a fresh nonce, the same salt', () async {
      final c = codec();
      final a = await c.encode(plain);
      final b = await c.encode(plain);
      expect(a.sublist(0, 27), b.sublist(0, 27)); // header through the salt
      expect(a, isNot(b));
    });

    test('wrong password is rejected', () async {
      final bytes = await codec().encode(plain);
      expect(() => codec(password: 'other').decode(bytes),
          throwsA(isA<StorageRejectedException>()));
    });

    test('tampered header or ciphertext is rejected', () async {
      final bytes = await codec().encode(plain);
      for (final i in [5, 8, 20, bytes.length - 1]) {
        final t = Uint8List.fromList(bytes)..[i] ^= 1;
        expect(() => codec().decode(t), throwsA(anything), reason: 'byte $i');
      }
    });

    test('unencrypted file is rejected with a password unless migrating', () async {
      final bytes = await codec(password: null).encode(plain);
      expect(() => codec().decode(bytes), throwsA(isA<StorageRejectedException>()));
      final doc = await codec(migrate: true).decode(bytes);
      expect(doc.plaintext, plain);
      expect(doc.needsRewrite, isTrue);
    });

    test('encrypted file without a password is rejected', () async {
      final bytes = await codec().encode(plain);
      expect(() => codec(password: null).decode(bytes),
          throwsA(isA<StorageRejectedException>()));
    });

    test('truncated file is a FormatException', () async {
      final bytes = await codec().encode(plain);
      expect(() => codec().decode(bytes.sublist(0, 10)), throwsFormatException);
    });
  });

  group('1.x files', () {
    test('1.x encrypted envelope is read and flagged for rewrite', () async {
      final algo = AesCtr.with128bits(macAlgorithm: Hmac.sha256());
      final box = await algo.encryptString(plain, secretKey: SecretKey(legacyKey));
      final file = jsonEncode({
        'nonce': oldHex(box.nonce),
        'mac': oldHex(box.mac.bytes),
        'cipherText': oldHex(box.cipherText),
      });
      final doc = await codec().decode(utf8.encode(file));
      expect(doc.plaintext, plain);
      expect(doc.needsRewrite, isTrue);
    });

    test('1.x plain JSON follows the migrateUnencrypted rule', () async {
      final file = utf8.encode(plain);
      expect(() => codec().decode(file), throwsA(isA<StorageRejectedException>()));
      expect((await codec(migrate: true).decode(file)).plaintext, plain);
      expect((await codec(password: null).decode(file)).plaintext, plain);
    });

    test('1.x envelope without a password is rejected', () async {
      final file = await encodeLegacyDocument(legacyKey, plain);
      expect(() => codec(password: null).decode(utf8.encode(file)),
          throwsA(isA<StorageRejectedException>()));
    });
  });

  test('hexDecode rejects odd length and bad digits', () {
    expect(hexDecode('0aFF'), [10, 255]);
    expect(() => hexDecode('abc'), throwsFormatException);
    expect(() => hexDecode('zz'), throwsFormatException);
  });

  test('assembled document equals json.encode of the map', () {
    final map = <String, dynamic>{
      'a': 1,
      'quote "x"': ['é', null, 2.5],
      'nested': {'k': true},
    };
    final cache = {for (final e in map.entries) e.key: json.encode(e.value)};
    expect(assembleDocument(cache), json.encode(map));
  });
}
