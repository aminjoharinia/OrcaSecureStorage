import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as legacy;
import 'package:webcrypto/webcrypto.dart';

/// Everything needed to encode and decode a container file. Plain data only,
/// so it can be sent to the background writer isolate.
class StorageCodecConfig {
  const StorageCodecConfig({
    this.password,
    this.keyBytes,
    this.legacyKeyBytes,
    this.migrateUnencrypted = false,
    this.kdfIterations = 600000,
    this.nonceField = 'nonce',
    this.macField = 'mac',
    this.cipherTextField = 'cipherText',
  });

  /// Encrypts the container when set. The AES-256 key is derived from it with
  /// PBKDF2-SHA256 and a random per-container salt stored in the file header.
  final String? password;

  /// A random 256-bit AES key the app keeps itself (e.g. in the Keychain /
  /// Android Keystore). No key derivation, so opening is fast. When set, new
  /// files use it even if [password] is also given; the password is then only
  /// used to read files written with it, which are rewritten with this key.
  final List<int>? keyBytes;

  /// The 1.x AES-128 key (PBKDF2, 1000 iterations), used only to read 1.x
  /// files before they are rewritten in the current format. When null, it is
  /// derived from [password] the first time a 1.x file is read.
  final List<int>? legacyKeyBytes;

  /// With a password set, accept data that is not encrypted (e.g. a
  /// get_storage file) and encrypt it. Off by default: such a file could have
  /// been swapped in by anyone able to write the app's files.
  final bool migrateUnencrypted;

  /// PBKDF2 iterations for new files (OWASP 2023 figure for SHA-256). Files
  /// keep the count they were written with, read from their header.
  final int kdfIterations;

  final String nonceField;
  final String macField;
  final String cipherTextField;

  bool get encrypted => password != null || keyBytes != null;
}

/// Thrown when a file cannot be accepted: wrong password, tampering, an
/// unsupported format, or unencrypted data while
/// [StorageCodecConfig.migrateUnencrypted] is off.
class StorageRejectedException implements Exception {
  StorageRejectedException(this.message);
  final String message;
  @override
  String toString() => 'StorageRejectedException: $message';
}

/// The plaintext of a decoded file and whether the file should be rewritten
/// in the current format (it was 1.x, or its encryption differs from config).
class DecodedDocument {
  DecodedDocument(this.plaintext, {required this.needsRewrite, this.compressed});
  final String plaintext;
  final bool needsRewrite;

  /// The decrypted, still compressed bytes, when the file was compressed:
  /// several times smaller than [plaintext] to send to another isolate.
  final List<int>? compressed;
}

typedef BytesTransform = List<int> Function(List<int> input);
typedef BytesConverter = Converter<List<int>, List<int>>;

// Format 2 (format 1 is the 1.x JSON files), all integers big-endian:
//
//   'O' 'S' 'S'              magic
//   u8  version              2
//   u8  flags                bit 0: payload is gzip, bit 1: encrypted,
//                            bit 2: snapshot id follows (unencrypted files)
//   if bit 2:
//     u8  id length, id      random; makes every snapshot's fingerprint
//                            unique even when the content repeats
//   if encrypted:
//     u8  kdf                1 = PBKDF2-HMAC-SHA256 from a password,
//                            2 = raw key supplied by the app
//     u32 iterations         0 for a raw key
//     u8  salt length, salt  empty for a raw key
//     12  AES-GCM nonce
//   payload                  (gzip of) UTF-8 JSON; when encrypted,
//                            AES-256-GCM ciphertext + 16-byte tag, with the
//                            header above as additional authenticated data
const List<int> _magic = [0x4F, 0x53, 0x53]; // 'OSS'
const int _version = 2;
const int _flagCompressed = 1;
const int _flagEncrypted = 2;
const int _flagSnapshotId = 4;
const int _snapshotIdLength = 16;
const int _kdfPbkdf2Sha256 = 1;
const int _kdfRawKey = 2;
const int _nonceLength = 12;
const int _saltLength = 16;
const List<int> _logMagic = [0x4F, 0x53, 0x4C]; // 'OSL'
const int _logVersion = 1;

/// Whether [bytes] start with the current format's magic.
bool isCurrentFormat(List<int> bytes) {
  if (bytes.length < _magic.length) return false;
  for (var i = 0; i < _magic.length; i++) {
    if (bytes[i] != _magic[i]) return false;
  }
  return true;
}

