import 'dart:async';
import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/config/account_integration_page.dart';
import 'package:deckos/src/config/obs_settings_page.dart';
import 'package:deckos/src/config/triggers_page.dart';
import 'package:deckos/src/home/home_page.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.choice.value = 'pt';
  });

  tearDown(() async {
    await GetIt.I.reset();
  });

  testWidgets('TriggersPage guarda os IDs retornados por PUT /api/triggers ao testar',
      (tester) async {
    final runCalls = <String>[];
    final profileJson = jsonDecode(jsonEncode(DeckProfile(
      id: 'p1',
      name: 'Principal',
      rows: 2,
      columns: 4,
      buttons: [
        DeckButton(
          id: 'b1',
          row: 0,
          column: 0,
          label: 'Mudo',
          action: DeckAction(type: 'media'),
        ),
      ],
    ).toJson())) as Map<String, dynamic>;

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/api/triggers' && options.method == 'GET') {
          return handler.resolve(Response(requestOptions: options, statusCode: 200, data: []));
        }
        if (options.path == '/api/triggers' && options.method == 'PUT') {
          final body = (options.data as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
          for (var i = 0; i < body.length; i++) {
            body[i]['id'] ??= 'srv-id-${i + 1}';
          }
          return handler.resolve(Response(requestOptions: options, statusCode: 200, data: body));
        }
        if (options.path.startsWith('/api/triggers/') && options.path.endsWith('/run')) {
          runCalls.add(options.path);
          return handler.resolve(Response(requestOptions: options, statusCode: 200, data: {}));
        }
        if (options.path == '/api/StreamDeck/profiles') {
          return handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: [profileJson]));
        }
        if (options.path == '/api/system/apps') {
          return handler.resolve(Response(requestOptions: options, statusCode: 200, data: []));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: {}));
      },
    ));

    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(SignalRService());

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: const TriggersPage(),
    ));
    await tester.pumpAndSettle();

    // Cria nova automação (evento "Quando o DeckOS iniciar" + botão "Mudo").
    await tester.tap(find.text('Nova automação').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Num horário'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quando o DeckOS iniciar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apertar o botão'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Principal · Mudo'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Salvar'));
    await tester.pumpAndSettle();

    // Abre opções do cartão criado e toca em "Testar agora".
    await tester.tap(find.byTooltip('Opções'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Testar agora'));
    await tester.pumpAndSettle();

    expect(runCalls, ['/api/triggers/srv-id-1/run']);
  });

  testWidgets('AccountIntegrationPage reflete desconexão ao vivo vinda do SignalR',
      (tester) async {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/api/integrations/homeassistant' && options.method == 'GET') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'configured': true, 'connected': true, 'fields': {'url': 'http://ha.local:8123'}},
          ));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: {}));
      },
    ));
    final signalR = SignalRService();
    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(signalR);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: const AccountIntegrationPage(spec: homeAssistantSpec),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Conectado'), findsOneWidget);

    // SignalR informa queda real da integração.
    signalR.seedState(homeAssistantSpec.stateEvent, {'connected': false});
    await tester.pumpAndSettle();

    expect(find.text('Desconectado'), findsOneWidget);
    expect(find.text('Conectado'), findsNothing);
  });

  testWidgets('ObsSettingsPage preenche host/porta salvos e usa disconnect/config',
      (tester) async {
    final calls = <String>[];
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        calls.add('${options.method} ${options.path}');
        if (options.path == '/api/obs/state') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'connected': true,
              'configured': true,
              'host': '192.168.1.50',
              'port': 4466,
              'hasPassword': true,
              'currentScene': 'Live',
            },
          ));
        }
        if (options.path == '/api/obs/disconnect' && options.method == 'POST') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'connected': false, 'configured': true, 'host': '192.168.1.50', 'port': 4466, 'hasPassword': true},
          ));
        }
        if (options.path == '/api/obs/config' && options.method == 'DELETE') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'connected': false, 'configured': false},
          ));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: {}));
      },
    ));
    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(SignalRService());

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: const ObsSettingsPage(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('192.168.1.50'), findsOneWidget);
    expect(find.text('4466'), findsOneWidget);

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('Desconectar'),
      200,
      scrollable: scrollable,
    );
    await tester.tap(find.text('Desconectar'));
    await tester.pumpAndSettle();
    expect(calls, contains('POST /api/obs/disconnect'));

    await tester.scrollUntilVisible(
      find.text('Esquecer'),
      200,
      scrollable: scrollable,
    );
    await tester.tap(find.text('Esquecer'));
    await tester.pumpAndSettle();
    expect(calls, contains('DELETE /api/obs/config'));
  });

  testWidgets('HomePage abre o Deck imediatamente mesmo enquanto /api/v1/Mixer/out demora',
      (tester) async {
    final mixerCompleter = Completer<Response>();
    final profileJson = jsonDecode(jsonEncode(DeckProfile(
      id: 'p1',
      name: 'Principal',
      rows: 2,
      columns: 4,
      buttons: [
        DeckButton(id: 'b1', row: 0, column: 0, label: 'Cena 1', iconName: 'videocam'),
      ],
    ).toJson())) as Map<String, dynamic>;

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/api/v1/Mixer/out') {
          mixerCompleter.future.then((r) => handler.resolve(r));
          return;
        }
        if (options.path == '/api/StreamDeck/profiles') {
          return handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: [profileJson]));
        }
        if (options.path == '/api/StreamDeck/layout') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'rows': 2, 'columns': 4},
          ));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: []));
      },
    ));
    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(SignalRService());

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
      home: const HomePage(),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    // O botão do deck já está visível mesmo com /api/v1/Mixer/out ainda pendente!
    expect(find.text('Cena 1'), findsOneWidget);

    // Completa a chamada para não deixar futures pendentes.
    mixerCompleter.complete(Response(
      requestOptions: RequestOptions(path: '/api/v1/Mixer/out'),
      statusCode: 200,
      data: const [],
    ));
    await tester.pumpAndSettle();

    // A barra de navegação da Home acompanha o auto-hide de 5s sem deslocar a tecla.
    final tileBefore = tester.getRect(find.text('Cena 1'));
    // 800x600 conta como retrato (só é deitado com altura < 600): barra inferior.
    final navFinder = find.ancestor(
      of: find.byKey(const ValueKey('home-bottom-nav')),
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(navFinder.first).opacity, 1.0);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedOpacity>(navFinder.first).opacity, 0.0);
    expect(tester.getRect(find.text('Cena 1')), tileBefore);
  });

  testWidgets('HomePage deitado: a faixa lateral não cobre a barra do topo do deck',
      (tester) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final profileJson = jsonDecode(jsonEncode(DeckProfile(
      id: 'p1',
      name: 'Principal',
      rows: 2,
      columns: 4,
      buttons: [
        DeckButton(id: 'b1', row: 0, column: 0, label: 'Cena 1', iconName: 'videocam'),
      ],
    ).toJson())) as Map<String, dynamic>;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/api/StreamDeck/profiles') {
          return handler.resolve(
              Response(requestOptions: options, statusCode: 200, data: [profileJson]));
        }
        if (options.path == '/api/StreamDeck/layout') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'rows': 2, 'columns': 4},
          ));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: []));
      },
    ));
    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(SignalRService());

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
      home: const HomePage(),
    ));
    await tester.pumpAndSettle();

    final rail = tester.getRect(find.byKey(const ValueKey('home-side-nav')));
    final top = tester.getRect(find.byKey(const ValueKey('deck-top-chrome')));
    expect(rail.width, greaterThan(0));
    expect(top.left, greaterThanOrEqualTo(rail.right));
  });
}
