// sqflite has no web implementation without extra setup (a SQLite WASM build
// and a shared worker served by the app), so it is skipped on the web.
// ignore: unnecessary_nullable_for_final_variable_declarations
const String? sqfliteUnsupportedReason = 'not available on the web';

class BenchDatabase {
  Future<void> execute(String sql, [List<Object?>? args]) =>
      throw UnsupportedError(sqfliteUnsupportedReason!);
  Future<void> close() async {}
  Future<Object?> readValue(String key) =>
      throw UnsupportedError(sqfliteUnsupportedReason!);
}

Future<BenchDatabase> openBenchDatabase() =>
    throw UnsupportedError(sqfliteUnsupportedReason!);
