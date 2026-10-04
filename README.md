# OrcaSecureStorage

An encrypted, fast key-value store for Flutter, with WASM support. The data
lives in memory and is saved to disk after each change.

Based on [get_secure_storage](https://github.com/gslender/get_secure_storage) by
gslender, itself a secure version of [GetStorage](https://github.com/jonataslaw/get_storage)
by Jonny Borges.

- **Encryption:** AES-256-GCM, key derived with PBKDF2-HMAC-SHA256 (600,000
  iterations, random salt per container), through BoringSSL
  ([webcrypto](https://pub.dev/packages/webcrypto)) or the browser's WebCrypto.
- **Compact files:** data is gzip-compressed before encryption; a 15 MB
  container takes about 2 MB on disk.
- **Smooth UI:** compression, encryption and file writes run on a background
  isolate; a write only encodes the keys that changed.
- **Crash-safe:** files are written to a temp file and renamed into place.

Supports Android, iOS, Web, Mac, Linux, and Windows. Can store String, int,
double, bool, Map and List, and objects with a `toJson()` method (read back
as a `Map` after a restart). Requires Dart 3.10 (Flutter 3.38) or later.

### Add to your pubspec:
Pin a release tag, so `flutter pub upgrade` never changes the file format
under your users' data without you choosing to:
```yaml
dependencies:
  orca_secure_storage:
    git:
      url: https://github.com/aminjoharinia/OrcaSecureStorage.git
      ref: v2.4.2
```
### Install it

You can install packages from the command line:

with `Flutter`:

```css
$  flutter packages get
```

### Import it

Now in your `Dart` code, you can use: 

````dart
import 'package:orca_secure_storage/orca_secure_storage.dart';
````

### Initialize storage driver with await:
```dart
main() async {
  await OrcaSecureStorage.init(password: 'strongpassword');
  runApp(App());
}
```
### Password or encryption key
A `password` is turned into the AES key with PBKDF2 (600,000 iterations,
about 40 ms per container when it is opened). For fast opening, use a random
32-byte `encryptionKey` instead and keep it in secure platform storage
(Keychain, Android Keystore, e.g. with flutter_secure_storage):
```dart
final key = OrcaSecureStorage.generateKey(); // once; store it securely
await OrcaSecureStorage.init(encryptionKey: key);
```
To move existing password-protected data (including 1.x files) to a key, pass
both once; files are read with the password and rewritten with the key:
```dart
await OrcaSecureStorage.init(password: 'strongpassword', encryptionKey: key);
```
After that, the key alone opens them. A key alone cannot open files that are
still protected by the password.

If your app was released with get_secure_storage 1.x, **keep passing the
password with the key for good**. 1.x files can still turn up after the
conversion: a user who updates late, or a phone backup from before the update
restored on a new device. With the key alone, such a container opens empty,
and the empty `.oss` written then stops the 1.x file from being converted
later. Passing the password costs nothing when there is no 1.x file: the 1.x
key is only derived when one is found, and the password's PBKDF2 only runs
for files written with a password.

`write` returns before the data reaches disk; `await box.flush()` waits until
it is saved.

### Durability: what "saved" means
By default every save is fsynced before it counts as saved (before `flush()`
completes). For apps that would rather save faster and can lose the last few
changes after an OS crash or power loss, choose `Durability.os` when opening:
```dart
await OrcaSecureStorage.init(encryptionKey: key, durability: Durability.os);
```

| | `Durability.fsync` (default) | `Durability.os` |
|---|---|---|
| App crash, app killed | nothing saved is lost | nothing saved is lost (the OS still writes it) |
| OS crash, power loss | nothing saved is lost | the latest saves can be lost; the container goes back to an earlier state |
| Damaged container | never | never: snapshots are still fsynced and replaced atomically, and a half-written change is detected and ignored |
| Cost of a save | one fsync of the change log | none |

How much the fsync costs depends on the device. On a Mac it is cheap, because
on Apple platforms `fsync` hands the data to the drive without flushing the
drive's own cache: in the [benchmark](benchmarkapp/results/2026-10-04_durability.md)
(10,000 strings, release build) writing everything took 24.7 ms with fsync
and 25.5 ms without, and an update took 0.1 ms either way. On Android phones
an fsync typically takes milliseconds, which is where `Durability.os` saves
the most (not measured here).

What other storages mean by "saved":

| Storage | A save is done when the data is | Survives a power loss |
|---|---|---|
| OrcaSecureStorage, `Durability.fsync` | fsynced to disk | yes |
| OrcaSecureStorage, `Durability.os` | handed to the OS | not the latest saves |
| Hive CE, Sembast, GetStorage | written to the file, without fsync | not the latest saves |
| SharedPreferences | handed to the platform (on Apple platforms `NSUserDefaults`, which writes later) | not the latest saves |
| sqflite | committed by SQLite, which syncs to disk on commit by default | yes, with SQLite's default settings |

On the web, data goes to `localStorage` and the browser decides when it
reaches disk; `durability` has no effect there. Each save encrypts and
stores the whole container, so a save waits 75 ms for more writes to join
it: a burst of writes is stored once. `await box.flush()` stores at once, and
so does hiding the tab (switching away or closing it).

### Comparison with other storages
Measured on an Apple Silicon Mac, release build, with the
[Orca Benchmark](benchmarkapp) app (macOS, version 2.4.0). Each storage ran in its
own process. Times include waiting until each storage counts the data as
saved (see "Durability" above: OrcaSecureStorage fsyncs, most others do
not). Speed uses strings of about 100 characters; memory uses JSON records
of about 330 bytes and is the memory the storage added to its process.
Anything that took longer than 40 s was stopped; "–" means not measured
because writing the entries did not finish. The best (lowest) number of
each column is in bold. Single runs, so small numbers vary by a few tenths
of a millisecond or a few MB.

![Orca Benchmark on macOS: the write results for 1,000 entries per storage and value type, on a log scale, with the summary table below](benchmarkapp/screenshots/orca_benchmark.webp)

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

In short: OrcaSecureStorage writes 7–24× and deletes 8–33× faster than
encrypted Hive, and opens without blocking the UI (Hive decodes the whole
box on the UI isolate: about 0.9 s at 100,000 entries). It uses less memory
than Hive right after opening and about the same once every entry has been
read. It uses more while writing, since by default it keeps every written
value as objects as well as its JSON in the background isolate; `writeAll`
and `keepWrittenObjects: false` keep the text only, which brings it below
Hive at large sizes (see "Keeping written values as text" below). sqflite uses the least memory (it reads from disk on demand)
but is the slowest to write. SharedPreferences, get_secure_storage and
get_storage do not finish 50,000 writes within 40 s. Full results:
[benchmarkapp/results/2026-10-04_comparison_40s.md](benchmarkapp/results/2026-10-04_comparison_40s.md).

### How it works (and its memory use)
A container lives in memory twice, on purpose:

```
 UI isolate                                 background isolate (one per container)
┌────────────────────────────┐  changed   ┌─────────────────────────────────────┐
│ Map<String, dynamic>       │  keys as   │ each key's JSON text                │
│  read() answers from here, │  JSON ───▶ │  appends changes to the log; builds │
│  synchronously; decodes a  │            │  snapshots: join, gzip, encrypt,    │
│  value when first read     │            │  write temp file, fsync, rename     │
│ write() encodes one value  │            │                                     │
└────────────────────────────┘            └─────────────────────────────────────┘
```

1. **The UI isolate's map** is what `read` answers from, so reads are
   instant and need no `await`. After opening, each value is still its JSON
   text: `read` decodes a value the first time it is asked for it (a few
   microseconds for a typical record) and keeps the result, so later reads
   return the same object. Values you write are kept as objects.
2. **The worker's copy** holds every key's JSON text. Dart isolates do not
   share objects, so the worker keeps its own. With it, the worker can build
   a new snapshot (join the JSON, compress, encrypt, write) whenever it
   likes, without asking the UI isolate for anything.

The second copy is what keeps the UI smooth: a `write` only encodes the value
you wrote, never the whole container. Without the copy, every snapshot would
mean encoding the whole container on the UI thread, about 100 ms at 15 MB,
which drops frames.

The cost is memory. Measured after garbage collection on a 64-bit desktop,
against the container's JSON (UTF-8):

| Copy | Records (maps, numbers, short strings) | Long string values |
|---|---|---|
| A value on the UI isolate before it is read (its JSON text) | about 1×; up to 2× | about 1×; up to 2.3× |
| A value on the UI isolate once read, or written with the default `write` (objects) | about 6× | about 2.5× |
| The worker's JSON text | about 1×; up to 2× | about 1×; up to 2.3× |
| The file on disk (compressed, encrypted) | about 0.1× | about 0.1× |

Text reaches the upper figure when strings contain characters outside
Latin-1 (Persian, Arabic, CJK, emoji, even `—` or `×`), which Dart stores at
2 bytes per character. On phones Dart uses 4-byte pointers, so the decoded
objects are likely somewhat smaller there. Code that reads every value
(`getValues()`, `listenable`, or a loop over all keys) decodes all of them,
so the container then costs its full decoded size.

On top of that come short peaks. Writing a snapshot builds the document in
pieces of about 64 KB and compresses each one right away, so it only holds
the compressed output (about 0.1×) in full, and a large save (such as a bulk
import) goes straight to a snapshot. Opening a container does not decode
it: the worker and a short-lived helper isolate cut the file into each
key's JSON text, and the helper hands the result to the UI isolate without
copying it, so opening does not block the UI (the longest stall measured
at 100,000 entries was 6 ms). Memory freed after a peak is usually kept by
the process rather than returned to the OS.

For a container with 15 MB of record-like JSON, a release build on macOS
adds about 140 MB to the process after writing it, about 100–115 MB right
after opening it, and about 160 MB once every value has been read
([measurements](benchmarkapp/results/2026-10-04_decode_on_read.md)).
Containers up to a few MB (settings, tokens, cached records) cost little.
For larger data, split it across several containers or use a database.

### Files and migration
Each container is stored as `<container>.oss` with a backup in
`<container>.ossbak`, plus a change log `<container>.osslog`: an update
appends one small encrypted record to the log (fsynced before it counts as
saved) instead of rewriting the whole file, so it costs about the same at 50
or 10,000 entries. When writes pause for 300 ms, the log outgrows the
snapshot, or the app goes to the background, the log is folded into a new
snapshot and backup. A save too large for the log (such as a bulk import)
is written as a new snapshot straight away. A crash at any point leaves the data readable: a record
cut short is ignored, a log already contained in the snapshot is not applied
twice, and anything that cannot be applied is kept as a `.rejected` file
rather than deleted.

When a container has no `.oss` file yet, its files from get_secure_storage 1.x
or GetStorage (`<container>.gs` / `<container>.bak`) are read once, written as
`.oss`, and left untouched. The default container also picks up the old
default `GetSecureStorage.gs`. get_secure_storage 1.x cannot read `.oss` files.

With a password, a file that is not encrypted (for example one written by
GetStorage or without a password) is not loaded. To load such a file once and
encrypt it, pass `migrateUnencrypted: true`:
```dart
await OrcaSecureStorage.init(password: 'strongpassword', migrateUnencrypted: true);
```
A `.oss` file that cannot be read (wrong password, tampering) is kept as
`<container>.oss.rejected` before the container starts empty.

#### use OrcaSecureStorage through an instance or use directly `OrcaSecureStorage().read('key')`
```dart
final box = OrcaSecureStorage(password: 'strongpassword');
```
#### To write information you must use `write` :
```dart
box.write('quote', 'OrcaSecureStorage is the best');
```

`write` makes the value readable at once and saves it in the background.
To wait until everything written so far is on disk (and to see a failed
save, such as a full disk), await `flush`. `flush` also retries a save that
failed earlier:
```dart
box.write('quote', 'OrcaSecureStorage is the best');
await box.flush();
```

`write` converts the value to JSON straight away (objects through their
`toJson()`), and saves it as it is at that moment. A value that cannot be
converted throws a `JsonUnsupportedObjectError` from `write` and is not
stored. If you change a stored list or map in place, call `save()`.

Opening a container that is already open returns the same instance. Pass
the same `password` / `encryptionKey` / `path` / `durability` /
`keepWrittenObjects`, or none; different ones throw a `StateError`.

#### To write many values at once, use `writeAll`:
```dart
await box.writeAll({for (final r in records) 'r${r.id}': r.toJson()});
```

`writeAll` saves the entries together and keeps them as their JSON text,
decoded again when read, instead of as the objects you passed. A bulk
import then takes much less memory (see the table below). If any value
cannot be converted to JSON, nothing is stored. Each call encodes its
entries on the UI thread, so for large imports call it with about 1,000
entries at a time (about 8 ms each).

#### Keeping written values as text: `keepWrittenObjects`
By default `write` keeps the object you wrote, and `read` returns that same
object. With `keepWrittenObjects: false`, every `write` keeps the value's
JSON text instead, as `writeAll` does:
```dart
await OrcaSecureStorage.init(encryptionKey: key, keepWrittenObjects: false);
```

What changes for values stored as text (with this option, or by
`writeAll`): `read` returns a new object (decoded the first time it is read,
a few microseconds for a typical record), not the instance you wrote; and
changing that instance in place and calling `save()` does not store the
change: `write` the value again. The default keeps today's behaviour.

Memory the container added after writing, records of about 330 bytes of
JSON, macOS release build (medians of 3 runs;
[measurements](benchmarkapp/results/2026-10-04_write_memory.md)):

| Records (JSON) | `write`, objects kept (default) | `keepWrittenObjects: false` | `writeAll`, 1,000 per call | Hive CE (encrypted) |
|---|---:|---:|---:|---:|
| 500 (0.2 MB) | 6 MB | 6 MB | 6 MB | 6 MB |
| 1,000 (0.3 MB) | 9 MB | 7 MB | 8 MB | 7 MB |
| 5,000 (1.6 MB) | 30 MB | 22 MB | 24 MB | 15 MB |
| 10,000 (3.2 MB) | 44 MB | 31 MB | 33 MB | 24 MB |
| 100,000 (32 MB) | 277 MB | 113 MB | 115 MB | 182 MB |

Up to about 1,000 records the difference is within the fixed cost of the
container (its background isolate), so keep the default. From about 5,000
records, and for imports and syncs, text saves a quarter to three fifths of
the memory; writing is as fast or slightly faster. Reopening the data later
is the same either way: values are always decoded when first read after
opening.

#### To read values you use `read`:
```dart
print(box.read('quote'));
// out: OrcaSecureStorage is the best

```
#### To remove a key, you can use `remove`:

```dart
box.remove('quote');
```

#### To listen changes you can use `listen`:
```dart
Function? disposeListen;
disposeListen = box.listen((){
  print('box changed');
});
```
#### If you subscribe to events, be sure to dispose them when using:
```dart
disposeListen?.call();
```
#### To listen changes on key you can use `listenKey`:

```dart
box.listenKey('key', (value){
  print('new key is $value');
});
```

#### To erase your container:
```dart
box.erase();
```

#### If you want to create different containers, simply give it a name. You can listen to specific containers, and also delete them.

```dart
OrcaSecureStorage g = OrcaSecureStorage(container:'MyStorage', password: 'strongpassword');
```

#### To initialize specific container:
```dart
await OrcaSecureStorage.init(container:'MyStorage', password: 'strongpassword');
```

## SharedPreferences Implementation
```dart
class MyPref {
  static final _otherBox = () => OrcaSecureStorage(container:'MyPref', password: 'strongpassword');

  final username = ''.val('username');
  final age = 0.val('age');
  final price = 1000.val('price', getBox: _otherBox);

  // or
  final username2 = ReadWriteValue('username', '');
  final age2 = ReadWriteValue('age', 0);
  final price2 = ReadWriteValue('price', '', _otherBox);
}

...

void updateAge() {
  final age = 0.val('age');
  // or 
  final age = ReadWriteValue('age', 0, () => box);
  // or 
  final age = Get.find<MyPref>().age;

  age.val = 1; // will save to box
  final realAge = age.val; // will read from box
}
```
