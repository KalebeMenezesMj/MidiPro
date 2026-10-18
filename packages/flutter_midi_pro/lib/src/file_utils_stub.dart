import 'dart:typed_data';

Future<String> persistTempSoundfont(
  Uint8List data, {
  String extension = '.sf2',
}) {
  throw UnsupportedError(
    'Temporary soundfont persistence is not supported on web.',
  );
}

Future<Uint8List> readFileBytes(String path) {
  throw UnsupportedError('Reading files from disk is not supported on web.');
}
