import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_midi_pro/flutter_midi_pro.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'builtin_soundfonts.dart';
import 'soundfont.dart';
import 'soundfont_folder_picker_stub.dart'
    if (dart.library.js_interop) 'soundfont_folder_picker_web.dart';
import 'soundfont_store.dart';
import 'midi_input.dart';
import 'midi_message.dart';
import 'metronome.dart';
import 'performance_preset.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: AppColors.background,
      systemNavigationBarColor: AppColors.background,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
  }
  runApp(const MidiProApp());
}

/// Limite de camadas simultâneas (cada uma carrega um SoundFont próprio).
const int maxLayers = 6;

abstract final class AppColors {
  static const background = Color(0xFF111111);
  static const surface = Color(0xFF161616);
  static const raised = Color(0xFF232323);
  static const line = Color(0xFF3A3A3A);
  static const accent = Color(0xFFD9A93F);
  static const accentWash = Color(0xFF2A2418);
  static const ivory = Color(0xFFC9BFA6);
  static const secondary = Color(0xFF9C968A);
  static const muted = Color(0xFF6E6A61);
  static const blackKey = Color(0xFF181818);
  static const sheet = Color(0xFF1B1B1B);
  static const sheetRaised = Color(0xFF1E1E1E);
}

class MidiProApp extends StatelessWidget {
  const MidiProApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MIDI Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.background,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          secondary: AppColors.ivory,
          surface: AppColors.surface,
        ),
        fontFamily: 'sans-serif',
        useMaterial3: true,
        sliderTheme: const SliderThemeData(
          activeTrackColor: AppColors.accent,
          inactiveTrackColor: AppColors.line,
          thumbColor: AppColors.ivory,
          overlayColor: Color(0x22D9A93F),
          trackHeight: 3,
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: AppColors.raised,
          contentTextStyle: TextStyle(color: AppColors.ivory),
        ),
        dialogTheme: const DialogThemeData(
          backgroundColor: AppColors.raised,
        ),
      ),
      home: const PianoHome(),
    );
  }
}

class LoadedSoundfont {
  LoadedSoundfont({
    required this.font,
    required this.id,
    LayerEffects? effects,
  }) : effects = effects ?? LayerEffects();

  final SoundFont font;
  final int id;
  final LayerEffects effects;
}

class PianoHome extends StatefulWidget {
  const PianoHome({super.key});

  @override
  State<PianoHome> createState() => _PianoHomeState();
}

class _PianoHomeState extends State<PianoHome> with WidgetsBindingObserver {
  final MidiPro _midi = MidiPro();
  final SoundfontStore _library = SoundfontStore();
  final MidiInput _midiInput = MidiInput();
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  final MetronomeOutput _metronomeOutput = MetronomeOutput();
  List<SoundFont> _soundfonts = const [];
  final List<LoadedSoundfont> _layers = [];
  List<PerformancePreset> _savedPresets = const [];
  MidiInputDevice? _midiDevice;
  final Set<(int, int)> _sustainedNotes = {};
  int _octave = 3;
  double _volume = 0.78;
  int _bpm = 100;
  int? _selectedLayerId;
  bool _engineReady = false;
  bool _starting = true;
  bool _loadingFont = false;
  bool _importing = false;
  int _importProgress = 0;
  int _importTotal = 0;
  bool _connectingMidi = false;
  bool _sustain = false;

  /// Timers de segurar-nota agendados por camada ao soltar o pedal.
  final List<Timer> _sustainHoldTimers = [];

  /// Posição visual da roda de pitch (14 bits, centro 8192).
  int _pitchBendRaw = 8192;

  /// Sensibilidade da roda de pitch em semitons.
  double _pitchBendRange = 2;

  /// Posição visual da roda de modulação (0..127).
  int _modWheel = 0;
  bool _metronomeRunning = false;
  Timer? _metronomeTimer;
  int _metronomeBeat = 0;
  String? _engineError;

