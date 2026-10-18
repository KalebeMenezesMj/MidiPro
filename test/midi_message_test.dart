import 'package:flutter_test/flutter_test.dart';
import 'package:midipro/midi_message.dart';

void main() {
  test('parses note on and velocity-zero note off with channel', () {
    final noteOn = parseMidiMessage([0x92, 60, 90]);
    expect(noteOn?.type, MidiMessageType.noteOn);
    expect(noteOn?.channel, 2);
    expect(noteOn?.key, 60);
    expect(noteOn?.value, 90);

    final noteOff = parseMidiMessage([0x92, 60, 0]);
    expect(noteOff?.type, MidiMessageType.noteOff);
    expect(noteOff?.channel, 2);
    expect(noteOff?.key, 60);
  });

  test('parses sustain, volume, and all-notes-off controls', () {
    expect(
      parseMidiMessage([0xB0, 64, 127])?.type,
      MidiMessageType.sustain,
    );
    expect(
      parseMidiMessage([0xB0, 7, 80])?.value,
      80,
    );
    expect(
      parseMidiMessage([0xB0, 123, 0])?.type,
      MidiMessageType.allNotesOff,
    );
    expect(parseMidiMessage([0xF8]), isNull);
  });

  test('parses pitch bend and modulation wheel', () {
    final bend = parseMidiMessage([0xE3, 0x00, 0x60]);
    expect(bend?.type, MidiMessageType.pitchBend);
    expect(bend?.channel, 3);
    expect(bend?.value, 0x3000);

    final centered = parseMidiMessage([0xE0, 0x00, 0x40]);
    expect(centered?.value, 8192);

    // Amostras reais do controlador do usuário (14 bits padrão).
    expect(parseMidiMessage([0xE0, 0x00, 0x00])?.value, 0); // fim para baixo
    expect(parseMidiMessage([0xE0, 0x70, 0x7F])?.value, 16368); // fim para cima
    expect(parseMidiMessage([0xE0, 0x40, 0x00])?.value, 64);

    final mod = parseMidiMessage([0xB0, 1, 96]);
    expect(mod?.type, MidiMessageType.modulation);
    expect(mod?.value, 96);
  });
}
