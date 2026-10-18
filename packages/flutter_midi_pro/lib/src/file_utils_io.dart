import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String> persistTempSoundfont(
  Uint8List data, {
  String extension = '.sf2',
}) async {
  final tempDir = await getTemporaryDirectory();
  final filename =
      'soundfont_${DateTime.now().microsecondsSinceEpoch}$extension';
  final file = File('${tempDir.path}/$filename');
  await file.writeAsBytes(data, flush: true);
  return file.path;
}

Future<Uint8List> readFileBytes(String path) async {
  final file = File(path);
  return file.readAsBytes();
}
