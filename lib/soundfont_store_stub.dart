import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

import 'soundfont.dart';

class SoundfontStore {
  Future<List<SoundFont>> scan() async => const [];

  Future<int> importFiles(
    List<PlatformFile> files, {
    SoundfontImportProgress? onProgress,
  }) async => 0;

  Future<Uint8List?> readData(SoundFont font) async => font.data;

  Future<int> importWebFiles(
    List<Object> files, {
    SoundfontImportProgress? onProgress,
  }) async => 0;

  Future<void> delete(SoundFont font) async {}
}
