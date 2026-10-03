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
`write` returns before the data reaches disk.

### Files and migration
Each container is stored as `<container>.oss` with a backup in
`<container>.ossbak`.

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
