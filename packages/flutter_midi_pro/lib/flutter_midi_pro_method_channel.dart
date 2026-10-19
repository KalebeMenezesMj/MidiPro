import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_midi_pro/flutter_midi_pro_platform_interface.dart';

import 'src/file_utils_stub.dart'
    if (dart.library.io) 'src/file_utils_io.dart'
    as file_utils;

/// An implementation of [FlutterMidiProPlatform] that uses method channels.
class MethodChannelFlutterMidiPro extends FlutterMidiProPlatform {
  static const MethodChannel _channel = MethodChannel('flutter_midi_pro');

  @override
  Future<int> loadSoundfont(String path, int bank, int program) async {
    final int sfId = await _channel.invokeMethod('loadSoundfont', {
      'path': path,
      'bank': bank,
      'program': program,
    });
    return sfId;
  }

  @override
  Future<int> loadSoundfontBytes(Uint8List data, int bank, int program) async {
    final path = await file_utils.persistTempSoundfont(data);
    return loadSoundfont(path, bank, program);
  }

  @override
  Future<void> selectInstrument(
    int sfId,
    int channel,
    int bank,
    int program,
  ) async {
    await _channel.invokeMethod('selectInstrument', {
      'sfId': sfId,
      'channel': channel,
      'bank': bank,
      'program': program,
    });
  }

  @override
  Future<void> playNote(int channel, int key, int velocity, int sfId) async {
    await _channel.invokeMethod('playNote', {
      'channel': channel,
      'key': key,
      'velocity': velocity,
      'sfId': sfId,
    });
  }

  @override
  Future<void> stopNote(int channel, int key, int sfId) async {
    await _channel.invokeMethod('stopNote', {
      'channel': channel,
      'key': key,
      'sfId': sfId,
    });
  }

  @override
  Future<void> stopAllNotes(int sfId) async {
    await _channel.invokeMethod('stopAllNotes', {'sfId': sfId});
  }

  @override
  Future<void> unloadSoundfont(int sfId) async {
    await _channel.invokeMethod('unloadSoundfont', {'sfId': sfId});
  }

  @override
  Future<void> setAudioEffects(int sfId, Map<String, double> effects) async {
    await _channel.invokeMethod('setAudioEffects', {
      'sfId': sfId,
      'effects': effects,
    });
  }

  @override
  Future<void> pitchBend(int sfId, int channel, int value) async {
    await _channel.invokeMethod('pitchBend', {
      'sfId': sfId,
      'channel': channel,
      'value': value,
    });
  }

  @override
  Future<void> controlChange(
    int sfId,
    int channel,
    int controller,
    int value,
  ) async {
    await _channel.invokeMethod('controlChange', {
      'sfId': sfId,
      'channel': channel,
      'controller': controller,
      'value': value,
    });
  }

  @override
  Future<void> pitchWheelSensitivity(int sfId, int channel, double semitones) async {
    await _channel.invokeMethod('pitchWheelSensitivity', {
      'sfId': sfId,
      'channel': channel,
      'semitones': semitones,
    });
  }

  @override
  Future<void> dispose() async {
    await _channel.invokeMethod('dispose');
  }
}
