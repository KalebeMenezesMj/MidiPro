import 'dart:typed_data';

typedef SoundfontImportProgress = void Function(int completed, int total);

class SoundFont {
  const SoundFont({
    required this.filename,
    this.path,
    this.data,
    this.builtin = false,
  });

  final String filename;
  final String? path;
  final Uint8List? data;
  final bool builtin;

  String get id => path ?? filename;

  String get displayName {
    var name = filename.replaceFirst(RegExp(r'\.sf2$', caseSensitive: false), '');
    name = name
        .replaceFirst(RegExp(r'^\d+[_\s.-]*'), '')
        .replaceFirst(RegExp(r'[_\s.-]*nord$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[_-]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return name
        .split(' ')
        .map((word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }

  String get category => soundfontCategory(filename);
}

String soundfontCategory(String filename) {
  final name = filename.toLowerCase();
  if (name.contains('upright')) return 'Upright';
  if (name.contains('epiano') ||
      name.contains('electric') ||
      name.contains('eletric') ||
      name.contains('wurlitzer') ||
      name.contains('digigrand') ||
      RegExp(r'(^|[_\s])ep([_\s.-]|\d|$)').hasMatch(name) ||
      RegExp(r'(^|[_\s])dx([_\s.-]|$)').hasMatch(name)) {
    return 'E-Piano';
  }
  if (name.contains('grand')) return 'Grand';
  return 'Outros';
}

bool isSoundFontData(Uint8List data) =>
    data.length >= 12 &&
    String.fromCharCodes(data.sublist(0, 4)) == 'RIFF' &&
    String.fromCharCodes(data.sublist(8, 12)) == 'sfbk';
