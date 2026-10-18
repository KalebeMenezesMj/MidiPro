// Web-only: opens the native folder dialog and returns the .sf2 files inside
// it, without reading their bytes yet. Returns null when the user cancels.
import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<List<web.File>?> pickSoundfontFolder() {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.sf2'
    ..style.display = 'none';
  input.setAttribute('webkitdirectory', '');
  input.setAttribute('multiple', '');
  web.document.body?.append(input);

  final completer = Completer<List<web.File>?>();
  var finished = false;
  late final web.EventListener focusListener;

  void finish(List<web.File>? files) {
    if (finished) return;
    finished = true;
    web.window.removeEventListener('focus', focusListener);
    input.remove();
    completer.complete(files);
  }

  focusListener = ((web.Event event) {
    // The dialog closed without a selection: if nothing arrives shortly
    // after the window regains focus, treat it as a cancel.
    Timer(const Duration(seconds: 1), () {
      if (!finished) finish(null);
    });
  }).toJS;

  input.addEventListener(
    'change',
    ((web.Event event) {
      final files = <web.File>[];
      final list = input.files;
      if (list != null) {
        for (var index = 0; index < list.length; index++) {
          final file = list.item(index);
          if (file != null && file.name.toLowerCase().endsWith('.sf2')) {
            files.add(file);
          }
        }
      }
      finish(files);
    }).toJS,
  );
  input.addEventListener('cancel', ((web.Event event) => finish(null)).toJS);
  web.window.addEventListener('focus', focusListener);

  input.click();
  return completer.future;
}
