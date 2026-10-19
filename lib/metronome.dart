export 'metronome_stub.dart'
    if (dart.library.js_interop) 'metronome_web.dart'
    if (dart.library.io) 'metronome_android.dart';
