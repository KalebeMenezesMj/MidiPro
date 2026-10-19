import 'dart:typed_data';

import 'soundfont.dart';

class SoundfontStore {
  Future<List<SoundFont>> scan() async => const [];

  Future<Uint8List?> readData(SoundFont font) async => font.data;

  Future<int> importWebFiles(
    List<Object> files, {
    SoundfontImportProgress? onProgress,
  }) async => 0;

  Future<void> writeSoundfont(String filename, Uint8List data) async {}

  Future<void> delete(SoundFont font) async {}
}
