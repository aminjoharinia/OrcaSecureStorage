import 'package:flutter_test/flutter_test.dart';
import 'package:orca_secure_storage/orca_secure_storage.dart';

void main() {
  const counter = 'counter';
  const isDarkMode = 'isDarkMode';
  OrcaSecureStorage box = OrcaSecureStorage();
  test('OrcaSecureStorage read and write operation', () {
    box.write(counter, 0);
    expect(box.read(counter), 0);
  });

  test('save the state of brightness mode of app in OrcaSecureStorage', () {
    box.write(isDarkMode, true);
    expect(box.read(isDarkMode), true);
  });
}
