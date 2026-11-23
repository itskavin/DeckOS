import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/home/home_nav.dart';
import 'package:deckos/src/home/home_page.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _registerMockBackend({List<String>? pressed}) {
  final profiles = [
    DeckProfile(
      id: 'p1',
      name: 'Principal',
      rows: 2,
      columns: 4,
      buttons: [
        DeckButton(
          id: 'b1',
          row: 0,
          column: 0,
          label: 'Cena 1',
          iconName: 'videocam',
          action: DeckAction(type: 'media'),
        ),
        DeckButton(
          id: 'b2',
          row: 0,
          column: 1,
          label: 'Mudo',
          iconName: 'mic_off',
          action: DeckAction(type: 'media'),
        ),
      ],
    ),
    DeckProfile(
      id: 'p2',
      name: 'Live',
      rows: 2,
      columns: 4,
      buttons: [
        DeckButton(
          id: 'b3',
          row: 0,
          column: 0,
          label: 'Gravar',
          iconName: 'fiber_manual_record',
          action: DeckAction(type: 'media'),
        ),
      ],
    ),
  ];

  final profilesJson =
      profiles.map((p) => jsonDecode(jsonEncode(p.toJson()))).toList();

  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      if (options.path == '/api/StreamDeck/profiles' && options.method == 'GET') {
        return handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: profilesJson),
        );
      }
      if (options.path == '/api/StreamDeck/layout' && options.method == 'GET') {
        return handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {'rows': 2, 'columns': 4},
        ));
      }
      if (options.path == '/api/StreamDeck/press') {
        pressed?.add('${(options.data as Map)['buttonId']}');
        return handler.resolve(Response(requestOptions: options, statusCode: 200));
      }
      if (options.path == '/api/actions/schema') {
        return handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: const []),
        );
      }
      return handler.resolve(
        Response(requestOptions: options, statusCode: 200, data: const []),
      );
    },
  ));

  GetIt.I.registerSingleton<DeckOSClient>(
    DeckOSClient(baseUrl: 'http://localhost', dio: dio),
  );
  GetIt.I.registerSingleton<SignalRService>(SignalRService());
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.choice.value = 'pt';
  });

  tearDown(() async {
    await ThemeController.instance.setDeckOnly(false);
    await ThemeController.instance.setCustomGrid(null);
    await GetIt.I.reset();
  });

  testWidgets(
      'retrato: pílula flutuante compacta, alvos >= 44 dp, esconde em 5 s sem fantasma e preserva teclas',
      (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final pressed = <String>[];
    _registerMockBackend(pressed: pressed);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
      home: const HomePage(),
    ));
    await tester.pumpAndSettle();

    final navFinder = find.byKey(const ValueKey('home-bottom-nav'));
    expect(navFinder, findsOneWidget);
    final navRect = tester.getRect(navFinder);
    // Cápsula só-ícones bem compacta e centrada em retrato (espelho da lateral de paisagem).
    expect(navRect.width, lessThanOrEqualTo(96));
    expect(navRect.height, greaterThanOrEqualTo(44));
    expect(navRect.height, lessThanOrEqualTo(48));
    expect((navRect.center.dx - 412 / 2).abs(), lessThan(2.0));

    // Alvos de toque confortáveis (>= 44 dp) com tooltips acessíveis.
    final audioTab = find.descendant(of: navFinder, matching: find.byTooltip('Áudio'));
    final deckTab = find.descendant(of: navFinder, matching: find.byTooltip('Deck'));
    expect(audioTab, findsOneWidget);
    expect(deckTab, findsOneWidget);
    expect(tester.getSize(audioTab).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(audioTab).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(deckTab).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(deckTab).width, greaterThanOrEqualTo(44));

    final tileBefore = tester.getRect(find.text('Cena 1'));

    // Após 5 s de inatividade no Deck, pílula e barra superior recolhem sem mover as teclas.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    final navOpacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: navFinder, matching: find.byType(AnimatedOpacity)).first,
    );
    expect(navOpacity.opacity, 0.0);
    expect(tester.getRect(find.text('Cena 1')), tileBefore);

    // Com os controles escondidos, tocar na tecla dispara já no 1º toque sem piscar a barra.
    await tester.tap(find.text('Cena 1'));
    await tester.pumpAndSettle();
    expect(pressed, ['b1']);
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.ancestor(of: navFinder, matching: find.byType(AnimatedOpacity)).first,
          )
          .opacity,
      0.0,
    );

    // Sem alvo fantasma: tocar exatamente onde o botão "Áudio" da pílula estava NÃO muda de aba;
    // o toque atravessa para a área livre do Deck e revela os controles.
    await tester.tapAt(navRect.centerLeft + const Offset(22, 0));
    await tester.pumpAndSettle();
    expect(find.text('Cena 1'), findsOneWidget);
    expect(tester.state<HomePageState>(find.byType(HomePage)).selectedIndex, 1);
    final revealedOpacity = tester.widget<AnimatedOpacity>(
      find.ancestor(of: navFinder, matching: find.byType(AnimatedOpacity)).first,
    );
    expect(revealedOpacity.opacity, 1.0);
  });

  testWidgets(
      'paisagem: trilho lateral enxuto em cápsula centrada, não cobre barra nem modo de edição',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    _registerMockBackend();

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.light),
      home: const HomePage(),
    ));
    await tester.pumpAndSettle();

    final railFinder = find.byKey(const ValueKey('home-side-nav'));
    final topFinder = find.byKey(const ValueKey('deck-top-chrome'));
    expect(railFinder, findsOneWidget);
    expect(topFinder, findsOneWidget);

    final rail = tester.getRect(railFinder);
    final top = tester.getRect(topFinder);
    final topPill = tester.getRect(find.byKey(const ValueKey('deck-top-pill')));
    final tile = tester.getRect(find.text('Cena 1'));

    // Trilho enxuto só-ícones e compacto verticalmente (não é parede de cima a baixo).
    expect(rail.width, lessThanOrEqualTo(48));
    expect(rail.right, lessThanOrEqualTo(54));
    expect(rail.height, lessThan(412 * 0.35));
    expect((rail.center.dy - 412 / 2).abs(), lessThan(4.0));
    // Barra superior de largura média centrada na tela (nem minúscula nem ponta a ponta).
    expect(topPill.width, greaterThanOrEqualTo(380));
    expect(topPill.width, lessThan(915 * 0.65));
    expect((topPill.center.dx - 915 / 2).abs(), lessThan(2.0));
    expect(topPill.left, greaterThanOrEqualTo(rail.right));
    // Sem sobrepor a barra superior nem as teclas do deck.
    expect(top.left, greaterThanOrEqualTo(rail.right));
    expect(tile.left, greaterThanOrEqualTo(rail.right));

    // Alvos de toque confortáveis (>= 44 dp) com tooltips acessíveis.
    final audioTab = find.descendant(of: railFinder, matching: find.byTooltip('Áudio'));
    final deckTab = find.descendant(of: railFinder, matching: find.byTooltip('Deck'));
    expect(tester.getSize(audioTab).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(audioTab).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(deckTab).width, greaterThanOrEqualTo(44));
    expect(tester.getSize(deckTab).height, greaterThanOrEqualTo(44));

    // Entra em modo de edição: botão Cancelar e título ficam totalmente livres do trilho.
    await tester.tap(find.byTooltip('Editar layout'));
    await tester.pumpAndSettle();
    final cancelRect = tester.getRect(find.text('Cancelar'));
    expect(cancelRect.left, greaterThanOrEqualTo(rail.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'paisagem com recorte de câmera à esquerda: não duplica margem no Áudio e não cobre grade densa',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    _registerMockBackend();

    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(
        size: Size(915, 412),
        padding: EdgeInsets.only(left: 48),
      ),
      child: MaterialApp(
        theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
        home: const HomePage(),
      ),
    ));
    await tester.pumpAndSettle();

    final railFinder = find.byKey(const ValueKey('home-side-nav'));
    final rail = tester.getRect(railFinder);
    final top = tester.getRect(find.byKey(const ValueKey('deck-top-chrome')));
    final topPill = tester.getRect(find.byKey(const ValueKey('deck-top-pill')));
    final tile = tester.getRect(find.text('Cena 1'));

    // Começa rente ao recorte da câmera, sem margem extra desnecessária nem invasão.
    expect(rail.left, greaterThanOrEqualTo(48));
    expect(rail.left, lessThanOrEqualTo(52));
    expect(rail.width, lessThanOrEqualTo(48));
    // Barra superior continua centrada na tela mesmo com recorte + trilho à esquerda.
    expect((topPill.center.dx - 915 / 2).abs(), lessThan(2.0));
    expect(top.left, greaterThanOrEqualTo(rail.right));
    expect(tile.left, greaterThanOrEqualTo(rail.right));

    // Na aba de Áudio, o conteúdo começa logo após o trilho sem duplicar os 48 dp do SafeArea.
    await tester.tap(
      find.descendant(of: railFinder, matching: find.byTooltip('Áudio')),
    );
    await tester.pumpAndSettle();
    final audioTitle = tester.getRect(find.text('Áudio'));
    expect(audioTitle.left, greaterThanOrEqualTo(rail.right));
    expect(audioTitle.left - rail.right, lessThan(36));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'preserva aba salva ao girar retrato <-> paisagem e ao reabrir o app sem dessincronizar PageView',
      (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    _registerMockBackend();

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: const HomePage(),
    ));
    await tester.pumpAndSettle();

    // Troca para a aba Áudio em retrato.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('home-bottom-nav')),
        matching: find.byTooltip('Áudio'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Saídas'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('home_tab'), 0);

    // Gira dinamicamente para paisagem: continua na aba Áudio e exibe trilho lateral.
    tester.view.physicalSize = const Size(915, 412);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-side-nav')), findsOneWidget);
    expect(find.text('Saídas'), findsOneWidget);

    // Gira de volta para retrato: continua em Áudio com pílula inferior.
    tester.view.physicalSize = const Size(412, 915);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-bottom-nav')), findsOneWidget);
    expect(find.text('Saídas'), findsOneWidget);

    // Simula reabertura fria (novo HomePage lendo SharedPreferences).
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: const HomePage(key: ValueKey('cold-reopen')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Saídas'), findsOneWidget);
    final homeState = tester.state<HomePageState>(find.byType(HomePage));
    expect(homeState.selectedIndex, 0);
  });

  testWidgets(
      'texto grande (1.8x), movimento reduzido e teclado virtual não causam overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    _registerMockBackend();

    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(
        size: Size(360, 780),
        textScaler: TextScaler.linear(1.8),
        disableAnimations: true,
      ),
      child: MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: const HomePage(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(HomeBottomPillNav), findsOneWidget);

    // Troca de aba com movimento reduzido pula direto sem erro.
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('home-bottom-nav')),
        matching: find.byTooltip('Áudio'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Saídas'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Teclado virtual aberto em retrato recolhe a pílula para não flutuar sobre o teclado.
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(
        size: Size(360, 780),
        viewInsets: EdgeInsets.only(bottom: 280),
        textScaler: TextScaler.linear(1.8),
        disableAnimations: true,
      ),
      child: MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: const HomePage(),
      ),
    ));
    await tester.pumpAndSettle();
    final opacityWithKeyboard = tester.widget<AnimatedOpacity>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('home-bottom-nav')),
            matching: find.byType(AnimatedOpacity),
          )
          .first,
    );
    expect(opacityWithKeyboard.opacity, 0.0);

    // Paisagem com texto 1.8x e movimento reduzido também fica sem overflow.
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(
        size: Size(844, 390),
        textScaler: TextScaler.linear(1.8),
        disableAnimations: true,
      ),
      child: MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.light),
        home: const HomePage(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(HomeSidePillNav), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'modo Só o deck e tela cheia nunca colapsam para tela preta (alternância a partir de Áudio/Deck, orientação e reabertura fria)',
      (tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    _registerMockBackend();

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
      home: const HomePage(),
    ));
    await tester.pumpAndSettle();

    // 1. Liga Só o deck a partir da aba Deck em retrato: deck renderiza em tela cheia sem colapsar.
    await ThemeController.instance.setDeckOnly(true);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-bottom-nav')), findsNothing);
    expect(find.text('Cena 1'), findsOneWidget);
    final tileRect = tester.getRect(find.text('Cena 1'));
    expect(tileRect.width, greaterThan(40));
    expect(tileRect.height, greaterThan(10));
    expect(find.byTooltip('Configurações'), findsOneWidget);

    // Após 5 s de inatividade em Só o deck, o topo recolhe e a zona de borda permite recuperar Configurações.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('deck-edge-reveal')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Configurações'), findsOneWidget);

    // Gira para paisagem em Só o deck: deck continua visível em tela cheia.
    tester.view.physicalSize = const Size(915, 412);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-side-nav')), findsNothing);
    expect(find.text('Cena 1'), findsOneWidget);
    expect(tester.getRect(find.text('Cena 1')).width, greaterThan(40));

    // 2. Desliga Só o deck -> volta ao Deck com trilho lateral visível.
    await ThemeController.instance.setDeckOnly(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('home-side-nav')), findsOneWidget);

    // Troca para Áudio, liga Só o deck (mostra Deck), desliga Só o deck (volta sincronizado para Áudio).
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('home-side-nav')),
        matching: find.byTooltip('Áudio'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Saídas'), findsOneWidget);

    await ThemeController.instance.setDeckOnly(true);
    await tester.pumpAndSettle();
    expect(find.text('Cena 1'), findsOneWidget);
    expect(tester.getRect(find.text('Cena 1')).width, greaterThan(40));

    await ThemeController.instance.setDeckOnly(false);
    await tester.pumpAndSettle();
    expect(find.text('Saídas'), findsOneWidget);
    expect(find.byKey(const ValueKey('home-side-nav')), findsOneWidget);

    // 3. Reabertura fria com deck_only=true e home_tab=0 (estado real do usuário): abre direto no Deck visível.
    await ThemeController.instance.setDeckOnly(true);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
      home: const HomePage(key: ValueKey('cold-deck-only')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Cena 1'), findsOneWidget);
    expect(tester.getRect(find.text('Cena 1')).width, greaterThan(40));
    expect(tester.takeException(), isNull);
  });
}