/// Encodes and decodes container files. Keeps the derived key so PBKDF2 runs
/// once per container, not per write.
class StorageCodec {
  StorageCodec(this.config, {this.compress, this.decompress});

  final StorageCodecConfig config;

  /// gzip on platforms that have it (`dart:io`); null writes uncompressed.
  final BytesConverter? compress;
  final BytesConverter? decompress;

  Uint8List? _salt;
  int _iterations = 0;
  AesGcmSecretKey? _key;
  AesGcmSecretKey? _rawKey;

  /// The key of the snapshot last written or read. Log records belong to a
  /// snapshot, so they use its key.
  AesGcmSecretKey? _snapshotKey;

  Future<AesGcmSecretKey> _rawKeyFor() async =>
      _rawKey ??= await AesGcmSecretKey.importRawKey(config.keyBytes!);

  Future<AesGcmSecretKey> _keyFor(Uint8List salt, int iterations) async {
    final cached = _key;
    if (cached != null && iterations == _iterations && _sameBytes(salt, _salt!)) {
      return cached;
    }
    final pbkdf2 = await Pbkdf2SecretKey.importRawKey(utf8.encode(config.password!));
    final bits = await pbkdf2.deriveBits(256, Hash.sha256, salt, iterations);
    final key = await AesGcmSecretKey.importRawKey(bits);
    _salt = salt;
    _iterations = iterations;
    _key = key;
    return key;
  }

  Future<Uint8List> encode(String plaintext) {
    final gz = compress;
    final bytes = utf8.encode(plaintext);
    return gz == null ? _seal(bytes, 0) : _seal(gz.convert(bytes), _flagCompressed);
  }

  /// Like `encode(assembleDocument(encodedValues))`, without ever holding the
  /// whole document: it is built and turned into UTF-8 in pieces of about
  /// 64 KB, each compressed right away. A snapshot of a 15 MB container
  /// otherwise holds two extra full copies (the text and its UTF-8 bytes).
  Future<Uint8List> encodeDocument(Map<String, String> encodedValues) {
    final gz = compress;
    if (gz == null) return encode(assembleDocument(encodedValues));
    final out = BytesBuilder(copy: true);
    final utf8Sink = utf8.encoder
        .startChunkedConversion(gz.startChunkedConversion(_BytesBuilderSink(out)));
    final piece = StringBuffer();
    void write(String s) {
      piece.write(s);
      if (piece.length >= _pieceLength) {
        utf8Sink.add(piece.toString());
        piece.clear();
      }
    }

    write('{');
    var first = true;
    encodedValues.forEach((key, value) {
      if (!first) write(',');
      first = false;
      write(json.encode(key));
      write(':');
      write(value);
    });
    write('}');
    utf8Sink
      ..add(piece.toString())
      ..close();
    return _seal(out.takeBytes(), _flagCompressed);
  }

  /// Adds the header and, when configured, encrypts [payload].
  Future<Uint8List> _seal(List<int> payload, int flags) async {
    final header = BytesBuilder(copy: false)
      ..add(_magic)
      ..addByte(_version);
    if (!config.encrypted) {
      // Encrypted files are unique through their nonce; give unencrypted
      // ones a random id so a change log can tell snapshots apart.
      final id = Uint8List(_snapshotIdLength);
      fillRandomBytes(id);
      header
        ..addByte(flags | _flagSnapshotId)
        ..addByte(id.length)
        ..add(id);
      return (BytesBuilder(copy: false)
            ..add(header.takeBytes())
            ..add(payload))
          .takeBytes();
    }

    flags |= _flagEncrypted;
    final AesGcmSecretKey key;
    header.addByte(flags);
    if (config.keyBytes != null) {
      key = await _rawKeyFor();
      header
        ..addByte(_kdfRawKey)
        ..add(_u32(0))
        ..addByte(0);
    } else {
      if (_salt == null) {
        final salt = Uint8List(_saltLength);
        fillRandomBytes(salt);
        _salt = salt;
        _iterations = config.kdfIterations;
      }
      key = await _keyFor(_salt!, _iterations);
      header
        ..addByte(_kdfPbkdf2Sha256)
        ..add(_u32(_iterations))
        ..addByte(_salt!.length)
        ..add(_salt!);
    }
    _snapshotKey = key;
    final nonce = Uint8List(_nonceLength);
    fillRandomBytes(nonce);
    header.add(nonce);
    final headerBytes = header.takeBytes();
    final cipherText = await key.encryptBytes(payload, nonce, additionalData: headerBytes);
    return (BytesBuilder(copy: false)
          ..add(headerBytes)
          ..add(cipherText))
        .takeBytes();
  }

