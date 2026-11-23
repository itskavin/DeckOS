import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'backup_file_error.dart';

/// Baixa o backup pelo navegador.
Future<void> saveBackupFile(List<int> bytes, String name) async {
  final blob = web.Blob(
    [Uint8List.fromList(bytes).toJS].toJS,
    web.BlobPropertyBag(type: 'application/zip'),
  );
  final url = web.URL.createObjectURL(blob);
  final a = web.HTMLAnchorElement()
    ..href = url
    ..download = name;
  web.document.body?.append(a);
  a.click();
  a.remove();
  // O download lê o blob depois do click: revogar na hora cancelava o arquivo (0 bytes).
  Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
}

/// Abre o seletor de arquivos do navegador. Null se o usuário cancelar.
Future<List<int>?> pickBackupFile({String accept = '.deckos,.droiddeck,.zip'}) {
  final completer = Completer<List<int>?>();
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = accept
    ..style.display = 'none';

  late final JSFunction onFocus;
  Timer? focusTimer;

  void cleanup() {
    focusTimer?.cancel();
    web.window.removeEventListener('focus', onFocus);
    input.remove();
  }

  void finish(List<int>? bytes) {
    if (completer.isCompleted) return;
    cleanup();
    completer.complete(bytes);
  }

  void finishError(Object error, StackTrace stackTrace) {
    if (completer.isCompleted) return;
    cleanup();
    completer.completeError(BackupFileReadException(error), stackTrace);
  }

  onFocus = (web.Event _) {
    // Fallback para navegadores sem evento "cancel" no <input type="file">.
    focusTimer?.cancel();
    focusTimer = Timer(const Duration(milliseconds: 400), () {
      if (!completer.isCompleted && (input.files?.length ?? 0) == 0) {
        finish(null);
      }
    });
  }.toJS;

  input.onchange = (web.Event _) {
    final file = input.files?.item(0);
    if (file == null) {
      finish(null);
      return;
    }
    try {
      file.arrayBuffer().toDart.then(
            (buffer) => finish(buffer.toDart.asUint8List()),
            onError: (Object error, StackTrace stackTrace) =>
                finishError(error, stackTrace),
          );
    } catch (error, stackTrace) {
      finishError(error, stackTrace);
    }
  }.toJS;

  // Cancelar o seletor resolve com null para não travar os botões de backup em _busy.
  input.addEventListener(
    'cancel',
    ((web.Event _) => finish(null)).toJS,
  );
  web.window.addEventListener('focus', onFocus);
  web.document.body?.append(input);
  input.click();
  return completer.future;
}

const bool canPickBackup = true;
