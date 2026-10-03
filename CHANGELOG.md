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