  /// Decodes a file in the current format or any 1.x format.
  Future<DecodedDocument> decode(Uint8List bytes) async {
    if (!isCurrentFormat(bytes)) {
      final plaintext = await _decodeLegacy(utf8.decode(bytes));
      return DecodedDocument(plaintext, needsRewrite: true);
    }

    final r = _Reader(bytes)..skip(_magic.length);
    final version = r.byte();
    if (version != _version) {
      throw StorageRejectedException('unsupported format version $version');
    }
    final flags = r.byte();
    final encrypted = flags & _flagEncrypted != 0;
    // A password-protected file opened with a key as well: convert it.
    var toRawKey = false;
    List<int> payload;
    if (encrypted) {
      if (!config.encrypted) {
        throw StorageRejectedException('file is encrypted but no password or key was given');
      }
      final kdf = r.byte();
      final iterations = r.u32();
      final salt = r.bytes(r.byte());
      final nonce = r.bytes(_nonceLength);
      final header = Uint8List.sublistView(bytes, 0, r.offset);
      final AesGcmSecretKey key;
      switch (kdf) {
        case _kdfPbkdf2Sha256:
          if (config.password == null) {
            throw StorageRejectedException(
                'file is protected by a password; pass it (with encryptionKey to convert the file)');
          }
          key = await _keyFor(salt, iterations);
          toRawKey = config.keyBytes != null;
        case _kdfRawKey:
          if (config.keyBytes == null) {
            throw StorageRejectedException('file uses an encryption key; none was given');
          }
          key = await _rawKeyFor();
        default:
          throw StorageRejectedException('unknown KDF $kdf');
      }
      try {
        payload = await key.decryptBytes(r.rest(), nonce, additionalData: header);
      } on OperationError {
        throw StorageRejectedException('wrong password or key, or tampered file');
      }
      _snapshotKey = key;
    } else {
      if (config.encrypted && !config.migrateUnencrypted) {
        throw StorageRejectedException('file is not encrypted');
      }
      if (flags & _flagSnapshotId != 0) r.skip(r.byte());
      payload = r.rest();
    }
    final needsRewrite = encrypted != config.encrypted || toRawKey;
    if (flags & _flagCompressed != 0) {
      final gunzip = decompress;
      if (gunzip == null) {
        throw StorageRejectedException('compressed file, no decompressor here');
      }
      // Decompressed and decoded in pieces: the uncompressed bytes are never
      // held in full.
      late String text;
      final sink = gunzip.startChunkedConversion(utf8.decoder
          .startChunkedConversion(StringConversionSink.withCallback((s) => text = s)));
      sink
        ..add(payload)
        ..close();
      return DecodedDocument(text, needsRewrite: needsRewrite, compressed: payload);
    }
    return DecodedDocument(utf8.decode(payload), needsRewrite: needsRewrite);
  }

  // ---- Change log --------------------------------------------------------
  //
  // <container>.osslog holds changes made since the snapshot (.oss) was
  // written, so an update appends a small record instead of rewriting the
  // whole file. All integers big-endian:
  //
  //   'O' 'S' 'L'              magic
  //   u8  version              1
  //   u8  flags                bit 1: encrypted
  //   16  snapshot fingerprint first 16 bytes of SHA-256 of the .oss bytes
  //   records:
  //     u32 body length
  //     body                   encrypted: 12-byte nonce + AES-256-GCM
  //                            ciphertext + tag, with additional data
  //                            'OSL' + fingerprint + u32 sequence number;
  //                            otherwise: u32 CRC-32 of ('OSL' + fingerprint +
//                            u32 sequence number + payload), then payload
  //
  // The payload is UTF-8 JSON {"r": reset, "s": {key: value}, "d": [key]}.
  // The fingerprint ties a log to one snapshot: a log whose fingerprint does
  // not match is from before the last snapshot and already included in it.

