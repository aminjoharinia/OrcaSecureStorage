## [2.1.5]
- Docs only: the changelog and `LEGACY_KEY_CHANGES.md` no longer refer to the withdrawn 2.1.3. Same code as 2.1.4.

## [2.1.4]
- **Faster start with a password:** the 1.x key (PBKDF2, 1,000 iterations, pure Dart) is no longer derived on the UI isolate every time a container is opened with a password. It is derived in the background isolate, and only when a 1.x file is actually read. Saves about 3.5 ms per container on a desktop CPU, more on phones. See [LEGACY_KEY_CHANGES.md](LEGACY_KEY_CHANGES.md).
- The deprecated `algorithm` and `secretKey` fields are no longer set (they are now always null).
- README: apps migrating from 1.x should keep passing the password together with an `encryptionKey`.

## [2.1.2]
- README: corrected memory use. The decoded objects on the UI isolate are the large copy (about 5× the JSON); the worker's JSON text is about 1× (up to 2× with non-Latin-1 strings). Documents the short peaks while writing a snapshot and opening a container. No code changes.

## [2.1.1]
- **Fix:** a value that cannot be converted to JSON (e.g. an object without `toJson`) no longer blocks every later save of its container. `write` and `writeInMemory` now convert the value straight away and throw a `JsonUnsupportedObjectError` without storing it. The JSON made there is reused for the save, so values are not encoded twice. A value is saved as it was when written; call `save()` after changing it in place.
- `flush()` now retries a failed save itself (before, only the next write did) and throws only if saving still fails.
- `write` and `writeIfNull` throw synchronously for such values, so the error is not lost when the future is not awaited.
- README: install snippet pins a tag; new section on how a container is held in memory and why.

## [2.1.0]
- **`flush()`**: completes when every change so far is saved (fsynced) and throws the first save error since the last `flush()`. `write`, `remove`, `erase` and `save` still return before the data is saved. A failed save is logged instead of becoming an unhandled error, the changes are saved again with the next one, and an `Error` thrown while saving (e.g. a value `jsonEncode` cannot encode) no longer stops all later saves.
- **Behaviour change:** calling the constructor or `init` for an open container with a different `password`, `encryptionKey`, `path` or `migrateUnencrypted` now throws a `StateError` instead of returning the open container and ignoring them. Calling it without those arguments still returns the open container.
- Rejected files no longer overwrite each other: up to five copies are kept (`.rejected`, `.rejected.2` … `.rejected.5`; the oldest is replaced after that). `deleteContainer` removes them.
- `flutter_lints` 6; `deleteContainer` and `hasContainer` have typed signatures.

## [2.0.0]
- **Renamed to OrcaSecureStorage**: package `orca_secure_storage`, class `OrcaSecureStorage`, import `package:orca_secure_storage/orca_secure_storage.dart`, repository https://github.com/aminjoharinia/OrcaSecureStorage. The default container is now `OrcaSecureStorage`.
- **Change log for updates**: writes append an encrypted, fsynced record to `<container>.osslog` instead of rewriting the container, and are folded into the snapshot after 300 ms without writes, when the log outgrows the snapshot, or when the app is hidden. Single-entry updates cost ~0.1 ms regardless of container size (was ~6 ms at 10,000 entries). Records are bound to their snapshot (fingerprint + sequence number in the AES-GCM additional data, or in the CRC-32 without encryption); torn, stale or damaged logs are detected, and any log not fully applied is kept as `.osslog.rejected`. The backup is now written with each snapshot instead of on every write.
- **Encryption key option**: `encryptionKey` (32 bytes, see `OrcaSecureStorage.generateKey()`) encrypts without deriving a key from a password, so opening a container takes milliseconds instead of ~40 ms. Passing `password` and `encryptionKey` together reads password-protected files (2.x and 1.x) and rewrites them with the key.
- **New file names**: `<container>.oss`, backup `<container>.ossbak`. When there is no `.oss` file, the 1.x / GetStorage files `<container>.gs` / `.bak` are read once, written as `.oss`, and left untouched. The default container also picks up the old `GetSecureStorage.gs`. `deleteContainer` removes both.
- **New file format (format 2).** Containers are stored as a binary file: an `OSS` header, then the JSON compressed with gzip (level 1) and encrypted with AES-256-GCM. The key is derived with PBKDF2-HMAC-SHA256 (600,000 iterations) and a random per-container salt kept in the header; the header is authenticated. Encryption and key derivation use BoringSSL through `package:webcrypto` (the browser's WebCrypto on the web), replacing pure-Dart AES-128-CTR + HMAC. A 15 MB container is now about 2 MB on disk instead of 30 MB.
- **Automatic migration.** 1.x contents (the hex `{nonce, mac, cipherText}` envelope, or plain JSON) are detected and converted. **get_secure_storage 1.x cannot read `.oss` files.**
- Containers without a password also use format 2 (compressed, unencrypted), so they are no longer plain JSON readable by GetStorage.
- Writes no longer re-encode the whole container on the calling (UI) isolate: only changed keys are JSON-encoded there; a long-lived background isolate per container joins them, compresses, encrypts and writes the file. Opening a container also reads, decrypts and decodes in that isolate.
- Files are written atomically (temp file, fsync, rename), so a crash can no longer leave a torn file.
- **Behaviour change:** with a password, a file that is not encrypted is now rejected instead of silently loaded. Pass `migrateUnencrypted: true` to `init` / the constructor to load such a file (e.g. moving from GetStorage) and encrypt it.
- A file that cannot be read with either the main or the backup copy (wrong password, tampering, rejected plaintext) is kept as `<container>.oss.rejected` before the container starts empty, instead of being overwritten.
- `save()` now re-encodes every key, so values changed in place without `write` are persisted.
- `algorithm` and `secretKey` are deprecated; they only hold the 1.x key used to read 1.x files.
- Requires Dart 3.10 (Flutter 3.38) or later. `webcrypto` builds BoringSSL from source when the app is built.

## [1.0.5] 
- Updated package to support Flutter 3.19.5

## [1.0.4] 
- Add method to hasContainer

## [1.0.3] 
- Add method to deleteContainer

## [1.0.2] 
- Update storage to use hexString instead of a string of List<int>
- Made sure moving from GetStorage to/from GetSecureStorage works and recover from wrong pwd

## [1.0.0] 
- Initial release and port of v2.1.0 of GetStorage
