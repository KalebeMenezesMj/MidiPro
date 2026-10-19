import 'package:flutter/services.dart';

/// Clique do metrônomo via o plugin nativo `flutter_midi_pro`
/// (AudioTrack com um pulso curto gerado no nativo).
class MetronomeOutput {
  static const MethodChannel _channel = MethodChannel('flutter_midi_pro');

  Future<void> click({required bool accent}) async {
    try {
      await _channel.invokeMethod<void>('playClick', {'accent': accent});
    } catch (_) {
      // Sem saída de clique disponível; ignora silenciosamente.
    }
  }

  Future<void> dispose() async {}
}