  static const logHeaderLength = 21;

  /// First 16 bytes of the SHA-256 of a snapshot file.
  static Future<Uint8List> fingerprintOf(List<int> snapshotBytes) async =>
      Uint8List.sublistView(await Hash.sha256.digestBytes(snapshotBytes), 0, 16);

  bool get _logEncrypted => config.encrypted;

  Uint8List logHeader(Uint8List fingerprint) => (BytesBuilder(copy: false)
        ..add(_logMagic)
        ..addByte(_logVersion)
        ..addByte(_logEncrypted ? _flagEncrypted : 0)
        ..add(fingerprint))
      .takeBytes();

  /// The fingerprint in a log header, or null if [bytes] do not start with a
  /// valid header for this container's encryption.
  Uint8List? readLogHeader(Uint8List bytes) {
    if (bytes.length < logHeaderLength) return null;
    for (var i = 0; i < _logMagic.length; i++) {
      if (bytes[i] != _logMagic[i]) return null;
    }
    if (bytes[3] != _logVersion) return null;
    if ((bytes[4] & _flagEncrypted != 0) != _logEncrypted) return null;
    return Uint8List.fromList(Uint8List.sublistView(bytes, 5, logHeaderLength));
  }

  /// One record, length prefix included. Built as bytes throughout: a
  /// `List<int>` takes 8 bytes per element, so spreading a 15 MB record into
  /// one used to cost about 500 MB.
  Future<Uint8List> encodeLogRecord(String payload, Uint8List fingerprint, int seq) async {
    final plain = utf8.encode(payload);
    final List<int> check;
    final List<int> data;
    if (_logEncrypted) {
      final key = _snapshotKey;
      if (key == null) throw StateError('no snapshot key for the change log');
      final nonce = Uint8List(_nonceLength);
      fillRandomBytes(nonce);
      check = nonce;
      data = await key.encryptBytes(plain, nonce, additionalData: _logAad(fingerprint, seq));
    } else {
      check = _u32(crc32(plain, crc32(_logAad(fingerprint, seq))));
      data = plain;
    }
    return (BytesBuilder(copy: false)
          ..add(_u32(check.length + data.length))
          ..add(check)
          ..add(data))
        .takeBytes();
  }

  /// The payload of a record body, or null if it fails its check (torn
  /// write, corruption, tampering, or wrong key).
  Future<String?> decodeLogRecord(Uint8List body, Uint8List fingerprint, int seq) async {
    try {
      if (_logEncrypted) {
        final key = _snapshotKey;
        if (key == null || body.length < _nonceLength + 16) return null;
        final plain = await key.decryptBytes(
          Uint8List.sublistView(body, _nonceLength),
          Uint8List.sublistView(body, 0, _nonceLength),
          additionalData: _logAad(fingerprint, seq),
        );
        return utf8.decode(plain);
      }
      if (body.length < 4) return null;
      final crc = (body[0] << 24) | (body[1] << 16) | (body[2] << 8) | body[3];
      final plain = Uint8List.sublistView(body, 4);
      if (crc32(plain, crc32(_logAad(fingerprint, seq))) != crc) return null;
      return utf8.decode(plain);
    } on OperationError {
      return null;
    } on FormatException {
      return null;
    }
  }

  static List<int> _logAad(Uint8List fingerprint, int seq) =>
      [..._logMagic, ...fingerprint, ..._u32(seq)];

  List<int>? _derivedLegacyKey;

  /// The 1.x key: given in the config, or derived from the password the
  /// first time a 1.x file is read (and then kept for its backup file).
  Future<List<int>?> _legacyKey() async {
    final given = config.legacyKeyBytes;
    if (given != null) return given;
    final password = config.password;
    if (password == null) return null;
    return _derivedLegacyKey ??= await deriveLegacyKey(password);
  }

