import 'package:flutter/services.dart';
import 'package:flutter_midi_pro/flutter_midi_pro_platform_interface.dart';

import 'src/file_utils_stub.dart' if (dart.library.io) 'src/file_utils_io.dart'
    as file_utils;

/// The FlutterMidiPro class provides functions for writing to and loading soundfont
/// files, as well as playing and stopping MIDI notes.
///
/// To use this class, you must first call the [init] method. Then, you can load a
/// soundfont file using the [loadSoundfont] method. After loading a soundfont file,
/// you can select an instrument using the [selectInstrument] method. Finally, you
/// can play and stop notes using the [playNote] and [stopNote] methods.
///
/// To stop all notes on a channel, you can use the [stopAllNotes] method.
///
/// To dispose of the FlutterMidiPro instance, you can use the [dispose] method.
class MidiPro {
  MidiPro();

  /// Loads a soundfont file from the specified asset path.
  /// Returns the sfId (SoundfontSamplerId).
  Future<int> loadSoundfontAsset({
    required String assetPath,
    int bank = 0,
    int program = 0,
  }) async {
    final byteData = await rootBundle.load(assetPath);
    final buffer = byteData.buffer;
    final data = buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    return FlutterMidiProPlatform.instance.loadSoundfontBytes(
      data,
      bank,
      program,
    );
  }

  /// Loads a soundfont file from the specified file path.
  /// Returns the sfId (SoundfontSamplerId).
  Future<int> loadSoundfontFile({
    required String filePath,
    int bank = 0,
    int program = 0,
  }) async {
    try {
      final data = await file_utils.readFileBytes(filePath);
      return await FlutterMidiProPlatform.instance.loadSoundfontBytes(
        data,
        bank,
        program,
      );
    } on UnsupportedError catch (err) {
      throw UnsupportedError(
        'loadSoundfontFile is not supported on web. Use loadSoundfontAsset or loadSoundfontData. ${err.message}',
      );
    }
  }

  /// Loads a soundfont file from the specified data.
  /// Returns the sfId (SoundfontSamplerId).
  Future<int> loadSoundfontData({
    required Uint8List data,
    int bank = 0,
    int program = 0,
  }) async {
    return FlutterMidiProPlatform.instance.loadSoundfontBytes(
      data,
      bank,
      program,
    );
  }

  /// Selects an instrument on the specified soundfont.
  /// The soundfont ID is the ID returned by the [loadSoundfont] method.
  /// The channel is a number from 1 to 16.
  /// The bank number is the bank number of the instrument on the soundfont.
  /// The program number is the program number of the instrument on the soundfont.
  /// This is the same as the patch number.
  /// If the soundfont does not have banks, set the bank number to 0.
  Future<void> selectInstrument({
    /// The soundfont ID. First soundfont loaded is 1.
    required int sfId,

    /// The program number of the instrument on the soundfont.
    /// This is the same as the patch number.
    required int program,

    /// The MIDI channel. This is a number from 0 to 15. Channel numbers start at 0.
    int channel = 0,

    /// The bank number of the instrument on the soundfont. If the soundfont does not
    /// have banks, set this to 0.
    int bank = 0,
  }) async {
    return FlutterMidiProPlatform.instance.selectInstrument(
      sfId,
      channel,
      bank,
      program,
    );
  }

  /// Plays a note on the specified channel.
  /// The channel is a number from 0 to 15.
  /// The key is the MIDI note number. This is a number from 0 to 127.
  /// The velocity is the velocity of the note. This is a number from 0 to 127.
  /// A velocity of 127 is the maximum velocity.
  /// The note will continue to play until it is stopped.
  /// To stop the note, use the [stopNote] method.
  Future<void> playNote({
    /// The MIDI channel. This is a number from 0 to 15. Channel numbers start at 0.
    int channel = 0,

    /// The MIDI note number. This is a number from 0 to 127.
    required int key,

    /// The velocity of the note. This is a number from 0 to 127.
    int velocity = 127,

    /// The soundfont ID. First soundfont loaded is 1.
    int sfId = 1,
  }) async {
    return FlutterMidiProPlatform.instance.playNote(
      channel,
      key,
      velocity,
      sfId,
    );
  }

  /// Stops a note on the specified channel.
  /// The channel is a number from 0 to 15.
  /// The key is the MIDI note number. This is a number from 0 to 127.
  /// The note will stop playing.
  /// To play the note again, use the [playNote] method.
  /// To stop all notes on a channel, use the [stopAllNotes] method.
  Future<void> stopNote({
    /// The MIDI channel. This is a number from 0 to 15. Channel numbers start at 0.
    int channel = 0,

    /// The MIDI note number. This is a number from 0 to 127.
    required int key,

    /// The soundfont ID. First soundfont loaded is 1.
    int sfId = 1,
  }) async {
    return FlutterMidiProPlatform.instance.stopNote(channel, key, sfId);
  }

  /// Stops all notes on the specified sfId.
  Future<void> stopAllNotes({
    /// The soundfont ID. First soundfont loaded is 1.
    int sfId = 1,
  }) async {
    return FlutterMidiProPlatform.instance.stopAllNotes(sfId);
  }

  /// Unloads a soundfont from memory.
  /// The soundfont ID is the ID returned by the [loadSoundfont] method.
  /// If resetPresets is true, the presets will be reset to the default values.
  Future<void> unloadSoundfont(int sfId) async {
    return FlutterMidiProPlatform.instance.unloadSoundfont(sfId);
  }

  Future<void> setAudioEffects({
    required int sfId,
    required double reverb,
    required double delay,
    required double delayTime,
    required double feedback,
    required double bass,
    required double mid,
    required double treble,
  }) async {
    return FlutterMidiProPlatform.instance.setAudioEffects(sfId, {
      'reverb': reverb,
      'delay': delay,
      'delayTime': delayTime,
      'feedback': feedback,
      'bass': bass,
      'mid': mid,
      'treble': treble,
    });
  }

  /// Aplica pitch bend (roda de pitch) no canal. [value] é o valor MIDI
  /// bruto de 14 bits (0..16383, centro 8192).
  Future<void> pitchBend({
    required int sfId,
    int channel = 0,
    required int value,
  }) async {
    return FlutterMidiProPlatform.instance.pitchBend(sfId, channel, value);
  }

  /// Envia um control change ao sintetizador (ex.: CC1 modulação, 0..127).
  Future<void> controlChange({
    required int sfId,
    int channel = 0,
    required int controller,
    required int value,
  }) async {
    return FlutterMidiProPlatform.instance
        .controlChange(sfId, channel, controller, value);
  }

  /// Disposes of the FlutterMidiPro instance.
  /// This should be called when the instance is no longer needed.
  /// This will stop all notes and unload all soundfonts.
  /// This will also release all resources used by the instance.
  /// After disposing of the instance, the instance should not be used again.
  ///
  Future<void> dispose() async {
    return FlutterMidiProPlatform.instance.dispose();
  }
}
