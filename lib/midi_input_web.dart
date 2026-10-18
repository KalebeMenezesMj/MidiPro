import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'midi_input_types.dart';

class MidiInput {
  web.MIDIAccess? _access;
  web.MIDIInput? _input;

  Future<List<MidiInputDevice>> requestAccess() async {
    final access = await web.window.navigator
        .requestMIDIAccess(web.MIDIOptions(sysex: false))
        .toDart;
    _access = access;
    return _inputs(access)
        .map(
          (input) => MidiInputDevice(
            id: input.id,
            name: input.name?.trim().isNotEmpty == true
                ? input.name!
                : input.manufacturer ?? 'Entrada MIDI',
          ),
        )
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<void> connect(String id, MidiMessageHandler onMessage) async {
    final access = _access;
    if (access == null) throw StateError('Solicite acesso MIDI antes de conectar.');

    final input = _inputs(access).firstWhere((input) => input.id == id);
    if (_input != null) await disconnect();
    await input.open().toDart;
    input.onmidimessage = ((web.Event event) {
      final data = (event as web.MIDIMessageEvent).data?.toDart;
      if (data != null) onMessage(data);
    }).toJS;
    _input = input;
  }

  Future<void> disconnect() async {
    final input = _input;
    _input = null;
    if (input == null) return;
    input.onmidimessage = null;
    await input.close().toDart;
  }

  Iterable<web.MIDIInput> _inputs(web.MIDIAccess access) =>
      _MIDIInputMap(access.inputs).values().toDartIterable;
}

@JS()
extension type _MIDIInputMap(JSObject _) implements JSObject {
  external JSIterable<web.MIDIInput> values();
}
