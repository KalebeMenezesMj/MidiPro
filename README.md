# MIDI Pro

Teclado Flutter para Android, iOS e navegador, inspirado no piano interativo da AmostraLab. Toca SoundFonts `.sf2` com FluidSynth/WebAssembly.

## Executar no navegador

Flutter e cache de pacotes ficam em `D:\midipro-tools`. No PowerShell:

```powershell
cd C:\Users\Kalebe\Desktop\midipro
.\run-web.cmd
```

O script serve em `http://127.0.0.1:5180` e abre o Chrome com um perfil do app em `D:\midipro-tools\chrome-profile`; mantenha a janela do servidor aberta.

## Biblioteca de timbres

Os 44 SoundFonts `.sf2` (≈410 MiB) são nativos do app: ficam no pacote de assets `D:\midipro-tools\midipro-soundfonts` e são servidos pelo build em `D:\midipro-tools\midipro-web-app`, sem precisar importar nada. O app baixa do servidor local apenas o timbre que está em uso.

Para adicionar outros arquivos, use o botão **de pasta** (ícone ao lado do **+**) para importar todos os `.sf2` de uma pasta de uma vez, ou clique em **+** para escolher arquivos (mantenha Ctrl pressionado para selecionar vários). Esses extras ficam no IndexedDB do perfil do Chrome e não podem ter o mesmo nome de um timbre nativo. Só os timbres ativos são carregados na memória.

## MIDI e ferramentas

No Chrome/Edge, clique no ícone de piano, permita Web MIDI e escolha a entrada do controlador. Há suporte a notas, pitch bend (roda de pitch), modulação (CC1), pedal sustain (CC64), volume (CC7) e all-notes-off (CC120/123).

O botão de ajustes abre camadas de até dois timbres, reverb, delay, EQ de graves/médios/agudos, metrônomo com BPM e presets salvos. Há também o controle **Sustain (pedal)**: define por quanto tempo (0–5 s) as notas sustentadas continuam soando depois que o pedal é solto. Efeitos avançados usam o backend WebAssembly do fork local de `flutter_midi_pro`; o pacote oficial não inclui suporte Web.

## Verificações

```powershell
$env:PUB_CACHE = 'D:\midipro-tools\pub-cache'
& 'D:\midipro-tools\flutter\bin\flutter.bat' analyze
& 'D:\midipro-tools\flutter\bin\flutter.bat' test
```
