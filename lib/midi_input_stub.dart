import 'midi_input_types.dart';

class MidiInput {
  Future<List<MidiInputDevice>> requestAccess() async =>
      throw UnsupportedError('MIDI pelo navegador não está disponível nesta plataforma.');

  Future<void> connect(String id, MidiMessageHandler onMessage) async {}

  Future<void> disconnect() async {}
}
