import 'dart:async';
import 'dart:convert';
import 'package:get/get.dart';
import 'package:web/web.dart' as web;
import 'package:orca_secure_storage/orca_secure_storage.dart';

import '../codec.dart';

class StorageImpl {
  StorageImpl(this.fileName, [this.path]);
  web.Storage get localStorage => web.window.localStorage;

  final String? path;
  final String fileName;
  StorageCodec _codec = StorageCodec(const StorageCodecConfig());

  // localStorage holds strings: current-format values are stored as this
  // prefix + base64. There is no gzip on the web, so they are uncompressed.
  static const _prefix = 'OSS:';

  ValueStorage<Map<String, dynamic>> subject = ValueStorage<Map<String, dynamic>>(<String, dynamic>{});

  // Set by every change; a flush with nothing new to save does nothing.
  bool _dirty = false;

  void clear() {
    _dirty = true;
    localStorage.removeItem(fileName);
    subject.value?.clear();

    subject
      ..value?.clear()
      ..changeValue("", null);
  }

  static Future<bool> hasContainer(String container, [String? path]) async =>
      true;
  static Future<void> deleteContainer(String container, [String? path]) async {}

  Future<bool> _exists() async {
    return localStorage.getItem(fileName) != null;
  }

  //^ Each flush rewrites the whole container, so a burst of writes awaited
  //^ one by one used to rewrite it once per write (quadratic). Waiting one
  //^ event-loop turn lets the burst finish first; the flushes queued behind
  //^ this one then find nothing dirty and return.
  Future<void> flush() async {
    if (!_dirty) return;
    await Future<void>.delayed(Duration.zero);
    if (!_dirty) return;
    _dirty = false;
    try {
      await _writeToStorage(subject.value ?? {});
    } catch (_) {
      _dirty = true;
      rethrow;
    }
  }

  T? read<T>(String key) {
    return subject.value![key] as T?;
  }

  T getKeys<T>() {
    return subject.value!.keys as T;
  }

  T getValues<T>() {
    return subject.value!.values as T;
  }

  /// The web build re-encodes the whole container on each flush, so marking
  /// it dirty is enough.
  void markAllDirty() => _dirty = true;

  Future<void> init(Map<String, dynamic>? initialData, StorageCodecConfig config) async {
    _codec = StorageCodec(config);
    subject.value = initialData ?? <String, dynamic>{};
    if (await _exists()) {
      await _readFromStorage();
    } else {
      await _writeToStorage(subject.value ?? {});
    }
    return;
  }

  void remove(String key) {
    _dirty = true;
    subject
      ..value?.remove(key)
      ..changeValue(key, null);
  }

  void write(String key, dynamic value) {
    _dirty = true;
    subject
      ..value![key] = value
      ..changeValue(key, value);
  }

  Future<void> _writeToStorage(Map<String, dynamic> data) async {
    final plaintext = assembleDocument({
      for (final e in data.entries) e.key: json.encode(e.value),
    });
    final bytes = await _codec.encode(plaintext);
    localStorage.setItem(fileName, '$_prefix${base64.encode(bytes)}');
  }

  Future<void> _readFromStorage() async {
    var dataValue = localStorage.getItem(fileName);
    var legacyKey = fileName;
    if (dataValue == null && fileName == OrcaSecureStorage.defaultContainer) {
      // The default container before the rename.
      legacyKey = OrcaSecureStorage.legacyDefaultContainer;
      dataValue = localStorage.getItem(legacyKey);
    }
    if (dataValue == null) {
      await _writeToStorage(<String, dynamic>{});
      return;
    }
    final isCurrent = dataValue.startsWith(_prefix);
    try {
      final bytes = isCurrent
          ? base64.decode(dataValue.substring(_prefix.length))
          : utf8.encode(dataValue); // 1.x: JSON text
      final doc = await _codec.decode(bytes);
      subject.value = json.decode(doc.plaintext) as Map<String, dynamic>;
      if (doc.needsRewrite || legacyKey != fileName) {
        // Leave the 1.x value in place: under its own key, or copied to
        // '<container>.gs' when the converted value replaces it.
        if (!isCurrent && legacyKey == fileName) {
          localStorage.setItem('$fileName.gs', dataValue);
        }
        await _writeToStorage(subject.value!);
      }
    } catch (e) {
      // Keep the unreadable value instead of destroying it, then start empty.
      Get.log('Can not read box $fileName ($e)', isError: true);
      if (legacyKey == fileName) {
        localStorage.setItem('$fileName.rejected', dataValue);
      }
      subject.value = <String, dynamic>{};
      await _writeToStorage(subject.value!);
    }
  }
}

extension FirstWhereExt<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T element) test) {
    for (var element in this) {
      if (test(element)) return element;
    }
    return null;
  }
}
