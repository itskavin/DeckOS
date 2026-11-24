import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:deckos/core/deckos_client/deckos_client.dart';
import 'package:deckos/src/connection/transport_policy.dart';
import 'package:deckos/src/connection/transport_platform_io.dart';
import 'package:deckos/src/connection/secure_signalr.dart';
import 'package:deckos/src/connection/secure_websocket_io.dart';
import 'package:deckos/src/connection/usb_route.dart';
import 'package:deckos/src/welcome/pairing.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:signalr_netcore/itransport.dart';
import 'package:signalr_netcore/signalr_client.dart';

void main() {
  late Directory fixtures;
  late HttpServer server;
  var requests = 0;
  var upgrades = 0;
  var uploaded = 0;
  final sockets = <WebSocket>[];
  late String endpoint;
  late String pin;
  setUpAll(() async {
    fixtures = await Directory.systemTemp.createTemp('deckos-tls-test-');
    final dotnetRoot = Platform.environment['DOTNET_ROOT'];
    final executable = dotnetRoot == null
        ? 'dotnet'
        : '$dotnetRoot/dotnet${Platform.isWindows ? '.exe' : ''}';
    final result = await Process.run(executable, [
      'run',
      '--project',
      '../tests/TransportFixtures',
      '--',
      fixtures.path,
    ]);
    if (result.exitCode != 0)
      throw StateError(
        'TLS fixture generation failed: ${result.stderr} ${result.stdout}',
      );
    pin = File('${fixtures.path}/server.pin').readAsStringSync();
  });
  tearDownAll(() async {
    await fixtures.delete(recursive: true);
  });

  Future<void> start([String certificate = 'server', int port = 0]) async {
    requests = 0;
    upgrades = 0;
    uploaded = 0;
    final context = SecurityContext()
      ..useCertificateChain('${fixtures.path}/$certificate.pem')
      ..usePrivateKey('${fixtures.path}/$certificate-key.pem');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      port,
      context,
    );
    endpoint = 'https://127.0.0.1:${server.port}';
    server.listen((request) async {
      requests++;
      expect(request.headers.value('x-api-key'), 'test-device-credential');
      expect(request.uri.queryParameters.containsKey('access_token'), isFalse);
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        upgrades++;
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        socket.listen((data) {
          if ('$data'.contains('protocol'))
            socket.add('{}\u001e');
          else
            socket.add(data);
        });
      } else if (request.uri.path.endsWith('/negotiate')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'negotiateVersion': 1,
            'connectionId': 'fixture',
            'connectionToken': 'fixture',
            'availableTransports': [
              {
                'transport': 'WebSockets',
                'transferFormats': ['Text', 'Binary'],
              },
            ],
          }),
        );
        await request.response.close();
      } else {
        uploaded = await request.fold<int>(
          0,
          (sum, bytes) => sum + bytes.length,
        );
        request.response.add(Uint8List(1024 * 1024));
        await request.response.close();
      }
    });
  }

  Future<void> stop() async {
    for (final socket in sockets) {
      unawaited(socket.close());
    }
    sockets.clear();
    await server.close(force: true);
  }

  TransportPolicy policy([String? fingerprint]) =>
      TransportPolicy(endpoint, pin: fingerprint ?? pin);
  Dio authenticated(TransportPolicy p) =>
      p.dio()..options.headers['X-API-KEY'] = 'test-device-credential';

  test('REST image/download and large binary upload use pinned TLS', () async {
    await start();
    final dio = authenticated(policy());
    final r = await dio.get<List<int>>(
      '/image',
      options: Options(responseType: ResponseType.bytes),
    );
    expect(r.data!.length, 1024 * 1024);
    await dio.post(
      '/upload',
      data: Uint8List(2 * 1024 * 1024),
      options: Options(
        contentType: 'application/octet-stream',
        responseType: ResponseType.bytes,
      ),
    );
    expect(uploaded, 2 * 1024 * 1024);
    expect(requests, 2);
    dio.close(force: true);
    await stop();
  });
  test('wrong pin fails before REST or WebSocket sends a credential', () async {
    await start();
    final wrong = policy('0' * 64);
    final dio = authenticated(wrong);
    await expectLater(dio.get('/auth'), throwsA(isA<DioException>()));
    final ws = secureWebSocket(wrong, 'test-device-credential');
    await expectLater(
      ws.connect('$endpoint/deckHub', TransferFormat.Text),
      throwsA(isA<HandshakeException>()),
    );
    expect(requests, 0);
    expect(upgrades, 0);
    dio.close(force: true);
    await stop();
  });
  test(
    'CA-valid wrong pin also fails before credentials (callback is not sufficient)',
    () async {
      await start();
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates('${fixtures.path}/root.pem');
      final wrong = policy('0' * 64);
      final dio = authenticated(wrong);
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => secureHttpClient(wrong, context: context),
      );
      await expectLater(dio.get('/auth'), throwsA(isA<DioException>()));
      final ws = secureWebSocket(
        wrong,
        'test-device-credential',
        context: context,
      );
      await expectLater(
        ws.connect('$endpoint/deckHub', TransferFormat.Text),
        throwsA(isA<HandshakeException>()),
      );
      expect(requests, 0);
      dio.close(force: true);
      await stop();
    },
  );
  test(
    'changed certificate rejected on a fresh connection to the saved PC',
    () async {
      await start('changed');
      final dio = authenticated(policy());
      await expectLater(dio.get('/auth'), throwsA(isA<DioException>()));
      expect(requests, 0);
      dio.close(force: true);
      await stop();
    },
  );
  test(
    'system CA endpoint uses normal hostname and trust validation',
    () async {
      await start();
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates('${fixtures.path}/root.pem');
      final trusted = TransportPolicy(endpoint);
      final dio = authenticated(trusted);
      dio.httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => secureHttpClient(trusted, context: context),
      );
      await dio.get(
        '/auth',
        options: Options(responseType: ResponseType.bytes),
      );
      expect(requests, 1);
      dio.close(force: true);
      final untrusted = authenticated(trusted);
      await expectLater(untrusted.get('/auth'), throwsA(isA<DioException>()));
      expect(requests, 1);
      untrusted.close(force: true);
      await stop();
    },
  );
  test('legacy HTTP cannot transmit any authentication request', () async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var observed = 0;
    http.listen((request) {
      observed++;
      request.response.close();
    });
    final client = DeckOSClient(baseUrl: 'http://127.0.0.1:${http.port}')
      ..setApiKey('never-send-this');
    await expectLater(client.getJson('/auth'), throwsA(isA<DioException>()));
    expect(observed, 0);
    await http.close(force: true);
  });
  test('expired certificate rejected even when its pin matches', () async {
    await start('expired');
    final dio = authenticated(
      policy(File('${fixtures.path}/expired.pin').readAsStringSync()),
    );
    await expectLater(dio.get('/auth'), throwsA(isA<DioException>()));
    expect(requests, 0);
    dio.close(force: true);
    await stop();
  });
  test(
    'SignalR negotiate, upgrade and explicit reconnect all use header credentials over TLS',
    () async {
      await start();
      final hub = HubConnectionBuilder()
          .withUrl(
            '$endpoint/deckHub',
            options: secureSignalROptions(policy(), 'test-device-credential'),
          )
          .build();
      await hub.start();
      expect(upgrades, 1);
      expect(requests, 2);
      await hub.stop();
      await hub.start();
      expect(upgrades, 2);
      expect(requests, 4);
      await hub.stop();
      await stop();
    },
  );
  test('lost forwarded TLS route retries GET only at the same verified PC', () async {
    await start();
    final unavailable = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final forwarded = 'https://127.0.0.1:${unavailable.port}';
    await unavailable.close();
    final trust = TransportPolicy(endpoint, pin: pin, forwardedUrl: forwarded);
    final client = DeckOSClient(baseUrl: '');
    client.configureSecure(trust, 'test-device-credential', route: forwarded);
    client.onConnectionRefused = (failed, credential) async {
      expect(failed, forwarded);
      expect(credential, 'test-device-credential');
      client.setBaseUrl(endpoint);
      return endpoint;
    };
    final image = await client.getAppIcon(const InstalledApp(id: 'fixture', name: 'fixture', path: '', iconUrl: '/image'));
    expect(image?.length, 1024 * 1024);
    expect(requests, 1);
    expect(client.currentBaseUrl, endpoint);
    await stop();
  });
  test('SignalR automatic reconnect establishes another verified TLS WebSocket', () async {
    await start();
    final hub = HubConnectionBuilder().withUrl('$endpoint/deckHub',
      options: secureSignalROptions(policy(), 'test-device-credential'))
      .withAutomaticReconnect(retryDelays: [0, 100, 200]).build();
    final reconnected = Completer<void>();
    hub.onreconnected(({connectionId}) { if (!reconnected.isCompleted) reconnected.complete(); });
    await hub.start();
    await sockets.first.close();
    await reconnected.future.timeout(const Duration(seconds: 8));
    expect(upgrades, 2);
    expect(requests, 4);
    await hub.stop(); await stop();
  });
  test('SignalR wrong pin cannot reach negotiation or upgrade', () async {
    await start();
    final hub = HubConnectionBuilder()
        .withUrl(
          '$endpoint/deckHub',
          options: secureSignalROptions(
            policy('f' * 64),
            'test-device-credential',
          ),
        )
        .build();
    await expectLater(hub.start(), throwsA(anything));
    expect(requests, 0);
    await hub.stop();
    await stop();
  });
  test(
    'PC switch closes old pool and rejects a cached absolute URL to the old PC',
    () async {
      await start();
      final client = DeckOSClient(baseUrl: '');
      client.configureSecure(policy(), 'test-device-credential');
      final oldEndpoint = endpoint;
      client.configureSecure(
        TransportPolicy('https://127.0.0.1:1', pin: pin),
        'other-device',
      );
      await expectLater(
        client.getJson('$oldEndpoint/auth'),
        throwsA(isA<DioException>()),
      );
      expect(requests, 0);
      await stop();
    },
  );
  test(
    'HTTP endpoints, malformed pins, old QR and discovery addresses cannot establish trust',
    () async {
      for (final endpoint in [
        'http://192.168.1.2:4787',
        'https://user:pw@pc',
        'https://pc/path',
        'https://pc?token=x',
        'https://pc:99999',
      ]) {
        expect(() => TransportPolicy(endpoint), throwsFormatException);
      }
      expect(
        () => TransportPolicy('https://pc', pin: 'broken'),
        throwsFormatException,
      );
      expect(parsePairingQr('deckos://pair?ip=pc&key=legacy'), isNull);
      final valid = Uri(
        scheme: 'deckos',
        host: 'pair',
        queryParameters: {
          'v': '2',
          'endpoint': 'https://pc:4788',
          'pin': 'a' * 64,
          'token': 'b' * 64,
        },
      ).toString();
      expect(parsePairingQr(valid)?.policy.endpoint.origin, 'https://pc:4788');
      expect(parsePairingQr('$valid&pin=${'c' * 64}'), isNull);
      expect(parsePairingQr(valid.replaceFirst('https', 'http')), isNull);
      expect(await connectToAddress('192.168.1.2:4788'), isFalse);
      expect(UsbRoute.usbBaseUrl, startsWith('https://'));
      await expectLater(
        UsbRoute.pick('http://old-pc:4787', apiKey: 'secret'),
        throwsFormatException,
      );
    },
  );
}
