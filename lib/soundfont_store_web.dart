import 'dart:js_interop';
import 'dart:typed_data';

import 'package:idb_shim/idb_browser.dart';
import 'package:web/web.dart' as web;

import 'soundfont.dart';

class SoundfontStore {
  static const _databaseName = 'midipro-library';
  static const _storeName = 'soundfonts';
  Future<Database>? _databaseFuture;

  Future<Database> _database() => _databaseFuture ??= idbFactoryBrowser.open(
        _databaseName,
        version: 1,
        onUpgradeNeeded: (event) {
          final database = event.database;
          if (!database.objectStoreNames.contains(_storeName)) {
            database.createObjectStore(_storeName);
          }
        },
      );

  Future<List<SoundFont>> scan() async {
    final database = await _database();
    final transaction = database.transaction(_storeName, idbModeReadOnly);
    final keys = await transaction.objectStore(_storeName).getAllKeys();
    await transaction.completed;
    return keys
        .whereType<String>()
        .map((filename) => SoundFont(filename: filename))
        .toList()
      ..sort((a, b) => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()));
  }

  /// Imports the files returned by a folder picker, one at a time, so only a
  /// single SoundFont stays in memory during the import.
  Future<int> importWebFiles(
    List<web.File> files, {
    SoundfontImportProgress? onProgress,
  }) async {
    var imported = 0;

    for (var index = 0; index < files.length; index++) {
      final file = files[index];
      final data = (await file.arrayBuffer().toDart).toDart.asUint8List();
      if (!isSoundFontData(data)) {
        onProgress?.call(index + 1, files.length);
        continue;
      }
      await _putSoundfont(file.name, data);
      imported++;
      onProgress?.call(index + 1, files.length);
    }
    return imported;
  }

  Future<void> _putSoundfont(String filename, Uint8List data) async {
    final database = await _database();
    final transaction = database.transaction(_storeName, idbModeReadWrite);
    await transaction.objectStore(_storeName).put(
      {'filename': filename, 'data': data},
      filename,
    );
    await transaction.completed;
  }

  Future<Uint8List?> readData(SoundFont font) async {
    final database = await _database();
    final transaction = database.transaction(_storeName, idbModeReadOnly);
    final value = await transaction.objectStore(_storeName).getObject(font.id);
    await transaction.completed;
    if (value is Map) {
      final data = value['data'];
      if (data is Uint8List) return data;
      if (data is List<int>) return Uint8List.fromList(data);
    }
    return null;
  }

  /// Sem efeito na Web (os timbres nativos já são lidos dos assets).
  Future<void> writeSoundfont(String filename, Uint8List data) async {}

  Future<void> delete(SoundFont font) async {
    final database = await _database();
    final transaction = database.transaction(_storeName, idbModeReadWrite);
    await transaction.objectStore(_storeName).delete(font.id);
    await transaction.completed;
  }
}
