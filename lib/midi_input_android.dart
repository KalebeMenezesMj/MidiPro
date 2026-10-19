import 'dart:async';

import 'package:flutter/services.dart';

import 'midi_input_types.dart';

/// Entrada MIDI via o plugin nativo `flutter_midi_pro`.
/// No Android usa a API MidiManager; em outras plataformas retorna vazio.
class MidiInput {
  static const MethodChannel _channel = MethodChannel('flutter_midi_pro');
  static const EventChannel _events =
      EventChannel('flutter_midi_pro/midi_input');
  StreamSubscription<dynamic>? _subscription;

  Future<List<MidiInputDevice>> requestAccess() async {
    try {
      final result = await _channel.invokeListMethod<dynamic>('midiDevices');
      final devices = <MidiInputDevice>[];
      for (final item in result ?? const <dynamic>[]) {
        final map = Map<String, dynamic>.from(item as Map);
        final id = map['id'] as int;
        final name = map['name'] as String? ?? 'MIDI $id';
        devices.add(MidiInputDevice(id: '$id', name: name));
      }
      devices.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
      return devices;
    } catch (_) {
      return const [];
    }
  }

  Future<void> connect(String id, MidiMessageHandler onMessage) async {
    await disconnect();
    _subscription = _events.receiveBroadcastStream().listen((event) {
      if (event is Uint8List) {
        onMessage(event);
      } else if (event is List) {
        onMessage(List<int>.from(event));
      }
    });
    await _channel.invokeMethod<void>(
      'openMidiInput',
      {'deviceId': int.parse(id)},
    );
  }

  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _channel.invokeMethod<void>('closeMidiInput');
    } catch (_) {
      // Ignora se o canal nativo não estiver disponível.
    }
  }
}