  SoundFont? get _selected => _layers.isEmpty ? null : _layers.first.font;
  int? get _soundfontId => _layers.isEmpty ? null : _layers.first.id;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _metronomeTimer?.cancel();
    for (final timer in _sustainHoldTimers) {
      timer.cancel();
    }
    unawaited(_metronomeOutput.dispose());
    if (_layers.isNotEmpty) unawaited(_midi.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      if (_metronomeRunning) {
        _metronomeTimer?.cancel();
        setState(() => _metronomeRunning = false);
      }
      if (_layers.isNotEmpty) {
        _sustainedNotes.clear();
        for (final layer in _layers) {
          unawaited(_midi.stopAllNotes(sfId: layer.id).catchError((Object _) {}));
        }
      }
    }
  }

  Future<void> _initialize() async {
    try {
      if (!mounted) return;
      setState(() => _engineReady = true);

      final fonts = await _library.scan();
      final presets = await _loadSavedPresets();
      if (!mounted) return;
      final library = mergeBuiltinSoundfonts(fonts);
      setState(() {
        _soundfonts = library;
        _savedPresets = presets;
      });
      if (library.isNotEmpty) await _selectSoundfont(library.first);
    } catch (error) {
      if (mounted) setState(() => _engineError = error.toString());
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _importSoundfontFolder() async {
    if (_importing) return;
    if (!kIsWeb) {
      _showMessage('A importação por pasta está disponível no navegador.');
      return;
    }
    setState(() => _importing = true);

    try {
      final files = await pickSoundfontFolder();
      if (files == null || files.isEmpty) return;

      setState(() {
        _importProgress = 0;
        _importTotal = files.length;
      });
      final imported = await _library.importWebFiles(
        files,
        onProgress: (completed, total) {
          if (mounted) {
            setState(() {
              _importProgress = completed;
              _importTotal = total;
            });
          }
        },
      );

      await _completeImport(imported);
    } catch (_) {
      _showMessage('Não foi possível importar a pasta de timbres.');
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
          _importProgress = 0;
          _importTotal = 0;
        });
      }
    }
  }

  Future<void> _completeImport(int imported) async {
    final fonts = await _library.scan();
    if (!mounted) return;
    final library = mergeBuiltinSoundfonts(fonts);
    setState(() => _soundfonts = library);

    if (library.isNotEmpty &&
        _engineReady &&
        (kIsWeb || _selected == null)) {
      await _selectSoundfont(library.first);
    }
    if (mounted) {
      final message = imported > 0
          ? '$imported timbre${imported == 1 ? '' : 's'} importado${imported == 1 ? '' : 's'}'
          : 'Nenhum SoundFont válido foi importado';
      _showMessage(message);
    }
  }

  Future<int> _loadSoundfont(SoundFont font) async {
    if (font.builtin && font.path != null) {
      // Timbres nativos: lidos direto dos assets do pacote (em qualquer
      // plataforma o plugin persiste os bytes num temp e carrega).
      final byteData = await rootBundle.load(font.path!);
      final data = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      return _midi.loadSoundfontData(data: data, bank: 0, program: 0);
    }
    if (kIsWeb) {
      final data = await _library.readData(font) ?? font.data;
      if (data == null) {
        throw StateError('O SoundFont não está salvo na biblioteca.');
      }
      return _midi.loadSoundfontData(data: data, bank: 0, program: 0);
    }
    final path = font.path;
    if (path == null) throw StateError('O caminho do SoundFont está indisponível.');
    return _midi.loadSoundfontFile(filePath: path, bank: 0, program: 0);
  }

  Future<void> _applyAudioEffectsTo(int sfId, LayerEffects effects) async {
    try {
      await _midi.setAudioEffects(
        sfId: sfId,
        reverb: effects.reverb,
        delay: effects.delay,
        delayTime: effects.delayTime,
        feedback: effects.feedback,
        bass: effects.bass,
        mid: effects.mid,
        treble: effects.treble,
      );
    } catch (_) {
      // Plataformas sem efeitos nativos apenas ignoram.
    }
  }

  Future<void> _selectSoundfont(SoundFont font) async {
    if (_layers.length == 1 && _selected?.id == font.id) return;
    await _replaceLayers([font]);
  }

  Future<bool> _replaceLayers(
    List<SoundFont> fonts, {
    List<LayerEffects>? layerEffects,
  }) async {
    if (!_engineReady || _loadingFont || fonts.isEmpty) return false;
    setState(() {
      _loadingFont = true;
      _engineError = null;
    });

    final previousLayers = List<LoadedSoundfont>.of(_layers);
    final nextLayers = <LoadedSoundfont>[];
    try {
      _sustainedNotes.clear();
      for (final timer in _sustainHoldTimers) {
        timer.cancel();
      }
      _sustainHoldTimers.clear();
      for (final layer in previousLayers) {
        await _midi.stopAllNotes(sfId: layer.id);
      }

      final limited = fonts.take(maxLayers).toList();
      for (var index = 0; index < limited.length; index++) {
        final font = limited[index];
        final id = await _loadSoundfont(font);
        final layer = LoadedSoundfont(
          font: font,
          id: id,
          effects: layerEffects != null && index < layerEffects.length
              ? layerEffects[index].copy()
              : null,
        );
        nextLayers.add(layer);
        await _applyAudioEffectsTo(id, layer.effects);
        _applyPitchBendRangeTo(id);
      }
      for (final layer in previousLayers) {
        await _midi.unloadSoundfont(layer.id);
      }
      if (!mounted) return false;
      setState(() {
        _layers
          ..clear()
          ..addAll(nextLayers);
        _selectedLayerId = nextLayers.isEmpty ? null : nextLayers.first.id;
      });
      return true;
    } catch (_) {
      for (final layer in nextLayers) {
        try {
          await _midi.unloadSoundfont(layer.id);
        } catch (_) {}
      }
      _showMessage('Não foi possível carregar os timbres selecionados.');
      return false;
    } finally {
      if (mounted) setState(() => _loadingFont = false);
    }
  }

  Future<void> _addLayer(SoundFont font) async {
    if (_layers.any((layer) => layer.font.id == font.id)) {
      _showMessage('Esse timbre já está em uma camada.');
      return;
    }
    if (_layers.length >= maxLayers) {
      _showMessage('O máximo são $maxLayers camadas simultâneas.');
      return;
    }
    if (_layers.isEmpty) {
      await _selectSoundfont(font);
      return;
    }
    if (!_engineReady || _loadingFont) return;

    setState(() => _loadingFont = true);
    int? id;
    try {
      id = await _loadSoundfont(font);
      final layer = LoadedSoundfont(font: font, id: id);
      await _applyAudioEffectsTo(id, layer.effects);
      _applyPitchBendRangeTo(id);
      if (!mounted) return;
      setState(() {
        _layers.add(layer);
        _selectedLayerId = id;
      });
      _showMessage('Camada adicionada: ${font.displayName}');
    } catch (_) {
      if (id != null) {
        try {
          await _midi.unloadSoundfont(id);
        } catch (_) {}
      }
      _showMessage('Não foi possível adicionar ${font.displayName}.');
    } finally {
      if (mounted) setState(() => _loadingFont = false);
    }
  }

  Future<void> _removeLayer(int id) async {
    LoadedSoundfont? layer;
    for (final item in _layers) {
      if (item.id == id) {
        layer = item;
        break;
      }
    }
    if (layer == null) return;
    _sustainedNotes.clear();
    await _midi.stopAllNotes(sfId: id);
    await _midi.unloadSoundfont(id);
    if (mounted) {
      setState(() {
        _layers.removeWhere((item) => item.id == id);
        if (_selectedLayerId == id) {
          _selectedLayerId = _layers.isEmpty ? null : _layers.first.id;
        }
      });
    }
  }

  Future<List<PerformancePreset>> _loadSavedPresets() async {
    try {
      final data = await _preferences.getString('midipro.presets.v1');
      if (data == null) return const [];
      return (jsonDecode(data) as List)
          .map((item) => PerformancePreset.fromJson(
                Map<String, dynamic>.from(item as Map),
              ))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persistPresets() async {
    await _preferences.setString(
      'midipro.presets.v1',
      jsonEncode(_savedPresets.map((preset) => preset.toJson()).toList()),
    );
  }

  Future<void> _savePreset() async {
    if (_layers.isEmpty) {
      _showMessage('Carregue um timbre antes de salvar um preset.');
      return;
    }
    final controller = TextEditingController(text: _selected!.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFFF1F0F7),
        title: const Text(
          'Salvar configuração',
          style: TextStyle(color: Color(0xFF1A191D), fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Color(0xFF1A191D)),
          decoration: const InputDecoration(
            labelText: 'Nome do preset',
            labelStyle: TextStyle(color: Color(0xFF6B6770)),
            enabledBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFFB9B5BE)),
            ),
            focusedBorder: OutlineInputBorder(
              borderSide: BorderSide(color: Color(0xFF8A6D1F), width: 1.5),
            ),
          ),
          onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancelar',
                style: TextStyle(color: Color(0xFF1A191D))),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFD9A93F),
              foregroundColor: const Color(0xFF1A160C),
            ),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    controller.dispose();
    final trimmedName = name?.trim();
    if (trimmedName == null || trimmedName.isEmpty) return;

    final preset = PerformancePreset(
      name: trimmedName,
      soundfontIds: _layers.map((layer) => layer.font.id).toList(),
      volume: _volume,
      bpm: _bpm,
      pitchBendRange: _pitchBendRange,
      layerEffects: [
        for (final layer in _layers) layer.effects.copy(),
      ],
    );
    final updated = _savedPresets
        .where((item) => item.name.toLowerCase() != trimmedName.toLowerCase())
        .toList()
      ..insert(0, preset);
    setState(() => _savedPresets = updated);
    await _persistPresets();
    _showMessage('Preset "$trimmedName" salvo.');
  }

  Future<void> _deletePreset(PerformancePreset preset) async {
    setState(() => _savedPresets =
        _savedPresets.where((item) => item.name != preset.name).toList());
    await _persistPresets();
  }

  Future<void> _loadPreset(PerformancePreset preset) async {
    final byId = {for (final font in _soundfonts) font.id: font};
    final fonts = <SoundFont>[];
    for (final id in preset.soundfontIds) {
      final font = byId[id];
      if (font != null) fonts.add(font);
    }
    if (fonts.length != preset.soundfontIds.length || fonts.isEmpty) {
      _showMessage('Algum timbre deste preset não está na biblioteca.');
      return;
    }

    _metronomeTimer?.cancel();
    setState(() {
      _metronomeRunning = false;
      _volume = preset.volume;
      _bpm = preset.bpm;
      _pitchBendRange = preset.pitchBendRange;
    });
    // Presets antigos têm efeitos globais; novos têm efeitos por camada.
    final effects = preset.layerEffects;
    final fallback = LayerEffects(
      reverb: preset.reverb,
      delay: preset.delay,
      delayTime: preset.delayTime,
      feedback: preset.feedback,
      bass: preset.bass,
      mid: preset.mid,
      treble: preset.treble,
      sustainSeconds: preset.sustainSeconds,
    );
    if (await _replaceLayers(
      fonts,
      layerEffects: effects != null && effects.length == fonts.length
          ? effects
          : [for (var index = 0; index < fonts.length; index++) fallback],
    )) {
      _showMessage('Preset "${preset.name}" carregado.');
    }
  }

  /// Atualiza um efeito da camada [id] e reaplica no sintetizador.
  void _setLayerEffectApplied(int id) {
    LoadedSoundfont? layer;
    for (final item in _layers) {
      if (item.id == id) {
        layer = item;
        break;
      }
    }
    if (layer == null) return;
    setState(() {});
    unawaited(_applyAudioEffectsTo(id, layer.effects));
  }

  void _toggleMetronome() {
    if (_metronomeRunning) {
      _metronomeTimer?.cancel();
      setState(() => _metronomeRunning = false);
      return;
    }
    setState(() => _metronomeRunning = true);
    _metronomeBeat = 0;
    _metronomeTick();
    _scheduleMetronome();
  }

  void _scheduleMetronome() {
    _metronomeTimer?.cancel();
    if (!_metronomeRunning) return;
    _metronomeTimer = Timer.periodic(
      Duration(milliseconds: (60000 / _bpm).round()),
      (_) => _metronomeTick(),
    );
  }

  void _metronomeTick() {
    final accent = _metronomeBeat % 4 == 0;
    _metronomeBeat++;
    unawaited(_metronomeOutput.click(accent: accent).catchError((Object _) {}));
  }

  void _setBpm(int value) {
    setState(() => _bpm = value.clamp(40, 240));
    if (_metronomeRunning) _scheduleMetronome();
  }

  void _toggleSustain() {
    _setSustain(!_sustain);
  }

  void _setSustain(bool enabled) {
    if (_sustain == enabled) return;
    setState(() => _sustain = enabled);
    if (enabled) {
      for (final timer in _sustainHoldTimers) {
        timer.cancel();
      }
      _sustainHoldTimers.clear();
      return;
    }
    if (_sustainedNotes.isEmpty) return;
    final notes = _sustainedNotes.toList();
    _sustainedNotes.clear();
    for (final layer in _layers) {
      final seconds = layer.effects.sustainSeconds;
      if (seconds <= 0) {
        _stopLayerNotes(layer, notes);
        continue;
      }
      _sustainHoldTimers.add(
        Timer(
          Duration(milliseconds: (seconds * 1000).round()),
          () => _stopLayerNotes(layer, notes),
        ),
      );
    }
  }

  void _stopLayerNotes(LoadedSoundfont layer, List<(int, int)> notes) {
    for (final (channel, key) in notes) {
      unawaited(
        _midi
            .stopNote(sfId: layer.id, channel: channel, key: key)
            .catchError((Object _) {}),
      );
    }
  }

  void _setVolume(double value) {
    setState(() => _volume = value);
  }

  void _noteOn(int key, int velocity) {
    _playNote(key, velocity);
  }

  void _playNote(int key, int velocity, {int channel = 0}) {
    final scaledVelocity = (velocity * _volume).round().clamp(0, 127).toInt();
    if (_layers.isEmpty ||
        !_engineReady ||
        _loadingFont ||
        scaledVelocity == 0) {
      return;
    }
    for (final layer in _layers) {
      unawaited(
        _midi
            .playNote(
              sfId: layer.id,
              channel: channel,
              key: key,
              velocity: scaledVelocity,
            )
            .catchError((Object _) {}),
      );
    }
  }

  void _noteOff(int key, {int channel = 0}) {
    if (_sustain) {
      _sustainedNotes.add((channel, key));
      return;
    }
    _stopNote(key, channel: channel);
  }

  void _stopNote(int key, {int channel = 0}) {
    if (_layers.isEmpty || !_engineReady) return;
    for (final layer in _layers) {
      unawaited(
        _midi
            .stopNote(sfId: layer.id, channel: channel, key: key)
            .catchError((Object _) {}),
      );
    }
  }

  void _handleMidiMessage(List<int> data) {
    final message = parseMidiMessage(data);
    if (message == null) return;

    switch (message.type) {
      case MidiMessageType.noteOn:
        _playNote(message.key, message.value, channel: message.channel);
        break;
      case MidiMessageType.noteOff:
        _noteOff(message.key, channel: message.channel);
        break;
      case MidiMessageType.sustain:
        _setSustain(message.value >= 64);
        break;
      case MidiMessageType.volume:
        _setVolume(message.value / 127);
        break;
      case MidiMessageType.pitchBend:
        _applyPitchBend(message.value, channel: message.channel);
        break;
      case MidiMessageType.modulation:
        _applyModWheel(message.value, channel: message.channel);
        break;
      case MidiMessageType.allNotesOff:
        _sustainedNotes.clear();
        for (final layer in _layers) {
          unawaited(
            _midi.stopAllNotes(sfId: layer.id).catchError((Object _) {}),
          );
        }
        break;
    }
  }

  /// Aplica pitch bend (14 bits) a todas as camadas e atualiza o indicador.
  void _applyPitchBend(int value, {int channel = 0}) {
    setState(() => _pitchBendRaw = value);
    for (final layer in _layers) {
      unawaited(
        _midi
            .pitchBend(sfId: layer.id, channel: channel, value: value)
            .catchError((Object _) {}),
      );
    }
  }

  /// Aplica modulação (CC1, 0..127) a todas as camadas e atualiza o indicador.
  void _applyModWheel(int value, {int channel = 0}) {
    setState(() => _modWheel = value);
    for (final layer in _layers) {
      unawaited(
        _midi
            .controlChange(
              sfId: layer.id,
              channel: channel,
              controller: 1,
              value: value,
            )
            .catchError((Object _) {}),
      );
    }
  }

  void _setPitchBendRange(double value) {
    setState(() => _pitchBendRange = value);
    for (final layer in _layers) {
      _applyPitchBendRangeTo(layer.id);
    }
  }

  void _applyPitchBendRangeTo(int sfId) {
    unawaited(
      _midi
          .pitchWheelSensitivity(sfId: sfId, channel: 0, semitones: _pitchBendRange)
          .catchError((Object _) {}),
    );
  }

  Future<void> _toggleMidiInput() async {
    if (_connectingMidi) return;
    setState(() => _connectingMidi = true);

    try {
      if (_midiDevice != null) {
        await _midiInput.disconnect();
        for (final layer in _layers) {
          await _midi.stopAllNotes(sfId: layer.id);
        }
        _sustainedNotes.clear();
        if (mounted) setState(() => _midiDevice = null);
        _showMessage('Dispositivo MIDI desconectado');
        return;
      }

      final devices = await _midiInput.requestAccess();
      if (!mounted) return;
      if (devices.isEmpty) {
        _showMessage('Nenhuma entrada MIDI encontrada. Conecte um teclado e tente novamente.');
        return;
      }

      final device = devices.length == 1
          ? devices.single
          : await _chooseMidiInput(devices);
      if (device == null || !mounted) return;

      await _midiInput.connect(device.id, _handleMidiMessage);
      if (!mounted) return;
      setState(() => _midiDevice = device);
      _showMessage('MIDI conectado: ${device.name}');
    } catch (_) {
      _showMessage(
        'Não foi possível acessar MIDI. Use Chrome/Edge em localhost ou HTTPS e permita o acesso.',
      );
    } finally {
      if (mounted) setState(() => _connectingMidi = false);
    }
  }

  Future<MidiInputDevice?> _chooseMidiInput(
    List<MidiInputDevice> devices,
  ) =>
      showModalBottomSheet<MidiInputDevice>(
        context: context,
        backgroundColor: AppColors.background,
        builder: (context) => SafeArea(
          child: SizedBox(
            height: (MediaQuery.sizeOf(context).height * 0.55)
                .clamp(240.0, 440.0)
                .toDouble(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 22, 20, 4),
                  child: Text(
                    'Entrada MIDI',
                    style: TextStyle(
                      color: AppColors.ivory,
                      fontFamily: 'sans-serif',
                      fontSize: 24,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Text(
                    'Escolha o teclado ou controlador conectado.',
                    style: TextStyle(color: AppColors.muted, fontSize: 12),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: devices.length,
                    itemBuilder: (context, index) {
                      final device = devices[index];
                      return ListTile(
                        leading: const Icon(
                          Icons.piano_rounded,
                          color: AppColors.accent,
                        ),
                        title: Text(device.name),
                        onTap: () => Navigator.of(context).pop(device),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Future<void> _showSoundfontPicker({bool asLayer = false}) async {
    final font = await showModalBottomSheet<SoundFont>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        height: MediaQuery.sizeOf(sheetContext).height * 0.84,
        decoration: const BoxDecoration(
          color: AppColors.sheet,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        clipBehavior: Clip.antiAlias,
        child: SoundfontPicker(
          fonts: _soundfonts,
          selectedPath: _selected?.id,
          onImportFolder: () {
            Navigator.of(sheetContext).pop();
            unawaited(_importSoundfontFolder());
          },
          onDelete: (font) {
            Navigator.of(sheetContext).pop();
            unawaited(_confirmDeleteSoundfont(font));
          },
        ),
      ),
    );
    if (font != null) {
      if (asLayer) {
        await _addLayer(font);
      } else {
        await _selectSoundfont(font);
      }
    }
  }

  Future<void> _deleteSoundfont(SoundFont font) async {
    final active = _layers.where((layer) => layer.font.id == font.id).toList();
    for (final layer in active) {
      await _removeLayer(layer.id);
    }
    await _library.delete(font);
    final fonts = await _library.scan();
    if (!mounted) return;
    setState(() => _soundfonts = fonts);
    if (_layers.isEmpty && fonts.isNotEmpty) await _selectSoundfont(fonts.first);
    _showMessage('${font.displayName} removido da biblioteca.');
  }

  Future<void> _confirmDeleteSoundfont(SoundFont font) async {
    if (font.builtin) {
      _showMessage('Os timbres nativos não podem ser removidos.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Remover timbre?'),
        content: Text('${font.displayName} será removido da biblioteca local.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteSoundfont(font);
  }

  Future<void> _showLayerManager() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.background,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Camadas de timbre',
                style: TextStyle(
                  color: AppColors.ivory,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Combine até dois pianos; ambos tocam a mesma nota.',
                style: TextStyle(color: AppColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              for (var index = 0; index < _layers.length; index++)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: AppColors.accentWash,
                    child: Text('${index + 1}', style: const TextStyle(color: AppColors.accent)),
                  ),
                  title: Text(_layers[index].font.displayName),
                  subtitle: Text(_layers[index].font.category),
                  trailing: IconButton(
                    tooltip: 'Remover camada',
                    onPressed: () {
                      final id = _layers[index].id;
                      Navigator.of(sheetContext).pop();
                      unawaited(_removeLayer(id));
                    },
                    icon: const Icon(Icons.close_rounded, color: AppColors.muted),
                  ),
                ),
              const SizedBox(height: 8),
              if (_layers.length < maxLayers)
                OutlinedButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    unawaited(_showSoundfontPicker(asLayer: true));
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Adicionar outra camada'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.ivory,
                    side: const BorderSide(color: AppColors.line),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showStudioTools() async {
    if (_layers.isNotEmpty &&
        !_layers.any((layer) => layer.id == _selectedLayerId)) {
      _selectedLayerId = _layers.first.id;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        height: MediaQuery.sizeOf(sheetContext).height * 0.9,
        decoration: const BoxDecoration(
          color: AppColors.sheetRaised,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: AppColors.line)),
        ),
        clipBehavior: Clip.antiAlias,
        child: StudioToolsSheet(
          layers: List.unmodifiable(_layers),
          presets: _savedPresets,
          selectedLayerId: _selectedLayerId,
          bpm: _bpm,
          metronomeRunning: _metronomeRunning,
          pitchBendRange: _pitchBendRange,
          supportsAudioEffects:
              kIsWeb || defaultTargetPlatform == TargetPlatform.android,
          onSelectLayer: (id) => setState(() => _selectedLayerId = id),
          onLayerEffect: _setLayerEffectApplied,
          onBpm: _setBpm,
          onToggleMetronome: _toggleMetronome,
          onPitchBendRange: _setPitchBendRange,
          onSavePreset: () {
            Navigator.of(sheetContext).pop();
            unawaited(_savePreset());
          },
          onLoadPreset: (preset) {
            Navigator.of(sheetContext).pop();
            unawaited(_loadPreset(preset));
          },
          onDeletePreset: (preset) {
            Navigator.of(sheetContext).pop();
            unawaited(_deletePreset(preset));
          },
          onAddLayer: () {
            Navigator.of(sheetContext).pop();
            unawaited(_showSoundfontPicker(asLayer: true));
          },
          onRemoveLayer: (id) {
            Navigator.of(sheetContext).pop();
            unawaited(_removeLayer(id));
          },
        ),
      ),
    );
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppColors.raised,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxHeight < 560;
                final keyboardHeight = (constraints.maxHeight * 0.31)
                    .clamp(168.0, 226.0)
                    .toDouble();
                final controlsGap =
                    (constraints.maxHeight - 650).clamp(18.0, 84.0).toDouble();
                final firstMidiNote = (_octave + 1) * 12;

                if (compact) {
                  return _buildCompactLayout(firstMidiNote: firstMidiNote);
                }

                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildHeader(),
                      const SizedBox(height: 12),
                      _buildModeTabs(),
                      const SizedBox(height: 10),
                      _buildVolumeControl(),
                      const SizedBox(height: 10),
                      _buildPitchModIndicators(),
                      const SizedBox(height: 10),
                      _buildPerformanceControls(),
                      SizedBox(height: controlsGap),
                      Row(
                        children: [
                          Text('TECLADO', style: _eyebrowStyle),
                          const Spacer(),
                          Text(
                            '${midiNoteName(firstMidiNote)} — ${midiNoteName(firstMidiNote + 23)}',
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontFamily: 'sans-serif',
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        height: keyboardHeight,
                        child: PianoKeyboard(
                          key: ValueKey(_soundfontId),
                          firstMidiNote: firstMidiNote,
                          enabled: _soundfontId != null && !_loadingFont,
                          onNoteOn: _noteOn,
                          onNoteOff: _noteOff,
                        ),
                      ),
                      const SizedBox(height: 9),
                      Row(
                        children: [
                          Icon(
                            _soundfontId == null
                                ? Icons.info_outline_rounded
                                : Icons.touch_app_outlined,
                            color: AppColors.muted,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _soundfontId == null
                                  ? 'Importe um timbre SF2 para começar'
                                  : _midiDevice != null
                                      ? 'MIDI conectado · ${_midiDevice!.name}'
                                      : kIsWeb
                                          ? 'Toque no piano ou conecte um teclado MIDI'
                                          : 'Toque ou deslize pelas teclas para tocar',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          Text(
                            '${_soundfonts.length} TIMBRE${_soundfonts.length == 1 ? '' : 'S'}',
                            style: const TextStyle(
                              color: AppColors.muted,
                              fontFamily: 'sans-serif',
                              fontSize: 9,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Layout compacto para telas baixas (celular na horizontal).
  Widget _buildCompactLayout({required int firstMidiNote}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: AppColors.accentWash,
                  borderRadius: BorderRadius.circular(11),
                ),
                child: const Icon(
                  Icons.graphic_eq_rounded,
                  color: AppColors.accent,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'MIDI PRO',
                      style: TextStyle(
                        color: AppColors.ivory,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.6,
                      ),
                    ),
                    _buildInstrumentChip(),
                  ],
                ),
              ),
              IconButton(
                tooltip: _midiDevice == null
                    ? 'Conectar teclado MIDI'
                    : 'Desconectar ${_midiDevice!.name}',
                onPressed: _connectingMidi ? null : _toggleMidiInput,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.surface,
                  foregroundColor: AppColors.ivory,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                    side: BorderSide(
                      color: _midiDevice == null
                          ? AppColors.line
                          : AppColors.accent,
                    ),
                  ),
                ),
                icon: _connectingMidi
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppColors.accent,
                        ),
                      )
                    : Icon(
                        Icons.piano_rounded,
                        color: _midiDevice == null
                            ? AppColors.secondary
                            : AppColors.accent,
                      ),
              ),
              const SizedBox(width: 6),
              IconButton(
                tooltip: 'Efeitos, metrônomo e presets',
                onPressed: _showStudioTools,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  backgroundColor: AppColors.surface,
                  foregroundColor: AppColors.ivory,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                    side: const BorderSide(color: AppColors.line),
                  ),
                ),
                icon: const Icon(Icons.tune_rounded, size: 19),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.volume_down_rounded,
                  color: AppColors.muted, size: 17),
              Expanded(
                child: Slider(
                  value: _volume,
                  min: 0,
                  max: 1,
                  onChanged: _setVolume,
                ),
              ),
              _compactStep(
                icon: Icons.remove_rounded,
                onPressed: _octave > 1 ? () => setState(() => _octave--) : null,
              ),
              Text(
                '$_octave',
                style: const TextStyle(
                  color: AppColors.ivory,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              _compactStep(
                icon: Icons.add_rounded,
                onPressed: _octave < 6 ? () => setState(() => _octave++) : null,
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: _sustain ? 'Soltar sustain' : 'Segurar sustain',
                onPressed: _toggleSustain,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  backgroundColor:
                      _sustain ? AppColors.accentWash : AppColors.surface,
                  foregroundColor:
                      _sustain ? AppColors.accent : AppColors.secondary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(11),
                    side: BorderSide(
                      color: _sustain ? AppColors.accent : AppColors.line,
                    ),
                  ),
                ),
                icon: const Icon(Icons.music_note_rounded, size: 18),
              ),
              const SizedBox(width: 8),
              _buildBpmPill(),
            ],
          ),
          const SizedBox(height: 6),
          _buildPitchModCompact(),
          const SizedBox(height: 6),
          Expanded(
            child: PianoKeyboard(
              key: ValueKey(_soundfontId),
              firstMidiNote: firstMidiNote,
              enabled: _soundfontId != null && !_loadingFont,
              onNoteOn: _noteOn,
              onNoteOff: _noteOff,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            _midiDevice != null
                ? 'MIDI · ${_midiDevice!.name}'
                : '${_soundfonts.length} TIMBRES · ${midiNoteName(firstMidiNote)} — ${midiNoteName(firstMidiNote + 23)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.muted, fontSize: 9),
          ),
        ],
      ),
    );
  }

  Widget _compactStep({
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      color: AppColors.secondary,
      disabledColor: AppColors.line,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 28, height: 30),
      padding: EdgeInsets.zero,
    );
  }

  Widget _buildBpmPill() {
    return Material(
      color: AppColors.accent,
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: _showStudioTools,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          alignment: Alignment.center,
          child: Text(
            '$_bpm',
            style: const TextStyle(
              color: Color(0xFF1A160C),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPitchModCompact() {
    final pitchFraction = (_pitchBendRaw / 16383).clamp(0.0, 1.0);
    final modFraction = (_modWheel / 127).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          Text('PITCH', style: _eyebrowStyle),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 10,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final trackWidth = constraints.maxWidth;
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _applyPitchBend(
                        ((d.localPosition.dx / trackWidth)
                                    .clamp(0.0, 1.0) *
                                16383)
                            .round()),
                    onHorizontalDragUpdate: (d) => _applyPitchBend(
                        ((d.localPosition.dx / trackWidth)
                                    .clamp(0.0, 1.0) *
                                16383)
                            .round()),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          height: 5,
                          decoration: BoxDecoration(
                            color: AppColors.raised,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        Container(
                            width: 1.5, height: 10, color: AppColors.muted),
                        Positioned(
                          left: (trackWidth - 10) * pitchFraction,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: AppColors.accent,
                              shape: BoxShape.circle,
                              border:
                                  Border.all(color: AppColors.ivory, width: 1),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text('MOD', style: _eyebrowStyle),
          const SizedBox(width: 6),
          SizedBox(
            height: 24,
            child: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _applyModWheel(
                      ((1 - (d.localPosition.dy / 24).clamp(0.0, 1.0)) * 127)
                          .round()),
                  onVerticalDragUpdate: (d) => _applyModWheel(
                      ((1 - (d.localPosition.dy / 24).clamp(0.0, 1.0)) * 127)
                          .round()),
                  child: SizedBox(
                    width: 10,
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: AppColors.raised,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        FractionallySizedBox(
                          heightFactor: modFraction,
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppColors.accent,
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '$_modWheel',
                  style: const TextStyle(
                    color: AppColors.secondary,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: AppColors.accentWash,
            borderRadius: BorderRadius.circular(13),
          ),
          child: const Icon(
            Icons.graphic_eq_rounded,
            color: AppColors.accent,
            size: 23,
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'MIDI PRO',
              style: TextStyle(
                color: AppColors.ivory,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.8,
              ),
            ),
            const SizedBox(height: 5),
            _buildInstrumentChip(),
          ],
        ),
        const Spacer(),
        IconButton(
          tooltip: _midiDevice == null
              ? 'Conectar teclado MIDI'
              : 'Desconectar ${_midiDevice!.name}',
          onPressed: _connectingMidi ? null : _toggleMidiInput,
          style: IconButton.styleFrom(
            backgroundColor: AppColors.surface,
            foregroundColor: AppColors.ivory,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(13),
              side: BorderSide(
                color: _midiDevice == null ? AppColors.line : AppColors.accent,
              ),
            ),
            fixedSize: const Size(44, 44),
          ),
          icon: _connectingMidi
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                )
              : Icon(
                  Icons.piano_rounded,
                  color: _midiDevice == null
                      ? AppColors.secondary
                      : AppColors.accent,
                ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Efeitos, metrônomo e presets',
          onPressed: _showStudioTools,
          style: IconButton.styleFrom(
            backgroundColor: AppColors.surface,
            foregroundColor: AppColors.ivory,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(13),
              side: const BorderSide(color: AppColors.line),
            ),
            fixedSize: const Size(44, 44),
          ),
          icon: const Icon(Icons.tune_rounded),
        ),
      ],
    );
  }

  Widget _buildInstrumentChip() {
    final label = _importing && _importTotal > 0
        ? 'Importando $_importProgress/$_importTotal'
        : _starting
            ? 'Preparando…'
            : _loadingFont
                ? 'Carregando…'
                : _engineError != null
                    ? 'Áudio indisponível'
                    : _selected?.displayName ?? 'Escolha um timbre';
    return Material(
      color: const Color(0xFF282828),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: _showSoundfontPicker,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 5, 8, 5),
          constraints: const BoxConstraints(maxWidth: 240),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.piano_rounded,
                  color: AppColors.accent, size: 14),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.ivory,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.expand_more_rounded,
                  color: AppColors.secondary, size: 14),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeTabs() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.sheetRaised,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          _modeTab('TECLADO', active: true, onTap: () {}),
          _modeTab('TIMBRES', active: false, onTap: _showSoundfontPicker),
          _modeTab('ESTÚDIO', active: false, onTap: _showStudioTools),
        ],
      ),
    );
  }

  Widget _modeTab(String label,
      {required bool active, required VoidCallback onTap}) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          alignment: Alignment.center,
          decoration: active
              ? BoxDecoration(
                  color: AppColors.accentWash,
                  borderRadius: BorderRadius.circular(8),
                )
              : null,
          child: Text(
            label,
            style: TextStyle(
              color: active ? AppColors.accent : AppColors.secondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPitchModIndicators() {
    final pitchFraction = (_pitchBendRaw / 16383).clamp(0.0, 1.0);
    final pitchSemitones = (_pitchBendRaw - 8192) / 8192 * _pitchBendRange;
    final modFraction = (_modWheel / 127).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.line),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('PITCH', style: _eyebrowStyle),
                    const Spacer(),
                    Text(
                      pitchSemitones >= 0
                          ? '+${pitchSemitones.toStringAsFixed(2)} st'
                          : '${pitchSemitones.toStringAsFixed(2)} st',
                      style: const TextStyle(
                        color: AppColors.secondary,
                        fontFamily: 'sans-serif',
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 14,
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final trackWidth = constraints.maxWidth;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapDown: (d) => _applyPitchBend(
                            ((d.localPosition.dx / trackWidth)
                                        .clamp(0.0, 1.0) *
                                    16383)
                                .round()),
                        onHorizontalDragUpdate: (d) => _applyPitchBend(
                            ((d.localPosition.dx / trackWidth)
                                        .clamp(0.0, 1.0) *
                                    16383)
                                .round()),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: AppColors.raised,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                            Container(
                              width: 2,
                              height: 14,
                              color: AppColors.muted,
                            ),
                            Positioned(
                              left: (trackWidth - 14) * pitchFraction,
                              child: Container(
                                width: 14,
                                height: 14,
                                decoration: BoxDecoration(
                                  color: AppColors.accent,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: AppColors.ivory,
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 20),
          SizedBox(
            height: 46,
            child: Row(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) => _applyModWheel(
                      ((1 - (d.localPosition.dy / 46).clamp(0.0, 1.0)) * 127)
                          .round()),
                  onVerticalDragUpdate: (d) => _applyModWheel(
                      ((1 - (d.localPosition.dy / 46).clamp(0.0, 1.0)) * 127)
                          .round()),
                  child: SizedBox(
                    width: 14,
                    child: Stack(
                      alignment: Alignment.bottomCenter,
                      children: [
                        Container(
                          decoration: BoxDecoration(
                            color: AppColors.raised,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        FractionallySizedBox(
                          heightFactor: modFraction,
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppColors.accent,
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('MOD', style: _eyebrowStyle),
                    Text(
                      '$_modWheel',
                      style: const TextStyle(
                        color: AppColors.secondary,
                        fontFamily: 'sans-serif',
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVolumeControl() {
    return Row(
      children: [
        const Icon(Icons.volume_down_rounded, color: AppColors.muted, size: 19),
        Expanded(
          child: Slider(
            value: _volume,
            min: 0,
            max: 1,
            onChanged: _setVolume,
            semanticFormatterCallback: (value) => '${(value * 100).round()}%',
          ),
        ),
        SizedBox(
          width: 38,
          child: Text(
            '${(_volume * 100).round()}%',
            textAlign: TextAlign.right,
            style: const TextStyle(
              color: AppColors.secondary,
              fontFamily: 'monospace',
              fontSize: 10,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPerformanceControls() {
    return Row(
      children: [
        Container(
          height: 43,
          padding: const EdgeInsets.symmetric(horizontal: 5),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: AppColors.line),
          ),
          child: Row(
            children: [
              _smallControl(
                icon: Icons.remove_rounded,
                label: 'Diminuir oitava',
                onPressed: _octave > 1
                    ? () => setState(() => _octave--)
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 7),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text(
                      'OITAVA',
                      style: TextStyle(
                        color: AppColors.muted,
                        fontFamily: 'sans-serif',
                        fontSize: 8,
                        letterSpacing: 0.5,
                      ),
                    ),
                    Text(
                      '$_octave',
                      style: const TextStyle(
                        color: AppColors.ivory,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
              _smallControl(
                icon: Icons.add_rounded,
                label: 'Aumentar oitava',
                onPressed: _octave < 6
                    ? () => setState(() => _octave++)
                    : null,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Camadas de timbre (${_layers.length}/2)',
          onPressed: _showLayerManager,
          style: IconButton.styleFrom(
            backgroundColor: AppColors.surface,
            foregroundColor: AppColors.ivory,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(13),
              side: const BorderSide(color: AppColors.line),
            ),
            fixedSize: const Size(44, 43),
          ),
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              const Icon(Icons.layers_rounded, size: 18),
              Positioned(
                right: -8,
                top: -7,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: const BoxDecoration(
                    color: AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${_layers.length}',
                    style: const TextStyle(fontSize: 8, height: 1),
                  ),
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        Material(
          color: _sustain ? AppColors.accentWash : AppColors.surface,
          borderRadius: BorderRadius.circular(13),
          child: InkWell(
            onTap: _toggleSustain,
            borderRadius: BorderRadius.circular(13),
            child: Container(
              height: 43,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(13),
                border: Border.all(
                  color: _sustain ? AppColors.accent : AppColors.line,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.music_note_rounded,
                    color: _sustain ? AppColors.accent : AppColors.secondary,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Sustain',
                    style: TextStyle(
                      color: _sustain ? AppColors.ivory : AppColors.secondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 7),
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      color: _sustain ? AppColors.accent : AppColors.muted,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Material(
          color: AppColors.accent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: _showStudioTools,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              height: 43,
              padding: const EdgeInsets.symmetric(horizontal: 13),
              alignment: Alignment.center,
              child: Text(
                '$_bpm',
                style: const TextStyle(
                  color: Color(0xFF1A160C),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _smallControl({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: label,
      icon: Icon(icon, size: 17),
      color: AppColors.secondary,
      disabledColor: AppColors.line,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 34),
    );
  }
}

class StudioToolsSheet extends StatefulWidget {
  const StudioToolsSheet({
    required this.layers,
    required this.presets,
    required this.selectedLayerId,
    required this.bpm,
    required this.metronomeRunning,
    required this.pitchBendRange,
    required this.supportsAudioEffects,
    required this.onSelectLayer,
    required this.onLayerEffect,
    required this.onBpm,
    required this.onToggleMetronome,
    required this.onPitchBendRange,
    required this.onSavePreset,
    required this.onLoadPreset,
    required this.onDeletePreset,
    required this.onAddLayer,
    required this.onRemoveLayer,
    super.key,
  });

  final List<LoadedSoundfont> layers;
  final List<PerformancePreset> presets;
  final int? selectedLayerId;
  final int bpm;
  final bool metronomeRunning;
  final double pitchBendRange;
  final bool supportsAudioEffects;
  final ValueChanged<int> onSelectLayer;
  final ValueChanged<int> onLayerEffect;
  final ValueChanged<int> onBpm;
  final VoidCallback onToggleMetronome;
  final ValueChanged<double> onPitchBendRange;
  final VoidCallback onSavePreset;
  final ValueChanged<PerformancePreset> onLoadPreset;
  final ValueChanged<PerformancePreset> onDeletePreset;
  final VoidCallback onAddLayer;
  final ValueChanged<int> onRemoveLayer;

  @override
  State<StudioToolsSheet> createState() => _StudioToolsSheetState();
}

class _StudioToolsSheetState extends State<StudioToolsSheet> {
  late double _bpm = widget.bpm.toDouble();
  late bool _metronomeRunning = widget.metronomeRunning;
  late double _pitchBendRange = widget.pitchBendRange;
  late int? _selectedId = widget.selectedLayerId;

  LoadedSoundfont? get _selectedLayer {
    for (final layer in widget.layers) {
      if (layer.id == _selectedId) return layer;
    }
    return widget.layers.isEmpty ? null : widget.layers.first;
  }

  @override
  void didUpdateWidget(covariant StudioToolsSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    _bpm = widget.bpm.toDouble();
    _metronomeRunning = widget.metronomeRunning;
    _pitchBendRange = widget.pitchBendRange;
    if (widget.selectedLayerId != null) {
      _selectedId = widget.selectedLayerId;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.line,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Estúdio',
              style: TextStyle(
                color: AppColors.ivory,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 3),
            const Text(
              'Camadas, efeitos e prática',
              style: TextStyle(color: AppColors.muted, fontSize: 11),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 18),
                children: [
                  _sectionTitle('CAMADAS',
                      trailing: '${widget.layers.length}/$maxLayers'),
                  if (widget.layers.isEmpty)
                    _emptyHint('Adicione um timbre para começar a tocar.')
                  else
                    for (final layer in widget.layers)
                      Material(
                        color: _selectedId == layer.id
                            ? AppColors.accentWash
                            : AppColors.surface,
                        borderRadius: BorderRadius.circular(14),
                        child: InkWell(
                          onTap: () {
                            setState(() => _selectedId = layer.id);
                            widget.onSelectLayer(layer.id);
                          },
                          borderRadius: BorderRadius.circular(14),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: _selectedId == layer.id
                                    ? AppColors.accent.withValues(alpha: 0.6)
                                    : AppColors.line,
                              ),
                            ),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 15,
                                  backgroundColor: AppColors.raised,
                                  child: Text(
                                    '${widget.layers.indexOf(layer) + 1}',
                                    style: const TextStyle(
                                        color: AppColors.accent, fontSize: 12),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        layer.font.displayName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.ivory,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        layer.font.category,
                                        style: const TextStyle(
                                          color: AppColors.muted,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (_selectedId == layer.id)
                                  const Icon(Icons.check_circle_rounded,
                                      color: AppColors.accent, size: 18),
                                IconButton(
                                  tooltip: 'Remover camada',
                                  onPressed: () =>
                                      widget.onRemoveLayer(layer.id),
                                  icon: const Icon(Icons.close_rounded,
                                      color: AppColors.muted, size: 18),
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  if (widget.layers.length < maxLayers)
                    OutlinedButton.icon(
                      onPressed: widget.onAddLayer,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('Adicionar timbre em camada'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.ivory,
                        side: const BorderSide(color: AppColors.line),
                      ),
                    ),
                  const SizedBox(height: 22),
                  if (_selectedLayer == null)
                    _emptyHint('Adicione um timbre para editar os efeitos.')
                  else ...[
                    _sectionTitle('EFEITOS DA CAMADA',
                        trailing:
                            _selectedLayer!.font.displayName.toUpperCase()),
                    if (!widget.supportsAudioEffects)
                      _emptyHint(
                          'Reverb, delay e EQ avançado estão disponíveis na versão Web.'),
                    _slider(
                      'Reverb',
                      _selectedLayer!.effects.reverb,
                      0,
                      1,
                      '${(_selectedLayer!.effects.reverb * 100).round()}%',
                      widget.supportsAudioEffects
                          ? (value) {
                              setState(
                                  () => _selectedLayer!.effects.reverb = value);
                              widget.onLayerEffect(_selectedLayer!.id);
                            }
                          : null,
                    ),
                    _slider(
                      'Delay',
                      _selectedLayer!.effects.delay,
                      0,
                      1,
                      '${(_selectedLayer!.effects.delay * 100).round()}%',
                      widget.supportsAudioEffects
                          ? (value) {
                              setState(
                                  () => _selectedLayer!.effects.delay = value);
                              widget.onLayerEffect(_selectedLayer!.id);
                            }
                          : null,
                    ),
                    if (_selectedLayer!.effects.delay > 0) ...[
                      _slider(
                        'Tempo do eco',
                        _selectedLayer!.effects.delayTime,
                        0.08,
                        0.8,
                        '${(_selectedLayer!.effects.delayTime * 1000).round()} ms',
                        widget.supportsAudioEffects
                            ? (value) {
                                setState(() =>
                                    _selectedLayer!.effects.delayTime = value);
                                widget.onLayerEffect(_selectedLayer!.id);
                              }
                            : null,
                      ),
                      _slider(
                        'Repetição',
                        _selectedLayer!.effects.feedback,
                        0,
                        0.78,
                        '${(_selectedLayer!.effects.feedback * 100).round()}%',
                        widget.supportsAudioEffects
                            ? (value) {
                                setState(() =>
                                    _selectedLayer!.effects.feedback = value);
                                widget.onLayerEffect(_selectedLayer!.id);
                              }
                            : null,
                      ),
                    ],
                    const SizedBox(height: 10),
                    _sectionTitle('EQUALIZADOR'),
                    _slider(
                      'Graves',
                      _selectedLayer!.effects.bass,
                      -12,
                      12,
                      '${_selectedLayer!.effects.bass.toStringAsFixed(0)} dB',
                      widget.supportsAudioEffects
                          ? (value) {
                              setState(
                                  () => _selectedLayer!.effects.bass = value);
                              widget.onLayerEffect(_selectedLayer!.id);
                            }
                          : null,
                      divisions: 24,
                    ),
                    _slider(
                      'Médios',
                      _selectedLayer!.effects.mid,
                      -12,
                      12,
                      '${_selectedLayer!.effects.mid.toStringAsFixed(0)} dB',
                      widget.supportsAudioEffects
                          ? (value) {
                              setState(
                                  () => _selectedLayer!.effects.mid = value);
                              widget.onLayerEffect(_selectedLayer!.id);
                            }
                          : null,
                      divisions: 24,
                    ),
                    _slider(
                      'Agudos',
                      _selectedLayer!.effects.treble,
                      -12,
                      12,
                      '${_selectedLayer!.effects.treble.toStringAsFixed(0)} dB',
                      widget.supportsAudioEffects
                          ? (value) {
                              setState(() =>
                                  _selectedLayer!.effects.treble = value);
                              widget.onLayerEffect(_selectedLayer!.id);
                            }
                          : null,
                      divisions: 24,
                    ),
                    const SizedBox(height: 12),
                    _sectionTitle('SUSTAIN (PEDAL)'),
                    _slider(
                      'Segurar após soltar',
                      _selectedLayer!.effects.sustainSeconds,
                      0,
                      5,
                      _selectedLayer!.effects.sustainSeconds <= 0
                          ? 'desligado'
                          : '${_selectedLayer!.effects.sustainSeconds.toStringAsFixed(1)} s',
                      (value) {
                        setState(() =>
                            _selectedLayer!.effects.sustainSeconds = value);
                        widget.onLayerEffect(_selectedLayer!.id);
                      },
                      divisions: 50,
                    ),
                  ],
                  const SizedBox(height: 12),
                  _sectionTitle('PITCH BEND'),
                  _slider(
                    'Alcance (semitons)',
                    _pitchBendRange,
                    1,
                    24,
                    '±${_pitchBendRange.toStringAsFixed(0)}',
                    (value) {
                      setState(() => _pitchBendRange = value);
                      widget.onPitchBendRange(value);
                    },
                    divisions: 23,
                  ),
                  const SizedBox(height: 12),
                  _sectionTitle('METRÔNOMO'),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Diminuir BPM',
                        onPressed: _bpm > 40
                            ? () {
                                final value = (_bpm - 1).round();
                                setState(() => _bpm = value.toDouble());
                                widget.onBpm(value);
                              }
                            : null,
                        icon: const Icon(Icons.remove_rounded),
                      ),
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              '${_bpm.round()} BPM',
                              style: const TextStyle(
                                color: AppColors.ivory,
                                fontFamily: 'sans-serif',
                                fontSize: 12,
                              ),
                            ),
                            Slider(
                              value: _bpm,
                              min: 40,
                              max: 240,
                              divisions: 200,
                              onChanged: (value) {
                                final bpm = value.round();
                                setState(() => _bpm = bpm.toDouble());
                                widget.onBpm(bpm);
                              },
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'Aumentar BPM',
                        onPressed: _bpm < 240
                            ? () {
                                final value = (_bpm + 1).round();
                                setState(() => _bpm = value.toDouble());
                                widget.onBpm(value);
                              }
                            : null,
                        icon: const Icon(Icons.add_rounded),
                      ),
                      const SizedBox(width: 4),
                      IconButton.filled(
                        tooltip: _metronomeRunning
                            ? 'Parar metrônomo'
                            : 'Iniciar metrônomo',
                        onPressed: () {
                          setState(() =>
                              _metronomeRunning = !_metronomeRunning);
                          widget.onToggleMetronome();
                        },
                        icon: Icon(
                          _metronomeRunning
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor: _metronomeRunning
                              ? AppColors.accent
                              : AppColors.raised,
                          foregroundColor: AppColors.ivory,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(child: _sectionTitle('PRESETS SALVOS')),
                      TextButton.icon(
                        onPressed: widget.onSavePreset,
                        icon: const Icon(Icons.bookmark_add_outlined, size: 17),
                        label: const Text('Salvar atual'),
                        style: TextButton.styleFrom(
                          foregroundColor: AppColors.accent,
                          textStyle: const TextStyle(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                  if (widget.presets.isEmpty)
                    _emptyHint('Salve um conjunto de timbres e efeitos para reutilizar.')
                  else
                    for (final preset in widget.presets)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(
                          Icons.bookmark_outline_rounded,
                          color: AppColors.accent,
                        ),
                        title: Text(preset.name),
                        subtitle: Text(
                          '${preset.soundfontIds.length} timbre${preset.soundfontIds.length == 1 ? '' : 's'} · ${preset.bpm} BPM',
                        ),
                        onTap: () => widget.onLoadPreset(preset),
                        trailing: IconButton(
                          tooltip: 'Excluir preset',
                          onPressed: () => widget.onDeletePreset(preset),
                          icon: const Icon(
                            Icons.delete_outline_rounded,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, {String? trailing}) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Text(title, style: _eyebrowStyle),
            if (trailing != null) ...[
              const Spacer(),
              Text(
                trailing,
                style: const TextStyle(
                  color: AppColors.muted,
                  fontFamily: 'sans-serif',
                  fontSize: 10,
                ),
              ),
            ],
          ],
        ),
      );

  Widget _emptyHint(String message) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          message,
          style: const TextStyle(color: AppColors.muted, fontSize: 12),
        ),
      );

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    String readout,
    ValueChanged<double>? onChanged, {
    int? divisions,
  }) =>
      Column(
        children: [
          Row(
            children: [
              Text(label, style: const TextStyle(color: AppColors.secondary, fontSize: 12)),
              const Spacer(),
              Text(readout, style: const TextStyle(color: AppColors.muted, fontFamily: 'monospace', fontSize: 10)),
            ],
          ),
          Slider(
            value: value.clamp(min, max).toDouble(),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      );
}

class SoundfontPicker extends StatefulWidget {
  const SoundfontPicker({
    required this.fonts,
    required this.selectedPath,
    required this.onImportFolder,
    required this.onDelete,
    super.key,
  });

  final List<SoundFont> fonts;
  final String? selectedPath;
  final VoidCallback onImportFolder;
  final ValueChanged<SoundFont> onDelete;

  @override
  State<SoundfontPicker> createState() => _SoundfontPickerState();
}

class _SoundfontPickerState extends State<SoundfontPicker> {
  final TextEditingController _search = TextEditingController();
  String _category = 'Todos';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final fonts = widget.fonts.where((font) {
      final matchesQuery = font.displayName.toLowerCase().contains(query);
      final matchesCategory =
          _category == 'Todos' || font.category == _category;
      return matchesQuery && matchesCategory;
    }).toList();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.line,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Timbres',
                        style: TextStyle(
                          color: AppColors.ivory,
                          fontFamily: 'sans-serif',
                          fontSize: 25,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${widget.fonts.length} SoundFont${widget.fonts.length == 1 ? '' : 's'} na biblioteca',
                        style: const TextStyle(
                          color: AppColors.muted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                if (kIsWeb)
                  TextButton.icon(
                    onPressed: widget.onImportFolder,
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 18,
                    ),
                    label: const Text('Importar pasta'),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      textStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: AppColors.ivory, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Buscar timbre',
                hintStyle: const TextStyle(color: AppColors.muted),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: AppColors.muted,
                  size: 20,
                ),
                filled: true,
                fillColor: AppColors.surface,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(13),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final category in const [
                    'Todos',
                    'Grand',
                    'Upright',
                    'E-Piano',
                    'Outros',
                  ]) ...[
                    ChoiceChip(
                      label: Text(category),
                      selected: _category == category,
                      onSelected: (_) => setState(() => _category = category),
                      selectedColor: AppColors.accentWash,
                      backgroundColor: AppColors.surface,
                      side: BorderSide(
                        color: _category == category
                            ? AppColors.accent
                            : AppColors.line,
                      ),
                      labelStyle: TextStyle(
                        color: _category == category
                            ? AppColors.ivory
                            : AppColors.secondary,
                        fontSize: 11,
                      ),
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 7),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: fonts.isEmpty
                  ? _emptyLibrary(query.isNotEmpty)
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 12),
                      itemCount: fonts.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 7),
                      itemBuilder: (context, index) {
                        final font = fonts[index];
                        final selected = font.id == widget.selectedPath;
                        return Material(
                          color: selected
                              ? AppColors.accentWash
                              : AppColors.surface,
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            onTap: () => Navigator.of(context).pop(font),
                            borderRadius: BorderRadius.circular(14),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 13,
                                vertical: 12,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: selected
                                      ? AppColors.accent.withValues(alpha: 0.7)
                                      : AppColors.line,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 36,
                                    height: 36,
                                    decoration: BoxDecoration(
                                      color: selected
                                          ? AppColors.accentWash
                                          : AppColors.raised,
                                      borderRadius: BorderRadius.circular(11),
                                    ),
                                    child: Icon(
                                      Icons.piano_rounded,
                                      color: selected
                                          ? AppColors.accent
                                          : AppColors.secondary,
                                      size: 19,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          font.displayName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: AppColors.ivory,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        Text(
                                          '${font.category} · SF2',
                                          style: const TextStyle(
                                            color: AppColors.muted,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (selected)
                                    const Icon(
                                      Icons.check_circle_rounded,
                                      color: AppColors.accent,
                                      size: 19,
                                    )
                                  else
                                    const Icon(
                                      Icons.chevron_right_rounded,
                                      color: AppColors.muted,
                                      size: 20,
                                    ),
                                  if (!font.builtin)
                                    IconButton(
                                      tooltip: 'Remover da biblioteca',
                                      onPressed: () => widget.onDelete(font),
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        color: AppColors.muted,
                                        size: 18,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyLibrary(bool noMatches) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              noMatches ? Icons.search_off_rounded : Icons.piano_rounded,
              color: AppColors.muted,
              size: 33,
            ),
            const SizedBox(height: 12),
            Text(
              noMatches ? 'Nenhum timbre encontrado' : 'Sua biblioteca está vazia',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.ivory,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              noMatches
                  ? 'Tente outro nome ou categoria.'
                  : 'Importe arquivos SoundFont .sf2 para tocar.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.muted, fontSize: 12),
            ),
            if (!noMatches) ...[
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: widget.onImportFolder,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('Importar timbres'),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.ivory,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Mapeia uma posição de toque no teclado para a nota MIDI correspondente,
/// ou null fora da área.
int? noteAtPosition(Offset position, Size size, int firstMidiNote) {
  if (size.width <= 0 ||
      size.height <= 0 ||
      position.dx < 0 ||
      position.dx >= size.width ||
      position.dy < 0 ||
      position.dy >= size.height) {
    return null;
  }
  const whiteCount = 14;
  const whiteSemitones = [0, 2, 4, 5, 7, 9, 11];
  const blackAfterWhite = {0, 1, 3, 4, 5};
  final whiteWidth = size.width / whiteCount;
  final whiteIndex =
      (position.dx / whiteWidth).floor().clamp(0, whiteCount - 1);
  if (position.dy < size.height * 0.62) {
    final blackWidth = whiteWidth * 0.6;
    for (var index = 0; index < whiteCount; index++) {
      final degree = index % 7;
      if (!blackAfterWhite.contains(degree)) continue;
      final left = (index + 1) * whiteWidth - blackWidth / 2;
      if (position.dx >= left && position.dx < left + blackWidth) {
        return firstMidiNote +
            (index ~/ 7) * 12 +
            whiteSemitones[degree] +
            1;
      }
    }
  }
  return firstMidiNote +
      (whiteIndex ~/ 7) * 12 +
      whiteSemitones[whiteIndex % 7];
}

class PianoKeyboard extends StatefulWidget {
  const PianoKeyboard({
    required this.firstMidiNote,
    required this.enabled,
    required this.onNoteOn,
    required this.onNoteOff,
    super.key,
  });
  final int firstMidiNote;
  final bool enabled;
  final void Function(int note, int velocity) onNoteOn;
  final ValueChanged<int> onNoteOff;

  @override
  State<PianoKeyboard> createState() => _PianoKeyboardState();
}

class _PianoKeyboardState extends State<PianoKeyboard> {
  final Map<int, int> _pointerNotes = {};
  final Set<int> _activeNotes = {};

  int _velocityFor(PointerEvent event, Size size) {
    // Tocar mais embaixo na tecla = mais forte (32..127).
    final fraction = (event.localPosition.dy / size.height).clamp(0.0, 1.0);
    return (32 + fraction * 95).round();
  }

  void _movePointer(PointerEvent event, Size size) {
    final note = widget.enabled
        ? noteAtPosition(event.localPosition, size, widget.firstMidiNote)
        : null;
    final previous = _pointerNotes[event.pointer];
    if (previous == note) return;

    if (previous != null) {
      _pointerNotes.remove(event.pointer);
      if (!_pointerNotes.containsValue(previous)) {
        _activeNotes.remove(previous);
        widget.onNoteOff(previous);
      }
    }
    if (note != null) {
      _pointerNotes[event.pointer] = note;
      if (_activeNotes.add(note)) {
        widget.onNoteOn(note, _velocityFor(event, size));
      }
    }
    setState(() {});
  }

  void _releasePointer(int pointer) {
    final note = _pointerNotes.remove(pointer);
    if (note == null) return;
    if (!_pointerNotes.containsValue(note)) {
      _activeNotes.remove(note);
      widget.onNoteOff(note);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Semantics(
          label: 'Teclado de piano, ${midiNoteName(widget.firstMidiNote)} a ${midiNoteName(widget.firstMidiNote + 23)}',
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) => _movePointer(event, size),
            onPointerMove: (event) => _movePointer(event, size),
            onPointerUp: (event) => _releasePointer(event.pointer),
            onPointerCancel: (event) => _releasePointer(event.pointer),
            child: RepaintBoundary(
              child: CustomPaint(
                size: size,
                painter: PianoKeyboardPainter(
                  firstMidiNote: widget.firstMidiNote,
                  activeNotes: Set<int>.of(_activeNotes),
                  enabled: widget.enabled,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class PianoKeyboardPainter extends CustomPainter {
  PianoKeyboardPainter({
    required this.firstMidiNote,
    required this.activeNotes,
    required this.enabled,
  });

  final int firstMidiNote;
  final Set<int> activeNotes;
  final bool enabled;

  static const List<int> _whiteSemitones = [0, 2, 4, 5, 7, 9, 11];
  static const List<String> _whiteNames = ['C', 'D', 'E', 'F', 'G', 'A', 'B'];
  static const Set<int> _blackAfterWhite = {0, 1, 3, 4, 5};

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    const whiteCount = 14;
    final whiteWidth = size.width / whiteCount;
    final radius = const Radius.circular(4);
    final border = Paint()
      ..color = AppColors.line
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    for (var index = 0; index < whiteCount; index++) {
      final note = firstMidiNote +
          (index ~/ 7) * 12 +
          _whiteSemitones[index % 7];
      final rect = Rect.fromLTWH(
        index * whiteWidth,
        0,
        whiteWidth,
        size.height,
      );
      final fill = Paint();
      if (!enabled) {
        fill.color = const Color(0xFFC7C4BC);
      } else {
        fill.shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: activeNotes.contains(note)
              ? const [Color(0xFFF3E3B5), Color(0xFFE9D5A0)]
              : const [Color(0xFFF0EFEC), Color(0xFFFFFFFF)],
        ).createShader(rect);
      }
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: radius,
          topRight: radius,
          bottomLeft: radius,
          bottomRight: radius,
        ),
        fill,
      );
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: radius,
          topRight: radius,
          bottomLeft: radius,
          bottomRight: radius,
        ),
        border,
      );

      final octave = firstMidiNote ~/ 12 - 1 + index ~/ 7;
      final label = index % 7 == 0 ? 'C$octave' : _whiteNames[index % 7];
      final text = TextPainter(
        text: TextSpan(
          text: label,
          style: TextStyle(
            color: activeNotes.contains(note)
                ? const Color(0xFF8A6D1F)
                : const Color(0xFF77756F),
            fontSize: index % 7 == 0 ? 8.5 : 9,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: whiteWidth);
      text.paint(
        canvas,
        Offset(
          index * whiteWidth + (whiteWidth - text.width) / 2,
          size.height - text.height - 8,
        ),
      );
    }

    final blackWidth = whiteWidth * 0.6;
    final blackHeight = size.height * 0.62;
    for (var index = 0; index < whiteCount; index++) {
      final degree = index % 7;
      if (!_blackAfterWhite.contains(degree)) continue;

      final note = firstMidiNote +
          (index ~/ 7) * 12 +
          _whiteSemitones[degree] +
          1;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          (index + 1) * whiteWidth - blackWidth / 2,
          0,
          blackWidth,
          blackHeight,
        ),
        const Radius.circular(3),
      );
      final fill = Paint()
        ..color = !enabled
            ? const Color(0xFF4C4B4A)
            : activeNotes.contains(note)
                ? AppColors.accent
                : AppColors.blackKey;
      canvas.drawRRect(rect, fill);
      canvas.drawRRect(
        rect,
        Paint()..color = Colors.black.withValues(alpha: 0.38),
      );
      canvas.drawRRect(
        rect,
        Paint()
          ..color = const Color(0xFF55565C)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.6,
      );
    }
  }

  @override
  bool shouldRepaint(covariant PianoKeyboardPainter oldDelegate) =>
      oldDelegate.firstMidiNote != firstMidiNote ||
      oldDelegate.enabled != enabled ||
      !setEquals(oldDelegate.activeNotes, activeNotes);
}

String midiNoteName(int note) {
  const names = [
    'C',
    'C#',
    'D',
    'D#',
    'E',
    'F',
    'F#',
    'G',
    'G#',
    'A',
    'A#',
    'B',
  ];
  return '${names[note % 12]}${note ~/ 12 - 1}';
}

const _eyebrowStyle = TextStyle(
  color: AppColors.muted,
  fontFamily: 'monospace',
  fontSize: 9,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.8,
);
