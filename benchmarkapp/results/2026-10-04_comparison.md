# Comparison: 6 storages × 5 sizes — macOS arm64, OrcaSecureStorage 2.3.1

Release build, Apple Silicon Mac. Every storage and size ran in its own
process of the benchmark app (`BENCH_STORAGES` / `BENCH_ENTRIES`, built with
`--dart-define=AUTORUN=true --dart-define=MEMORY=after --dart-define=KINDS=strings`):
the timing benchmark with strings (~100 characters), then the memory
benchmark with JSON records (~330 bytes), each memory phase in a fresh child
process. Timing operations over 20 s and memory phases over 30 s were
stopped. "–": not measured because the write did not finish. get_storage
was not run at 50,000 and 100,000 entries.

Running storages one after another in the same process skews the results:
storages that run out of time (get_storage, get_secure_storage) keep saving
in the background and slow down the next ones (encrypted Hive measured up to
5× slower that way). SharedPreferences was measured at 50 entries after a
run that cleared the keys earlier timed-out runs left behind (with them,
the first run took 736 ms instead of 5.5 ms).

**Write every entry, until saved (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 0.2 | 1.3 | 9.6 | 111 | 250 |
| Hive CE (encrypted) 🔒 | 1.7 | 16 | 191 | 1.5 s | 3.0 s |
| SharedPreferences | 5.5 | 55 | 517 | > 20 s | > 20 s |
| get_secure_storage 1.0.5 🔒 | 35 | 2.5 s | > 20 s | > 20 s | > 20 s |
| get_storage | 16 | 226 | > 20 s | not run | not run |
| sqflite | 19 | 167 | 2.1 s | 18.8 s | > 20 s |

**Read every entry (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 0 | 0.2 | 2.6 | 24 | 52 |
| Hive CE (encrypted) 🔒 | 0 | 0.4 | 4.3 | 45 | 97 |
| SharedPreferences | 0 | 0.3 | 3.5 | – | – |
| get_secure_storage 1.0.5 🔒 | 0.1 | 0.5 | – | – | – |
| get_storage | 0 | 0.2 | – | not run | not run |
| sqflite | 2.3 | 22 | 234 | 2.2 s | – |

**Open from disk and read every entry (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 1.4 | 2.6 | 13 | 109 | 235 |
| Hive CE (encrypted) 🔒 | 0.7 | 2.9 | 17 | 166 | 348 |
| SharedPreferences | 0.3 | 1.1 | 10 | – | – |
| get_secure_storage 1.0.5 🔒 | 4.2 | 5.5 | – | – | – |
| get_storage | 0.6 | 0.9 | – | not run | not run |
| sqflite | 2.4 | 26 | 239 | 2.2 s | – |

**Delete every entry, until saved (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 0.1 | 0.5 | 4.3 | 38 | 75 |
| Hive CE (encrypted) 🔒 | 1.5 | 14 | 132 | 1.2 s | 2.5 s |
| SharedPreferences | 5.1 | 51 | 560 | – | – |
| get_secure_storage 1.0.5 🔒 | 7.5 | 78 | – | – | – |
| get_storage | 6.1 | 63 | – | not run | not run |
| sqflite | 14 | 162 | 2.2 s | > 20 s | – |

**Update one entry, until saved (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 |
| Hive CE (encrypted) 🔒 | 0.1 | 0.1 | 0.1 | 0.1 | 0.1 |
| SharedPreferences | 0.1 | 0.1 | 0.1 | – | – |
| get_secure_storage 1.0.5 🔒 | 0.5 | 3.5 | – | – | – |
| get_storage | 0.2 | 0.4 | – | not run | not run |
| sqflite | 0.4 | 0.3 | 0.4 | 0.4 | – |

**Memory right after opening (MB)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 1 | 3 | 14 | 89 | 191 |
| Hive CE (encrypted) 🔒 | 1 | 4 | 23 | 168 | 313 |
| SharedPreferences | 0 | 1 | 9 | stopped | stopped |
| get_secure_storage 1.0.5 🔒 | 2 | 9 | stopped | stopped | stopped |
| get_storage | 3 | 2 | stopped | not run | not run |
| sqflite | 0 | 0 | 0 | 0 | stopped |

**Memory after reading every entry (MB)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 2 | 5 | 29 | 174 | 333 |
| Hive CE (encrypted) 🔒 | 1 | 5 | 33 | 174 | 318 |
| SharedPreferences | 0 | 3 | 16 | stopped | stopped |
| get_secure_storage 1.0.5 🔒 | 2 | 9 | stopped | stopped | stopped |
| get_storage | 3 | 4 | stopped | not run | not run |
| sqflite | 1 | 4 | 6 | 13 | stopped |

**Peak memory while writing every entry (MB)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 2 | 5 | 29 | 157 | 277 |
| Hive CE (encrypted) 🔒 | 3 | 7 | 15 | 94 | 183 |
| SharedPreferences | 1 | 4 | 10 | stopped | stopped |
| get_secure_storage 1.0.5 🔒 | 6 | 30 | stopped | stopped | stopped |
| get_storage | 6 | 25 | stopped | not run | not run |
| sqflite | 1 | 4 | 6 | 52 | stopped |

**Longest UI stall while opening (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 3 | 2 | 3 | 3 | 4 |
| Hive CE (encrypted) 🔒 | 3 | 9 | 58 | 446 | 909 |
| SharedPreferences | 0 | 3 | 11 | stopped | stopped |
| get_secure_storage 1.0.5 🔒 | 9 | 17 | stopped | stopped | stopped |
| get_storage | 19 | 4 | stopped | not run | not run |
| sqflite | 0 | 1 | 1 | 2 | stopped |

Superseded by [2026-10-04_comparison_40s.md](2026-10-04_comparison_40s.md), measured with a 40 s limit for every operation and phase.
