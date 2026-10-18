// Web implementation using FluidSynth WASM via js-synthesizer for smooth note playback.
import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'flutter_midi_pro_platform_interface.dart';

class FlutterMidiProWeb extends FlutterMidiProPlatform {
  // Flutter serves package assets for the web build under assets/packages/<pkg>/...
  static const _jsAssetBase =
      'assets/packages/flutter_midi_pro/assets/web/js_synthesizer';
  static const _fluidsynthModule = '$_jsAssetBase/libfluidsynth-2.4.6.js';
  static const _synthWorkletModule =
      '$_jsAssetBase/js-synthesizer.worklet.min.js';

  void _log(String message) {
    // debug logging on web to help diagnose worker/worklet failures.
    // ignore: avoid_print
    print('[flutter_midi_pro_web] $message');
  }

  static void registerWith(Registrar registrar) {
    FlutterMidiProPlatform.instance = FlutterMidiProWeb();
    registrar.registerMessageHandler();
  }

  final Map<int, _WebSynth> _synths = {};
  int _nextId = 1;
  web.AudioContext? _audioContext;
  Future<void>? _workletModuleLoader;

  Future<web.AudioContext> _ensureAudioContext() async {
    return _audioContext ??= web.AudioContext();
  }

  Future<void> _ensureWorkletModule(web.AudioContext ctx) {
    final worklet = ctx.audioWorklet;
    _workletModuleLoader ??= () async {
      _log(
        'Loading AudioWorklet modules: $_fluidsynthModule then $_synthWorkletModule',
      );
      await worklet.addModule(_fluidsynthModule).toDart;
      await worklet.addModule(_synthWorkletModule).toDart;
      _log('AudioWorklet modules loaded');
    }();
    return _workletModuleLoader!;
  }

  Future<_WebSynth> _createWorkletSynth(web.AudioContext ctx) async {
    final jsSynth = _jsSynth;
    if (jsSynth == null) {
      throw StateError('JSSynth global not found on window');
    }
    final ctor = jsSynth.audioWorkletNodeSynthesizer;
    if (ctor == null) {
      throw StateError('JSSynth.AudioWorkletNodeSynthesizer not available');
    }
    final synth = AudioWorkletNodeSynthesizer();
    synth.init(ctx.sampleRate.toJS);
    _log('AudioWorkletNodeSynthesizer initialized at ${ctx.sampleRate}');
    final node = synth.createAudioNode(ctx);
    final bass = ctx.createBiquadFilter()
      ..type = 'lowshelf'
      ..frequency.value = 120;
    final mid = ctx.createBiquadFilter()
      ..type = 'peaking'
      ..frequency.value = 1000
      ..Q.value = 0.8;
    final treble = ctx.createBiquadFilter()
      ..type = 'highshelf'
      ..frequency.value = 6000;
    final reverb = ctx.createConvolver()..buffer = _createReverbImpulse(ctx);
    final reverbWet = ctx.createGain()..gain.value = 0;
    final delay = ctx.createDelay(2)..delayTime.value = 0.28;
    final delayWet = ctx.createGain()..gain.value = 0;
    final delayFeedback = ctx.createGain()..gain.value = 0;
    final output = ctx.createGain();

    node.connect(bass);
    bass.connect(mid);
    mid.connect(treble);
    treble.connect(output);
    treble.connect(reverb);
    reverb.connect(reverbWet);
    reverbWet.connect(output);
    treble.connect(delay);
    delay.connect(delayWet);
    delayWet.connect(output);
    delay.connect(delayFeedback);
    delayFeedback.connect(delay);
    output.connect(ctx.destination);
    _log('AudioWorklet node and browser effects chain connected');
    return _WebSynth(
      synth: synth,
      node: node,
      bass: bass,
      mid: mid,
      treble: treble,
      reverb: reverb,
      reverbWet: reverbWet,
      delay: delay,
      delayWet: delayWet,
      delayFeedback: delayFeedback,
      output: output,
      ready: Completer<void>()..complete(), // init done immediately
    );
  }

