import 'package:flutter_test/flutter_test.dart';
import 'package:midipro/performance_preset.dart';

void main() {
  test('LayerEffects round-trip preserva todos os campos', () {
    final effects = LayerEffects(
      reverb: 0.4,
      delay: 0.5,
      delayTime: 0.6,
      feedback: 0.7,
      bass: -3,
      mid: 2,
      treble: 5,
      sustainSeconds: 1.5,
    );
    final restored = LayerEffects.fromJson(effects.toJson());
    expect(restored.reverb, 0.4);
    expect(restored.delay, 0.5);
    expect(restored.delayTime, 0.6);
    expect(restored.feedback, 0.7);
    expect(restored.bass, -3);
    expect(restored.mid, 2);
    expect(restored.treble, 5);
    expect(restored.sustainSeconds, 1.5);
  });

  test('LayerEffects usa padrões para campos ausentes', () {
    final effects = LayerEffects.fromJson(const {});
    expect(effects.reverb, 0.28);
    expect(effects.delay, 0);
    expect(effects.delayTime, 0.32);
    expect(effects.feedback, 0.3);
    expect(effects.bass, 0);
    expect(effects.sustainSeconds, 0);
  });

  test('PerformancePreset round-trip com efeitos por camada e range', () {
    final preset = PerformancePreset(
      name: 'Meu som',
      soundfontIds: const ['a', 'b'],
      volume: 0.5,
      bpm: 120,
      pitchBendRange: 12,
      layerEffects: [
        LayerEffects(reverb: 0.3),
        LayerEffects(delay: 0.4),
      ],
    );
    final restored = PerformancePreset.fromJson(preset.toJson());
    expect(restored.name, 'Meu som');
    expect(restored.soundfontIds, ['a', 'b']);
    expect(restored.volume, 0.5);
    expect(restored.bpm, 120);
    expect(restored.pitchBendRange, 12);
    expect(restored.layerEffects, isNotNull);
    expect(restored.layerEffects!.length, 2);
    expect(restored.layerEffects![0].reverb, 0.3);
    expect(restored.layerEffects![1].delay, 0.4);
  });

  test('preset antigo sem layerEffects mantém padrões', () {
    final preset = PerformancePreset.fromJson({
      'name': 'antigo',
      'soundfontIds': ['x'],
      'volume': 0.7,
      'bpm': 90,
    });
    expect(preset.layerEffects, isNull);
    expect(preset.pitchBendRange, 2);
    expect(preset.reverb, 0.28);
    expect(preset.sustainSeconds, 0);
  });
}
