import 'package:flutter/services.dart';

class MetronomeOutput {
  Future<void> click({required bool accent}) =>
      SystemSound.play(SystemSoundType.click);

  Future<void> dispose() async {}
}