  web.AudioBuffer _createReverbImpulse(web.AudioContext ctx) {
    final length = (ctx.sampleRate * 2).round();
    final impulse = ctx.createBuffer(2, length, ctx.sampleRate);
    final random = math.Random(1);
    for (var channel = 0; channel < 2; channel++) {
      final samples = impulse.getChannelData(channel).toDart;
      for (var index = 0; index < length; index++) {
        final decay = 1 - index / length;
        samples[index] = (random.nextDouble() * 2 - 1) * decay * decay;
      }
    }
    return impulse;
  }

  @override
  Future<int> loadSoundfont(String path, int bank, int program) async {
    final byteData = await rootBundle.load(path);
    final data = byteData.buffer.asUint8List(
      byteData.offsetInBytes,
      byteData.lengthInBytes,
    );
    return loadSoundfontBytes(data, bank, program);
  }

  @override
  Future<int> loadSoundfontBytes(Uint8List data, int bank, int program) async {
    final ctx = await _ensureAudioContext();
    await _ensureWorkletModule(ctx);
    final synth = await _createWorkletSynth(ctx);
    _log(
      'AudioWorklet synth created, loading SoundFont (${data.lengthInBytes} bytes)',
    );
      final sfontId =
          (await synth.synth.loadSFont(data.buffer.toJS).toDart).toDartInt;
      synth.soundfontId = sfontId;
    _log('SoundFont loaded id=$sfontId, selecting programs across channels');
    // Default program selection across all channels to align with native behavior.
    for (var channel = 0; channel < 16; channel++) {
      synth.synth.midiProgramSelect(
        channel.toJS,
        sfontId.toJS,
        bank.toJS,
        program.toJS,
      );
    }

    final id = _nextId++;
    synth.id = id;
    synth.soundfontId = sfontId;
    _synths[id] = synth;
    return id;
  }

  @override
  Future<void> selectInstrument(
    int sfId,
    int channel,
    int bank,
    int program,
  ) async {
    final synth = _synths[sfId];
    final sfontId = synth?.soundfontId;
    if (synth == null || sfontId == null) return;
    _log(
      'selectInstrument sfId=$sfId channel=$channel bank=$bank program=$program',
    );
    synth.synth.midiProgramSelect(
      channel.toJS,
      sfontId.toJS,
      bank.toJS,
      program.toJS,
    );
  }

  @override
  Future<void> playNote(int channel, int key, int velocity, int sfId) async {
    final synth = _synths[sfId];
    if (synth == null) return;
    if (_audioContext != null) {
      try {
        await _audioContext!.resume().toDart;
      } catch (_) {
        // ignore
      }
    }
    _log('noteOn sfId=$sfId channel=$channel key=$key velocity=$velocity');
    synth.synth.midiNoteOn(channel.toJS, key.toJS, velocity.toJS);
  }

  @override
  Future<void> stopNote(int channel, int key, int sfId) async {
    final synth = _synths[sfId];
    if (synth == null) return;
    _log('noteOff sfId=$sfId channel=$channel key=$key');
    synth.synth.midiNoteOff(channel.toJS, key.toJS);
  }

  @override
  Future<void> stopAllNotes(int sfId) async {
    final synth = _synths[sfId];
    if (synth == null) return;
    _log('stopAllNotes sfId=$sfId');
    for (var channel = 0; channel < 16; channel++) {
      synth.synth.midiAllNotesOff(channel.toJS);
      synth.synth.midiAllSoundsOff(channel.toJS);
    }
    synth.synth.midiSystemReset();
  }

  @override
  Future<void> setAudioEffects(int sfId, Map<String, double> effects) async {
    final synth = _synths[sfId];
    if (synth == null) return;

    final reverb = (effects['reverb'] ?? 0).clamp(0.0, 1.0).toDouble();
    synth.reverbWet.gain.value = reverb * 0.6;
    synth.bass.gain.value = (effects['bass'] ?? 0).clamp(-12.0, 12.0);
    synth.mid.gain.value = (effects['mid'] ?? 0).clamp(-12.0, 12.0);
    synth.treble.gain.value = (effects['treble'] ?? 0).clamp(-12.0, 12.0);

    final delayLevel = (effects['delay'] ?? 0).clamp(0.0, 1.0);
    synth.delay.delayTime.value = (effects['delayTime'] ?? 0.28).clamp(
      0.08,
      0.8,
    );
    synth.delayWet.gain.value = delayLevel * 0.45;
    synth.delayFeedback.gain.value = delayLevel == 0
        ? 0
        : (effects['feedback'] ?? 0.25).clamp(0.0, 0.78);
  }

