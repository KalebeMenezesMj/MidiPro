// Timbres nativos do pacote midipro_soundfonts. Gerado a partir de
// D:\midipro-tools\midipro-soundfonts\soundfonts.
import 'soundfont.dart';

const builtinSoundfontAssetDir = 'packages/midipro_soundfonts/soundfonts';

const builtinSoundfontFilenames = <String>[
  '01_royal grand 3d_nord.sf2',
  '02_velvet grand_nord.sf2',
  '03_silver grand_nord.sf2',
  '04_italian grand_nord.sf2',
  '05_bright grand_nord.sf2',
  '06_grand imperial_nord.sf2',
  '07_grand lady d_nord.sf2',
  '08_studio grand1_nord.sf2',
  '09_studio grand2_nord.sf2',
  '10_concert grand close_nord.sf2',
  '11_concert grand ambient_nord.sf2',
  '12_eletric grand amped_nord.sf2',
  '13_eletric grand cp80_nord.sf2',
  '14_eletric grand gerbstedt_nord.sf2',
  '15_baby upright_nord.sf2',
  '16_amber upright_nord.sf2',
  '17_bambino upright_nord.sf2',
  '18_mellow upright_nord.sf2',
  '19_grand upright_nord.sf2',
  '20_queen upright_nord.sf2',
  '21_black upright_nord.sf2',
  '22_honkytonk upright_nord.sf2',
  '23_saloon upright_nord.sf2',
  '24_romantic upright_nord.sf2',
  '25_blueswede upright_nord.sf2',
  '26_rain piano_nord.sf2',
  '27_epiano 1 mk I low deep_nord.sf2',
  '28_epiano 2 mk I closldeal_nord.sf2',
  '29_epiano 3 mk II shallow_nord.sf2',
  '30_epiano 4 mk V closldeal_nord.sf2',
  '31_ep5 bright tines custommod_nord.sf2',
  '32_ep6 spaekle top vintage67_nord.sf2',
  '33_epiano7 mk1 amped_nord.sf2',
  '34_ep8 nefrtiti mk1 1970_nord.sf2',
  '35_wurlitzer 1 200a_nord.sf2',
  '36_wurlitzer 2 amped_nord.sf2',
  '37_digigrand 1_nord.sf2',
  '38_digigrand 2_nord.sf2',
  '39_dx fulltines_nord.sf2',
  '40_dx rubbarhodes_nord.sf2',
  '41_ballad ep1_nord.sf2',
  '42_ballad ep2_nord.sf2',
  '43_silver ep_nord.sf2',
  '44_hybrid ep_nord.sf2',
];

/// Lista da biblioteca na Web: os timbres nativos vêm primeiro e os
/// importados pelo usuário são acrescentados (sem duplicar nomes).
List<SoundFont> mergeBuiltinSoundfonts(List<SoundFont> imported) {
  final merged = <SoundFont>[
    for (final filename in builtinSoundfontFilenames)
      SoundFont(
        filename: filename,
        path: '$builtinSoundfontAssetDir/$filename',
        builtin: true,
      ),
  ];
  for (final font in imported) {
    if (!merged.any((builtin) => builtin.filename == font.filename)) {
      merged.add(font);
    }
  }
  merged.sort(
    (a, b) => a.filename.toLowerCase().compareTo(b.filename.toLowerCase()),
  );
  return merged;
}
