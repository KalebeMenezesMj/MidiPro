import 'dart:typed_data';

import 'package:flutter_midi_pro/flutter_midi_pro_method_channel.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

abstract class FlutterMidiProPlatform extends PlatformInterface {
  FlutterMidiProPlatform() : super(token: _token);
  static final Object _token = Object();
  static FlutterMidiProPlatform _instance = MethodChannelFlutterMidiPro();
  static FlutterMidiProPlatform get instance => _instance;

  static set instance(FlutterMidiProPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<int> loadSoundfont(String path, int bank, int program) {
    throw UnimplementedError('loadSoundfont() has not been implemented.');
  }

  Future<int> loadSoundfontBytes(Uint8List data, int bank, int program) {
    throw UnimplementedError('loadSoundfontBytes() has not been implemented.');
  }

  Future<void> selectInstrument(int sfId, int channel, int bank, int program) {
    throw UnimplementedError('selectInstrument() has not been implemented.');
  }

  Future<void> playNote(int channel, int key, int velocity, int sfId) {
    throw UnimplementedError('playNote() has not been implemented.');
  }

  Future<void> stopNote(int channel, int key, int sfId) {
    throw UnimplementedError('stopNote() has not been implemented.');
  }

  Future<void> stopAllNotes(int sfId) {
    throw UnimplementedError('stopAllNotes() has not been implemented.');
  }

  Future<void> unloadSoundfont(int sfId) {
    throw UnimplementedError('unloadSoundfont() has not been implemented.');
  }

  Future<void> setAudioEffects(int sfId, Map<String, double> effects) {
    throw UnimplementedError('setAudioEffects() has not been implemented.');
  }

  /// Aplica pitch bend no canal. [value] é o valor MIDI bruto de 14 bits
  /// (0..16383, centro 8192).
  Future<void> pitchBend(int sfId, int channel, int value) {
    throw UnimplementedError('pitchBend() has not been implemented.');
  }

  /// Envia um control change (ex.: CC1 modulação, 0..127).
  Future<void> controlChange(
    int sfId,
    int channel,
    int controller,
    int value,
  ) {
    throw UnimplementedError('controlChange() has not been implemented.');
  }

  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }
}
