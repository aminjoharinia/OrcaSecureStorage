# OrcaSecureStorage 2.1.4: Lazy 1.x Key

**Date:** 2026-10-03
**Based on:** `v2.1.2`
**Files changed:** `lib/src/storage_impl.dart`, `lib/src/codec.dart`, `test/codec_test.dart`, `README.md`, `CHANGELOG.md`, `pubspec.yaml`
**Files added:** this document

## Summary

Opening a container with a `password` derived the get_secure_storage 1.x key
on the UI isolate every time, whether or not a 1.x file existed. After the
first start, that key is never needed again, but the derivation still ran on
every cold start, once per container.

The 1.x key is now derived **in the background isolate**, and **only when a
1.x file is actually read**. Nothing changes on disk: the file formats are the
same, and 1.x files are read and converted exactly as before.

| | Before (2.1.2) | After (2.1.4) |
|---|---|---|
| Where the 1.x key is derived | UI isolate, in the constructor | Background isolate, in the codec |
| When | Every open with a `password` | The first time a 1.x file is read |
| Cost on a normal start (no 1.x file) | One PBKDF2 per container | None |

## The cost, measured

PBKDF2-HMAC-SHA256, 1,000 iterations, 128 bits, using the pure-Dart
`cryptography` package, as the constructor ran it:

| Build | Time per container |
|---|---|
| AOT (release-like), Apple Silicon Mac | about 3.5 ms (3.2 to 4.0 ms) |
| JIT (debug), first call | about 13 ms |

Phones are typically several times slower than a desktop CPU. An app with
two containers paid this twice in a row before its first screen, on the
thread that draws frames.

## What changed

### `lib/src/storage_impl.dart`

Before, the constructor derived the key and passed it in the config:

```dart
if (password != null) {
  algorithm = AesCtr.with128bits(macAlgorithm: Hmac.sha256());
  final pbkdf2 = Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: 1000, bits: 128);
  secretKey = await pbkdf2.deriveKeyFromPassword(
    password: password,
    nonce: password.runes.toList().reversed.toList(),
  );
}
await _init(StorageCodecConfig(
  password: password,
  legacyKeyBytes: await secretKey?.extractBytes(),
  ...
));
```

After, it passes only the password:

```dart
await _init(StorageCodecConfig(
  password: password,
  ...
));
```

The deprecated public fields `algorithm` and `secretKey` are no longer set.
Nothing in the package used them; they stay so that code referring to them
still compiles.

### `lib/src/codec.dart`

- New top-level `deriveLegacyKey(String password)`: the same derivation as
  1.x (PBKDF2-HMAC-SHA256, 1,000 iterations, the reversed password as salt,
  128 bits).
- `_decodeLegacy` gets the key from `_legacyKey()`, which returns
  `config.legacyKeyBytes` when given, and otherwise derives it from
  `config.password` the first time and keeps it. The `.bak` file tried after
  an unreadable `.gs` reuses it.
- `StorageCodecConfig.legacyKeyBytes` is still accepted, so callers that pass
  a key keep working.

The codec runs in the background isolate on the `dart:io` platforms, so the
derivation now happens there. On the web, the codec runs on the main thread
as before, but still only when a 1.x value is found.

## Compatibility

- **On disk:** no change. 2.1.4 reads and writes the same files as 2.1.2.
- **1.x files:** converted as before, with the password alone or with the
  password and an `encryptionKey`.
- **API:** no change, except that `algorithm` and `secretKey` stay null.

## Tests

Two tests were added to `test/codec_test.dart`:

1. **"the 1.x key is derived exactly as 1.x did":** compares
   `deriveLegacyKey` with the 1.x constructor code, kept verbatim, using a
   real-world password.
2. **"without legacyKeyBytes, the 1.x key is derived from the password":**
   reads a 1.x envelope with only a password, and with a password plus an
   `encryptionKey`; a wrong password is rejected.

The existing `.gs` tests in `test/storage_io_test.dart` open containers with
a password only, so they now run the lazy path end to end (conversion, the
`.bak` fallback, and conversion straight to an `encryptionKey`).

`dart analyze lib test`: no issues. `flutter test`: 61 tests pass.

## Advice for apps migrating from get_secure_storage 1.x

Keep passing the password with the key, permanently:

```dart
await OrcaSecureStorage.init(
  container: 'Main',
  password: oldPassword,     // reads 1.x files whenever they turn up
  encryptionKey: appKey,     // every file is written with this
);
```

1.x files can still appear after the first conversion: users who update
late, or a phone backup from before the update restored on another device.
With the key alone, such a container opens empty, and the empty `.oss`
written then means the 1.x file is never tried again. With this release,
passing the password costs nothing when no 1.x file is present, and the
password's PBKDF2 never runs, because files are written with the key.
