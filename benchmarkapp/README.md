# Storage Benchmark app

A Flutter app that compares key-value storages in a real app, on every
platform, in the style of the get_storage benchmark: **read / write / delete**
tabs, integers vs strings, 10–1000 entries.

| Label | Storage | Encryption |
|---|---|---|
| Orca pw 🔒 | OrcaSecureStorage (this repo) with a password | AES-256-GCM, key from PBKDF2 (600,000 iterations) |
| Orca key 🔒 | OrcaSecureStorage with `encryptionKey` | AES-256-GCM, raw 32-byte key |
| Orca | OrcaSecureStorage, no password | none |
| GSS 🔒 | get_secure_storage 1.0.5 (gslender) | AES-128-CTR + HMAC |
| GS | get_storage 2.1.1 | none |
| Hive | Hive CE 2.20 | none |
| Hive 🔒 | Hive CE 2.20 with `HiveAesCipher` | AES-256-CBC |
| SP | shared_preferences | none |
| sqfl | sqflite (FFI on Linux/Windows) | none |
| Sem | Sembast (file / IndexedDB) | none |

## What is measured

For each storage and each selected value type (tabs in the app):

| Value type | Example value |
|---|---|
| Integers | `42` |
| Doubles | `42.92` (Dart's `double` is the 64-bit float; there is no separate `float`) |
| Strings | ~100 characters: `Invoice #42 — 3 × consulting hours, …` |
| JSON | a small record: `{id, invoice, amount, currency, paid, tags: [...]}` (~120 bytes) |

SharedPreferences and sqflite cannot store a map, so JSON values are stored as
JSON text and decoded on read, as an app would.


- **write**: `await write(key, value)` for every entry, then wait until the
  data is saved (get_storage-style boxes return before writing the file).
- **update 1**: write one entry into the full storage and wait until it is
  saved; median of 20.
- **read**: `await read(key)` for every entry.
- **cold read**: open the stored data again from disk, as on an app start, and
  read every entry (get_storage-style boxes: a new container on a copy of the
  file; Hive, sqflite, Sembast: close and reopen; SharedPreferences: `reload`).
- **delete**: `await delete(key)` for every entry, then wait until saved.

The chart shows the time of the selected operation per storage and value type
(optionally on a log scale). The summary table shows every operation for one
value type; the second table shows the selected operation for every value
type. The fastest time in each column is highlighted. The app has light and
dark themes (follows the system by default; switch in the header).

Calls are awaited one by one, the way app code usually uses these APIs (no
batching); every 50 operations the loop gives the event loop a turn, as a real
app would between user actions. Operations over 20 s are stopped and shown as
"timeout". Entries: 10 to 10,000.

"Saved" means what each API promises: Orca fsyncs its files; Hive, Sembast and
GetStorage write without fsync; SharedPreferences on Apple platforms returns
before `NSUserDefaults` writes. Measure in **release** or **profile** mode.
**Copy results** puts Markdown tables on the clipboard; they are also printed
to the console. Saved runs are in [`results/`](results).

## Run

```bash
flutter run --release -d macos
```

```bash
flutter run --release -d android
```

```bash
flutter run --release -d chrome
```

Linux, Windows and iOS: `flutter run --release -d linux` / `-d windows` /
`-d <iphone>`.

Headless run (prints a Markdown table and JSON, saves screenshots, exits; not on
the web; `--dart-define=THEME=light` or `dark` picks the theme):

```bash
flutter run --release -d macos --dart-define=AUTORUN=true --dart-define=ENTRIES=100 --dart-define=KINDS=integers,json
```

## Platform notes

| Platform | Status | Notes |
|---|---|---|
| macOS arm64 | built and run | Apple Silicon only (`ARCHS = arm64` in `macos/Runner/Configs`): webcrypto 0.6.1 cannot cross-compile BoringSSL for x86_64 on an arm64 Mac. |
| Web (JS) | built and run | sqflite is skipped (it needs a SQLite WASM build and worker). Not WASM: get_secure_storage 1.0.5 and get_storage use `dart:html`. |
| Android | not verified | Needs Google's Maven repository; it was unreachable from the network this was built on. |
| iOS | not verified | Needs the iOS platform installed in Xcode → Settings → Components. |
| Linux x64 | not verified | Needs CMake and clang for webcrypto's BoringSSL and the bundled SQLite. |
| Windows x64 | not verified | Needs Visual Studio with C++ (CMake) for webcrypto and SQLite. |
