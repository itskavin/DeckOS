import 'dart:io';

import 'package:deckos/core/core.dart';
import 'package:flutter_test/flutter_test.dart';

/// Porta local sem ninguém escutando: a conexão é recusada, como o 127.0.0.1:4787 do
/// celular depois que o adb reverse some.
Future<String> _refusedBaseUrl() async {
  final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return 'http://127.0.0.1:$port';
}

void main() {
  test('refused connection retries the press once on the new address', () async {
    var presses = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      if (r.uri.path == '/api/StreamDeck/press') presses++;
      r.response.statusCode = 200;
      await r.response.close();
    });
    addTearDown(() => server.close(force: true));

    final refused = await _refusedBaseUrl();
    final asked = <String>[];
    final client = DeckOSClient(baseUrl: refused)
      ..onConnectionRefused = (url, key) async {
        asked.add(url);
        return 'http://127.0.0.1:${server.port}';
      };

    await client.pressButton('p', 'b');

    expect(asked, [refused]);
    expect(presses, 1);
  });

  test('a failure after connecting is not replayed', () async {
    var presses = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      presses++;
      // O PC recebeu (pode ter executado) e a conexão caiu antes da resposta.
      (await r.response.detachSocket(writeHeaders: false)).destroy();
    });
    addTearDown(() => server.close(force: true));

    var asked = 0;
    final client = DeckOSClient(baseUrl: 'http://127.0.0.1:${server.port}')
      ..onConnectionRefused = (url, key) async {
        asked++;
        return url;
      };

    await expectLater(client.pressButton('p', 'b'), throwsA(isA<DioException>()));
    expect(asked, 0);
    expect(presses, 1);
  });
}
