# Durability — fsync vs no fsync, macOS arm64

Release build, Apple Silicon Mac, 10,000 strings (~100 characters), headless run of
`lib/main.dart` with the new `durability` setting. "OrcaSecureStorage (key, no fsync)" is
`Durability.os`; every other Orca row uses the default `Durability.fsync`. Times include
waiting until each storage counts the data as saved (see the README's durability table).

| Storage | Encryption | Write ms | Update 1 ms | Read ms | Cold read ms | Delete ms |
|---|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (password) | AES-256-GCM, PBKDF2 key | 20.1 | 0.1 | 5.5 | 54.8 | 20.7 |
| OrcaSecureStorage (key) | AES-256-GCM, raw key | 24.7 | 0.1 | 4.5 | 19.0 | 9.4 |
| OrcaSecureStorage (key, no fsync) | AES-256-GCM, raw key | 25.5 | 0.0 | 5.6 | 20.1 | 8.1 |
| OrcaSecureStorage (no password) | none | 25.8 | 0.1 | 4.4 | 19.1 | 7.5 |
| GetSecureStorage | AES-128-CTR + HMAC | > 20 s (still saving to disk) | – | – | – | – |
| GetStorage | none | > 20 s (still saving to disk) | – | – | – | – |
| Hive CE | none | 277.1 | 0.1 | 6.9 | 20.8 | 251.1 |
| Hive CE (encrypted) | AES-256-CBC | 337.9 | 0.1 | 7.1 | 30.7 | 246.9 |
| SharedPreferences | none | 11433.7 | 0.1 | 5.8 | 22.7 | 1384.1 |
| sqflite | none | 3878.5 | 0.3 | 497.6 | 484.0 | 3520.5 |
| Sembast | none | 864.9 | 0.1 | 10.6 | 29.7 | 1427.0 |

On Apple platforms `fsync` hands data to the drive without flushing the drive's own
cache, so it is cheap and the two Orca key rows are within noise of each other.
Phones (especially Android) usually pay more per fsync; not measured here.
