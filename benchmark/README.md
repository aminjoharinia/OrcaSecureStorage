# Storage comparison

Compares these implementations (pick with `--dart-define=IMPLS=...`; the
default is `get_storage,gslender,v2`):

| Name in results | Source |
|---|---|
| `v2` | This repo, OrcaSecureStorage (`..`): format 2 (gzip-1 + AES-256-GCM via BoringSSL, raw binary), background writer isolate, per-key JSON cache, atomic writes |
| `fork_v1` | The BOOFI copy (`FORK_PATH`), with encryption via `compute()` and the backup encrypted once; vendored as `get_secure_storage_fork_v1` |
| `gslender 1.0.5` | https://github.com/gslender/get_secure_storage, vendored as `get_secure_storage_gslender` |
| `get_storage` | https://github.com/jonataslaw/get_storage, unencrypted baseline |

## Setup

```bash
./tool/setup.sh
```

This clones both upstream repos and copies the BOOFI fork into `third_party/` (ignored by git), renaming the secure packages so they can share one pubspec. get_storage's
GitHub master targets `get` 5, while both secure packages resolve `get` 4.7.x, so
the script adds `!` to six `subject.value` uses in get_storage's `io.dart`.
That's behaviour-neutral, because `value` is always initialised.

If the BOOFI copy lives somewhere else, run with `FORK_PATH=<path> ./tool/setup.sh`.

## Tests

| File | What it checks |
|---|---|
| `test/suite_get_storage_test.dart` | get_storage's own `test/getstorage_test.dart`, run against get_storage |
| `test/suite_fork_test.dart` | The same suite against this repo, without and with a password |
| `test/suite_gslender_test.dart` | The same suite against gslender 1.0.5, without and with a password |
| `test/compat_test.dart` | `.gs` files written by gslender 1.0.5, fork v1 and get_storage open in OrcaSecureStorage intact, are written as `.oss`, and the `.gs` files are left untouched |
| `test/benchmark_test.dart` | 5 / 10 / 15 MB accounting-data read/write benchmark |

```bash
flutter test test/suite_get_storage_test.dart test/suite_fork_test.dart test/suite_gslender_test.dart test/compat_test.dart
```

Run the benchmark on its own, so no other test file competes for CPU:

```bash
flutter test test/benchmark_test.dart
```

Options: `--dart-define=IMPLS=get_storage,gslender,fork_v1,v2`, `--dart-define=SIZES=5,10,15`, `--dart-define=RUNS=3`, `--dart-define=UPDATES=5`.
Results are written to `results/benchmark_<timestamp>.md` and `.json`.

## Benchmark data and metrics

The data is a deterministic general ledger: a chart of accounts, company settings,
and balanced journal entries with 2–6 lines each, stored one entry per key
(`je_000001`, …). Entries are added until the plaintext JSON container reaches
the target size.

| Metric | Meaning |
|---|---|
| Write ms | `write()` every entry (one coalesced flush), then wait until it reaches disk |
| Update ms | Write one entry into the full container, then wait until it reaches disk (median of `UPDATES`) |
| Cold read ms | Open a fresh container from a copy of the file (read + decrypt + decode) |
| Stall ms | Longest time the calling isolate's event loop was blocked, i.e. how long the UI would freeze |
| Jank ms | Total blocked time beyond a 16.7 ms frame budget, including unawaited work after the call returns, such as backup files |

`write()` and `save()` return **before** the data is on disk in every package
here. The benchmark waits on each box's write queue so the timings include
the actual flush.

These numbers come from the Flutter test VM (JIT, debug mode) on the host machine.
Absolute times on a phone in profile/release mode will differ, but the relative
comparison holds. On Android, Flutter runs the UI isolate on the platform
thread, so stall and jank translate directly into dropped frames.
