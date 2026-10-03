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
double, Map and List. Requires Dart 3.10 (Flutter 3.38) or later.

### Add to your pubspec:
```
dependencies:
  orca_secure_storage:
    git: https://github.com/aminjoharinia/OrcaSecureStorage
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

`write` returns before the data reaches disk; `await box.flush()` waits until
it is saved.

### Files and migration
Each container is stored as `<container>.oss` with a backup in
`<container>.ossbak`, plus a change log `<container>.osslog`: an update
appends one small encrypted record to the log (fsynced before it counts as
saved) instead of rewriting the whole file, so it costs about the same at 50
or 10,000 entries. When writes pause for 300 ms, the log outgrows the
snapshot, or the app goes to the background, the log is folded into a new
snapshot and backup. A crash at any point leaves the data readable: a record
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
save, such as a full disk), await `flush`:
```dart
box.write('quote', 'OrcaSecureStorage is the best');
await box.flush();
```

Opening a container that is already open returns the same instance. Pass
the same `password` / `encryptionKey` / `path`, or none; different ones
throw a `StateError`.

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