  @override
  Future<void> pitchBend(int sfId, int channel, int value) async {
    final synth = _synths[sfId];
    if (synth == null) return;
    // Esta build do FluidSynth espera o valor MIDI bruto de 14 bits
    // (0..16383, centro 8192), sem conversão para valor com sinal.
    _log('pitchBend sfId=$sfId channel=$channel raw=$value');
    synth.synth.midiPitchBend(channel.toJS, value.toJS);
  }

  @override
  Future<void> controlChange(
    int sfId,
    int channel,
    int controller,
    int value,
  ) async {
    final synth = _synths[sfId];
    if (synth == null) return;
    synth.synth.midiControl(
      channel.toJS,
      controller.toJS,
      value.toJS,
    );
  }

  @override
  Future<void> unloadSoundfont(int sfId) async {
    final synth = _synths.remove(sfId);
    if (synth == null) return;
    synth.synth.midiSystemReset();
    synth.synth.unloadSFont(synth.soundfontId?.toJS ?? 0.toJS);
    synth.node.disconnect();
    synth.bass.disconnect();
    synth.mid.disconnect();
    synth.treble.disconnect();
    synth.reverb.disconnect();
    synth.reverbWet.disconnect();
    synth.delay.disconnect();
    synth.delayWet.disconnect();
    synth.delayFeedback.disconnect();
    synth.output.disconnect();
    synth.synth.close();
  }

  @override
  Future<void> dispose() async {
    final ids = List<int>.from(_synths.keys);
    for (final id in ids) {
      await unloadSoundfont(id);
    }
    _synths.clear();
  }
}

class _WebSynth {
  _WebSynth({
    required this.node,
    required this.bass,
    required this.mid,
    required this.treble,
    required this.reverb,
    required this.reverbWet,
    required this.delay,
    required this.delayWet,
    required this.delayFeedback,
    required this.output,
    required this.ready,
    required this.synth,
  });

  int? id;
  final web.AudioWorkletNode node;
  final web.BiquadFilterNode bass;
  final web.BiquadFilterNode mid;
  final web.BiquadFilterNode treble;
  final web.ConvolverNode reverb;
  final web.GainNode reverbWet;
  final web.DelayNode delay;
  final web.GainNode delayWet;
  final web.GainNode delayFeedback;
  final web.GainNode output;
  final Completer<void> ready;
  final AudioWorkletNodeSynthesizer synth;
  int? soundfontId;
}

@JS('JSSynth')
external _JSSynth? get _jsSynth;

@JS('JSSynth')
@staticInterop
class _JSSynth {}

extension _JSSynthExt on _JSSynth {
  @JS('AudioWorkletNodeSynthesizer')
  external JSFunction? get audioWorkletNodeSynthesizer;
}

@JS('JSSynth.AudioWorkletNodeSynthesizer')
@staticInterop
class AudioWorkletNodeSynthesizer {
  external factory AudioWorkletNodeSynthesizer();
}

extension AudioWorkletNodeSynthesizerExt on AudioWorkletNodeSynthesizer {
  external void init(JSNumber sampleRate);
  external web.AudioWorkletNode createAudioNode(web.BaseAudioContext context);
  external JSPromise<JSNumber> loadSFont(JSArrayBuffer buffer);
  external void midiProgramSelect(
    JSAny channel,
    JSAny sfontId,
    JSAny bank,
    JSAny program,
  );
  external void midiNoteOn(JSAny channel, JSAny key, JSAny velocity);
  external void midiNoteOff(JSAny channel, JSAny key);
  external void midiPitchBend(JSAny channel, JSAny value);
  external void midiControl(JSAny channel, JSAny controller, JSAny value);
  external void midiAllNotesOff(JSAny channel);
  external void midiAllSoundsOff(JSAny channel);
  external void midiSystemReset();
  external void unloadSFont(JSAny sfontId);
  external void close();
}
