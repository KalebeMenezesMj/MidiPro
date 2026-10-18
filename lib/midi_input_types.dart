class MidiInputDevice {
  const MidiInputDevice({required this.id, required this.name});

  final String id;
  final String name;
}

typedef MidiMessageHandler = void Function(List<int> data);
