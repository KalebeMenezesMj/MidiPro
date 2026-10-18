enum MidiMessageType {
  noteOn,
  noteOff,
  sustain,
  volume,
  modulation,
  pitchBend,
  allNotesOff,
}

class MidiMessage {
  const MidiMessage({
    required this.type,
    required this.channel,
    this.key = 0,
    this.value = 0,
  });

  final MidiMessageType type;
  final int channel;
  final int key;
  final int value;
}

MidiMessage? parseMidiMessage(List<int> data) {
  if (data.length < 2) return null;

  final status = data[0] & 0xF0;
  final channel = data[0] & 0x0F;
  final first = data[1] & 0x7F;
  final value = data.length > 2 ? data[2] & 0x7F : 0;

  if (status == 0x80 || (status == 0x90 && value == 0)) {
    return MidiMessage(
      type: MidiMessageType.noteOff,
      channel: channel,
      key: first,
    );
  }
  if (status == 0x90) {
    return MidiMessage(
      type: MidiMessageType.noteOn,
      channel: channel,
      key: first,
      value: value,
    );
  }
  if (status == 0xE0 && data.length >= 3) {
    return MidiMessage(
      type: MidiMessageType.pitchBend,
      channel: channel,
      value: (value << 7) | first, // 14 bits, 0..16383, centro 8192
    );
  }
  if (status != 0xB0 || data.length < 3) return null;

  if (first == 64) {
    return MidiMessage(
      type: MidiMessageType.sustain,
      channel: channel,
      value: value,
    );
  }
  if (first == 1) {
    return MidiMessage(
      type: MidiMessageType.modulation,
      channel: channel,
      value: value,
    );
  }
  if (first == 7) {
    return MidiMessage(
      type: MidiMessageType.volume,
      channel: channel,
      value: value,
    );
  }
  if (first == 120 || first == 123) {
    return MidiMessage(type: MidiMessageType.allNotesOff, channel: channel);
  }
  return null;
}
