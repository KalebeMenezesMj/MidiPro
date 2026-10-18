/// Efeitos de uma camada de timbre.
class LayerEffects {
  LayerEffects({
    this.reverb = 0.28,
    this.delay = 0,
    this.delayTime = 0.32,
    this.feedback = 0.3,
    this.bass = 0,
    this.mid = 0,
    this.treble = 0,
    this.sustainSeconds = 0,
  });

  double reverb;
  double delay;
  double delayTime;
  double feedback;
  double bass;
  double mid;
  double treble;
  double sustainSeconds;

  LayerEffects copy() => LayerEffects(
        reverb: reverb,
        delay: delay,
        delayTime: delayTime,
        feedback: feedback,
        bass: bass,
        mid: mid,
        treble: treble,
        sustainSeconds: sustainSeconds,
      );

  Map<String, double> toJson() => {
        'reverb': reverb,
        'delay': delay,
        'delayTime': delayTime,
        'feedback': feedback,
        'bass': bass,
        'mid': mid,
        'treble': treble,
        'sustainSeconds': sustainSeconds,
      };

  factory LayerEffects.fromJson(Map<String, dynamic> json) => LayerEffects(
        reverb: (json['reverb'] as num?)?.toDouble() ?? 0.28,
        delay: (json['delay'] as num?)?.toDouble() ?? 0,
        delayTime: (json['delayTime'] as num?)?.toDouble() ?? 0.32,
        feedback: (json['feedback'] as num?)?.toDouble() ?? 0.3,
        bass: (json['bass'] as num?)?.toDouble() ?? 0,
        mid: (json['mid'] as num?)?.toDouble() ?? 0,
        treble: (json['treble'] as num?)?.toDouble() ?? 0,
        sustainSeconds: (json['sustainSeconds'] as num?)?.toDouble() ?? 0,
      );
}

class PerformancePreset {
  const PerformancePreset({
    required this.name,
    required this.soundfontIds,
    required this.volume,
    this.reverb = 0.28,
    this.delay = 0,
    this.delayTime = 0.32,
    this.feedback = 0.3,
    this.bass = 0,
    this.mid = 0,
    this.treble = 0,
    this.bpm = 100,
    this.sustainSeconds = 0,
    this.layerEffects,
  });

  final String name;
  final List<String> soundfontIds;
  final double volume;

  /// Campos globais mantidos para compatibilidade com presets antigos;
  /// são usados como efeitos padrão quando [layerEffects] está ausente.
  final double reverb;
  final double delay;
  final double delayTime;
  final double feedback;
  final double bass;
  final double mid;
  final double treble;
  final int bpm;
  final double sustainSeconds;

  /// Efeitos por camada, na mesma ordem de [soundfontIds].
  final List<LayerEffects>? layerEffects;

  Map<String, Object> toJson() => {
        'name': name,
        'soundfontIds': soundfontIds,
        'volume': volume,
        'reverb': reverb,
        'delay': delay,
        'delayTime': delayTime,
        'feedback': feedback,
        'bass': bass,
        'mid': mid,
        'treble': treble,
        'bpm': bpm,
        'sustainSeconds': sustainSeconds,
        if (layerEffects != null)
          'layerEffects': [
            for (final effects in layerEffects!) effects.toJson(),
          ],
      };

  factory PerformancePreset.fromJson(Map<String, dynamic> json) =>
      PerformancePreset(
        name: json['name'] as String,
        soundfontIds: (json['soundfontIds'] as List).cast<String>(),
        volume: (json['volume'] as num).toDouble(),
        reverb: (json['reverb'] as num?)?.toDouble() ?? 0.28,
        delay: (json['delay'] as num?)?.toDouble() ?? 0,
        delayTime: (json['delayTime'] as num?)?.toDouble() ?? 0.32,
        feedback: (json['feedback'] as num?)?.toDouble() ?? 0.3,
        bass: (json['bass'] as num?)?.toDouble() ?? 0,
        mid: (json['mid'] as num?)?.toDouble() ?? 0,
        treble: (json['treble'] as num?)?.toDouble() ?? 0,
        bpm: (json['bpm'] as num?)?.toInt() ?? 100,
        sustainSeconds: (json['sustainSeconds'] as num?)?.toDouble() ?? 0,
        layerEffects: (json['layerEffects'] as List?)
            ?.whereType<Map>()
            .map((item) => LayerEffects.fromJson(
                  Map<String, dynamic>.from(item),
                ))
            .toList(),
      );
}