  // 1.x files are UTF-8 JSON: either the `{nonce, mac, cipherText}` hex
  // envelope (AES-128-CTR + HMAC-SHA256) or the plain container.
  Future<String> _decodeLegacy(String content) async {
    final payload = json.decode(content);
    final isEnvelope = payload is Map &&
        payload.containsKey(config.cipherTextField) &&
        payload.containsKey(config.macField) &&
        payload.containsKey(config.nonceField);

    if (!isEnvelope) {
      if (payload is! Map) throw const FormatException('container is not a JSON object');
      if (config.encrypted && !config.migrateUnencrypted) {
        throw StorageRejectedException('file is not encrypted');
      }
      return content;
    }

    final key = await _legacyKey();
    if (key == null) {
      throw StorageRejectedException('1.x encrypted file; pass the password to read it');
    }
    final nonce = payload[config.nonceField];
    final mac = payload[config.macField];
    final cipherText = payload[config.cipherTextField];
    if (nonce is! String || mac is! String || cipherText is! String) {
      throw StorageRejectedException('malformed envelope');
    }
    final box = legacy.SecretBox(hexDecode(cipherText),
        nonce: hexDecode(nonce), mac: legacy.Mac(hexDecode(mac)));
    try {
      return await _legacyAlgorithm().decryptString(box, secretKey: legacy.SecretKey(key));
    } on legacy.SecretBoxAuthenticationError {
      throw StorageRejectedException('wrong password or tampered file');
    }
  }
}

legacy.AesCtr _legacyAlgorithm() =>
    legacy.AesCtr.with128bits(macAlgorithm: legacy.Hmac.sha256());

/// The 1.x AES-128 key: PBKDF2-HMAC-SHA256, 1000 iterations, the reversed
/// password as salt.
Future<List<int>> deriveLegacyKey(String password) async {
  final key = await legacy.Pbkdf2(
    macAlgorithm: legacy.Hmac.sha256(),
    iterations: 1000,
    bits: 128,
  ).deriveKeyFromPassword(
    password: password,
    nonce: password.runes.toList().reversed.toList(),
  );
  return key.extractBytes();
}

/// Writes a 1.x hex envelope. Only used to test reading old files.
Future<String> encodeLegacyDocument(List<int> keyBytes, String plaintext) async {
  final box = await _legacyAlgorithm()
      .encryptString(plaintext, secretKey: legacy.SecretKey(keyBytes));
  return json.encode({
    'nonce': hexEncode(box.nonce),
    'mac': hexEncode(box.mac.bytes),
    'cipherText': hexEncode(box.cipherText),
  });
}

const int _pieceLength = 64 * 1024;

class _BytesBuilderSink implements Sink<List<int>> {
  _BytesBuilderSink(this._out);
  final BytesBuilder _out;
  @override
  void add(List<int> data) => _out.add(data);
  @override
  void close() {}
}

/// Builds `{"k1":v1,"k2":v2}` from already-encoded values. The result equals
/// `json.encode` of the original map with the same key order.
String assembleDocument(Map<String, String> encodedValues) {
  final sb = StringBuffer('{');
  var first = true;
  encodedValues.forEach((key, value) {
    if (!first) sb.write(',');
    first = false;
    sb
      ..write(json.encode(key))
      ..write(':')
      ..write(value);
  });
  sb.write('}');
  return sb.toString();
}

/// The reverse of [assembleDocument]: each top-level key of the JSON object
/// [text] with its value's JSON text, without decoding the values (which
/// would cost about 6× the text in objects). Checks the object's own syntax;
/// a value's inside is only scanned for where it ends, so [text] must come
/// from a trusted, integrity-checked source.
Map<String, String> splitDocument(String text) {
  final out = <String, String>{};
  var i = _skipSpace(text, 0);
  if (i >= text.length || text.codeUnitAt(i) != _openBrace) {
    throw const FormatException('container is not a JSON object');
  }
  i = _skipSpace(text, i + 1);
  if (i < text.length && text.codeUnitAt(i) == _closeBrace) {
    i++;
  } else {
    while (true) {
      if (i >= text.length || text.codeUnitAt(i) != _quote) {
        throw FormatException('expected a key', text, i);
      }
      final keyEnd = _stringEnd(text, i);
      final raw = text.substring(i + 1, keyEnd - 1);
      final key = raw.contains(r'\') ? json.decode(text.substring(i, keyEnd)) as String : raw;
      i = _skipSpace(text, keyEnd);
      if (i >= text.length || text.codeUnitAt(i) != _colon) {
        throw FormatException('expected ":"', text, i);
      }
      i = _skipSpace(text, i + 1);
      final start = i;
      i = _valueEnd(text, i);
      out[key] = text.substring(start, i);
      i = _skipSpace(text, i);
      final c = i < text.length ? text.codeUnitAt(i) : -1;
      if (c == _comma) {
        i = _skipSpace(text, i + 1);
      } else if (c == _closeBrace) {
        i++;
        break;
      } else {
        throw FormatException('expected "," or "}"', text, i);
      }
    }
  }
  if (_skipSpace(text, i) != text.length) {
    throw FormatException('text after the object', text, i);
  }
  return out;
}

const int _quote = 0x22, _backslash = 0x5C, _comma = 0x2C, _colon = 0x3A;
const int _openBrace = 0x7B, _closeBrace = 0x7D, _openBracket = 0x5B, _closeBracket = 0x5D;

bool _isSpace(int c) => c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09;

int _skipSpace(String s, int i) {
  while (i < s.length && _isSpace(s.codeUnitAt(i))) {
    i++;
  }
  return i;
}

/// Index just after the string that starts at [i] (an opening quote).
int _stringEnd(String s, int i) {
  for (i++; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == _backslash) {
      i++;
    } else if (c == _quote) {
      return i + 1;
    }
  }
  throw FormatException('unterminated string', s, i);
}

