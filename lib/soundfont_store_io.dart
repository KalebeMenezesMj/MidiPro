import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'soundfont.dart';

class SoundfontStore {
  Future<Directory> _directory() async {
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}soundfonts',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<List<SoundFont>> scan() async {
    final entries = await (await _directory()).list(followLinks: false).toList();
    final fonts = entries
        .whereType<File>()
        .where((file) => file.path.toLowerCase().endsWith('.sf2'))
        .map((file) => SoundFont(
              filename: file.path.split(RegExp(r'[\\/]+')).last,
              path: file.path,
            ))
        .toList()
      ..sort((a, b) => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()));
    return fonts;
  }

  Future<int> importFiles(
    List<PlatformFile> files, {
    SoundfontImportProgress? onProgress,
  }) async {
    final directory = await _directory();
    var imported = 0;

    for (var index = 0; index < files.length; index++) {
      final picked = files[index];
      final sourcePath = picked.path;
      if (sourcePath == null || !await _isSoundFontFile(File(sourcePath))) {
        onProgress?.call(index + 1, files.length);
        continue;
      }

      final filename = picked.name.split(RegExp(r'[\\/]+')).last;
      final source = File(sourcePath);
      final destination = File(
        '${directory.path}${Platform.pathSeparator}$filename',
      );
      if (source.absolute.path.toLowerCase() ==
          destination.absolute.path.toLowerCase()) {
        onProgress?.call(index + 1, files.length);
        continue;
      }
      await source.copy(destination.path);
      imported++;
      onProgress?.call(index + 1, files.length);
    }
    return imported;
  }

  Future<Uint8List?> readData(SoundFont font) async => font.data;

  /// Folder import only exists on the web build; desktop stays with files.
  Future<int> importWebFiles(
    List<Object> files, {
    SoundfontImportProgress? onProgress,
  }) async {
    throw UnsupportedError('importWebFiles só existe na versão Web.');
  }

  Future<void> delete(SoundFont font) async {
    final path = font.path;
    if (path != null) await File(path).delete();
  }

  Future<bool> _isSoundFontFile(File file) async {
    try {
      final header = <int>[];
      await for (final chunk in file.openRead(0, 12)) {
        header.addAll(chunk);
      }
      return isSoundFontData(Uint8List.fromList(header));
    } catch (_) {
      return false;
    }
  }
}
