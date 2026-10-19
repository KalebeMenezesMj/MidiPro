import 'dart:io';
import 'dart:typed_data';

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

  Future<Uint8List?> readData(SoundFont font) async => font.data;

  /// Grava um SoundFont vindo dos assets (usado para popular os timbres
  /// nativos na primeira execução do Android).
  Future<void> writeSoundfont(String filename, Uint8List data) async {
    final directory = await _directory();
    final file = File('${directory.path}${Platform.pathSeparator}$filename');
    await file.writeAsBytes(data, flush: true);
  }

  /// Importação por pasta só existe na versão Web; desktop/Android usam arquivos.
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
}
