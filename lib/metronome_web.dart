import 'dart:js_interop';

import 'package:web/web.dart' as web;

class MetronomeOutput {
  web.AudioContext? _context;

  Future<void> click({required bool accent}) async {
    final context = _context ??= web.AudioContext();
    if (context.state == 'suspended') await context.resume().toDart;

    final now = context.currentTime;
    final oscillator = context.createOscillator();
    final gain = context.createGain();
    oscillator.type = 'square';
    oscillator.frequency.setValueAtTime(accent ? 1320 : 880, now);
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(accent ? 0.16 : 0.1, now + 0.004);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.055);
    oscillator.connect(gain);
    gain.connect(context.destination);
    oscillator.start(now);
    oscillator.stop(now + 0.06);
  }

  Future<void> dispose() async {
    final context = _context;
    _context = null;
    if (context != null && context.state != 'closed') {
      await context.close().toDart;
    }
  }
}