/// Index just after the value that starts at [i].
int _valueEnd(String s, int i) {
  if (i >= s.length) throw FormatException('expected a value', s, i);
  final first = s.codeUnitAt(i);
  if (first == _quote) return _stringEnd(s, i);
  if (first == _openBrace || first == _openBracket) {
    var depth = 0;
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == _quote) {
        i = _stringEnd(s, i);
        continue;
      }
      if (c == _openBrace || c == _openBracket) {
        depth++;
      } else if (c == _closeBrace || c == _closeBracket) {
        if (--depth == 0) return i + 1;
      }
      i++;
    }
    throw FormatException('unterminated value', s, i);
  }
  final start = i;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (c == _comma || c == _closeBrace || c == _closeBracket || _isSpace(c)) break;
    i++;
  }
  if (i == start) throw FormatException('expected a value', s, i);
  return i;
}

const String _hexDigits = '0123456789abcdef';

/// Lowercase hex, one allocation for the whole buffer.
String hexEncode(List<int> bytes) {
  final out = Uint8List(bytes.length * 2);
  for (var i = 0; i < bytes.length; i++) {
    final b = bytes[i];
    out[2 * i] = _hexDigits.codeUnitAt(b >> 4);
    out[2 * i + 1] = _hexDigits.codeUnitAt(b & 0x0f);
  }
  return String.fromCharCodes(out);
}

int _hexNibble(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30; // 0-9
  if (c >= 0x61 && c <= 0x66) return c - 0x57; // a-f
  if (c >= 0x41 && c <= 0x46) return c - 0x37; // A-F
  throw FormatException('Invalid hex digit', String.fromCharCode(c));
}

Uint8List hexDecode(String hex) {
  if (hex.length.isOdd) throw FormatException('Odd-length hex string', hex.length);
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = (_hexNibble(hex.codeUnitAt(2 * i)) << 4) | _hexNibble(hex.codeUnitAt(2 * i + 1));
  }
  return out;
}

List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class _Reader {
  _Reader(this._bytes);
  final Uint8List _bytes;
  int offset = 0;

  void _need(int n) {
    if (offset + n > _bytes.length) throw const FormatException('truncated file');
  }

  void skip(int n) {
    _need(n);
    offset += n;
  }

  int byte() {
    _need(1);
    return _bytes[offset++];
  }

  int u32() {
    _need(4);
    final v = (_bytes[offset] << 24) |
        (_bytes[offset + 1] << 16) |
        (_bytes[offset + 2] << 8) |
        _bytes[offset + 3];
    offset += 4;
    return v;
  }

  Uint8List bytes(int n) {
    _need(n);
    final out = Uint8List.fromList(Uint8List.sublistView(_bytes, offset, offset + n));
    offset += n;
    return out;
  }

  Uint8List rest() => Uint8List.sublistView(_bytes, offset);
}

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

/// CRC-32 (IEEE), for detecting torn or corrupted log records. Pass the
/// CRC of earlier bytes as [crc] to continue it: `crc32(b, crc32(a))` is the
/// CRC of `a` followed by `b`.
int crc32(List<int> bytes, [int crc = 0]) {
  var c = crc ^ 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
