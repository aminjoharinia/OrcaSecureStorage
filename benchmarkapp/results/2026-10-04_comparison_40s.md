# Comparison with a 40 s limit: 6 storages × 5 sizes — macOS arm64, OrcaSecureStorage 2.4.0

Release build, Apple Silicon Mac. Every storage and size ran in its own
process of the benchmark app, with its own storage names
(`BENCH_STORAGES`, `BENCH_ENTRIES`, `BENCH_PREFIX`, `MEM_PREFIX`; built with
`--dart-define=AUTORUN=true --dart-define=MEMORY=after --dart-define=KINDS=strings --dart-define=LIMIT=40`):
the timing benchmark with strings (~100 characters), then the memory
benchmark with JSON records (~330 bytes), each memory phase in a fresh child
process. Timing operations and memory phases over 40 s were stopped. "–":
not measured because the write did not finish. Bold: the best (lowest)
number of each column. Single runs.

**Write every entry, until saved (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | **0.2** | **0.8** | **20** | **129** | **252** |
| Hive CE (encrypted) 🔒 | 1.4 | 19 | 173 | 1.6 s | 3.3 s |
| SharedPreferences | 9.1 | 56 | 513 | > 40 s | > 40 s |
| get_secure_storage 1.0.5 🔒 | 36 | 2.5 s | > 40 s | > 40 s | > 40 s |
| get_storage | 19 | 239 | 22.1 s | > 40 s | > 40 s |
| sqflite | 17 | 215 | 2.0 s | 17.6 s | 37.2 s |

**Read every entry (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | **0** | **0.3** | 2.4 | **28** | **56** |
| Hive CE (encrypted) 🔒 | **0** | 0.4 | 3.5 | 45 | 88 |
| SharedPreferences | **0** | **0.3** | 2.9 | – | – |
| get_secure_storage 1.0.5 🔒 | 0.1 | 0.5 | – | – | – |
| get_storage | **0** | **0.3** | **1.8** | – | – |
| sqflite | 2 | 34 | 240 | 2.2 s | 5.0 s |

**Open from disk and read every entry (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 2.3 | 2.7 | 11 | **118** | **257** |
| Hive CE (encrypted) 🔒 | 0.8 | 2.1 | 18 | 163 | 345 |
| SharedPreferences | **0.3** | 1.2 | 12 | – | – |
| get_secure_storage 1.0.5 🔒 | 3.3 | 6.4 | – | – | – |
| get_storage | 0.6 | **0.9** | **4.6** | – | – |
| sqflite | 4 | 26 | 247 | 2.1 s | 4.9 s |

**Delete every entry, until saved (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | **0.2** | **0.7** | **7** | **42** | **103** |
| Hive CE (encrypted) 🔒 | 1.6 | 18 | 130 | 1.4 s | 2.7 s |
| SharedPreferences | 6 | 50 | 555 | – | – |
| get_secure_storage 1.0.5 🔒 | 9.6 | 82 | – | – | – |
| get_storage | 10 | 67 | 655 | – | – |
| sqflite | 13 | 244 | 1.4 s | 14.8 s | 37.1 s |

**Update one entry, until saved (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | **0.1** | **0.1** | **0.1** | **0.1** | **0.1** |
| Hive CE (encrypted) 🔒 | **0.1** | **0.1** | **0.1** | **0.1** | **0.1** |
| SharedPreferences | **0.1** | **0.1** | **0.1** | – | – |
| get_secure_storage 1.0.5 🔒 | 0.5 | 3.4 | – | – | – |
| get_storage | 0.3 | 0.5 | 4.1 | – | – |
| sqflite | 0.4 | 0.3 | 0.3 | 0.3 | 0.4 |

**Memory right after opening (MB)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 2 | 3 | 16 | 98 | **193** |
| Hive CE (encrypted) 🔒 | 1 | 4 | 23 | 168 | 313 |
| SharedPreferences | **0** | 1 | 9 | stopped (> 40 s) | stopped (> 40 s) |
| get_secure_storage 1.0.5 🔒 | 2 | 9 | stopped (> 40 s) | stopped (> 40 s) | stopped (> 40 s) |
| get_storage | 1 | 5 | stopped (> 40 s) | stopped (> 40 s) | stopped (> 40 s) |
| sqflite | 1 | **0** | **1** | **1** | stopped (> 40 s) |

**Memory after reading every entry (MB)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 2 | 6 | 31 | 183 | 333 |
| Hive CE (encrypted) 🔒 | **1** | 5 | 33 | 174 | **318** |
| SharedPreferences | **1** | **4** | 16 | stopped (> 40 s) | stopped (> 40 s) |
| get_secure_storage 1.0.5 🔒 | 2 | 9 | stopped (> 40 s) | stopped (> 40 s) | stopped (> 40 s) |
| get_storage | 3 | 7 | stopped (> 40 s) | stopped (> 40 s) | stopped (> 40 s) |
| sqflite | **1** | **4** | **6** | **13** | stopped (> 40 s) |

**Peak memory while writing every entry (MB)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 2 | 6 | 31 | 154 | 285 |
| Hive CE (encrypted) 🔒 | 3 | 7 | 15 | 94 | **183** |
| SharedPreferences | **1** | **4** | **12** | stopped (> 40 s) | stopped (> 40 s) |
| get_secure_storage 1.0.5 🔒 | 6 | 30 | stopped (> 40 s) | stopped (> 40 s) | stopped (> 40 s) |
| get_storage | 53 | 25 | stopped (> 40 s) | stopped (> 40 s) | stopped (> 40 s) |
| sqflite | **1** | **4** | 51 | **59** | stopped (> 40 s) |

**Longest UI stall while opening (ms)**

| Storage | 50 | 500 | 5,000 | 50,000 | 100,000 |
|---|---:|---:|---:|---:|---:|
| OrcaSecureStorage (key) 🔒 | 3 | 3 | **2** | 3 | **5** |
| Hive CE (encrypted) 🔒 | 3 | 9 | 56 | 459 | 908 |
| SharedPreferences | **0** | **2** | 10 | stopped (> 40 s) | stopped (> 40 s) |
| get_secure_storage 1.0.5 🔒 | 9 | 17 | stopped (> 40 s) | stopped (> 40 s) | stopped (> 40 s) |
| get_storage | 3 | 41 | stopped (> 40 s) | stopped (> 40 s) | stopped (> 40 s) |
| sqflite | 2 | **2** | 3 | **2** | stopped (> 40 s) |
