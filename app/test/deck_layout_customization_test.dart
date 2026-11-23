import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/layout/slot_ops.dart';
import 'package:deckos/src/stream_deck/stream_deck_page.dart';
import 'package:deckos/src/stream_deck/widgets/deck_grid_button.dart';
import 'package:deckos/src/stream_deck/widgets/deck_layout_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeckButton _btn(
  String id,
  int row,
  int col, {
  int rowSpan = 1,
  int colSpan = 1,
  String? label,
  String? iconName,
  DeckAction? action,
}) =>
    DeckButton(
      id: id,
      row: row,
      column: col,
      rowSpan: rowSpan,
      columnSpan: colSpan,
      label: label ?? id,
      iconName: iconName,
      action: action,
    );

void main() {
  group('SlotOps.moveSafely e colisões com botões grandes', () {
    test('move botão 2×1 para espaço livre e deslocando 1 coluna sobre si mesmo', () {
      final buttons = [
        _btn('wide', 0, 0, colSpan: 2, action: DeckAction(type: 'media')),
        _btn('solo', 1, 0),
      ];
      final shifted = SlotOps.moveSafely(
        buttons,
        (row: 0, column: 0),
        (row: 0, column: 1),
        rows: 2,
        columns: 4,
      );
      expect(shifted, isNotNull);
      expect(shifted!.length, 2);
      final movedWide = shifted.firstWhere((b) => b.id == 'wide');
      expect((movedWide.row, movedWide.column, movedWide.columnSpan), (0, 1, 2));
      expect(movedWide.action?.type, 'media');
    });

    test('troca botão 2×1 com dois botões 1×1 preservando todos os IDs e atributos', () {
      final buttons = [
        _btn('wide', 0, 0, colSpan: 2, label: 'Largo'),
        _btn('b1', 1, 0, label: 'Um', iconName: 'mic'),
        _btn('b2', 1, 1, label: 'Dois', iconName: 'volume_up'),
        _btn('stay', 1, 2, label: 'Fixo'),
      ];
      final swapped = SlotOps.moveSafely(
        buttons,
        (row: 0, column: 0),
        (row: 1, column: 0),
        rows: 2,
        columns: 4,
      );
      expect(swapped, isNotNull);
      expect(swapped!.map((b) => b.id).toSet(), {'wide', 'b1', 'b2', 'stay'});
      final byId = {for (final b in swapped) b.id: b};
      expect((byId['wide']!.row, byId['wide']!.column, byId['wide']!.columnSpan), (1, 0, 2));
      expect((byId['b1']!.row, byId['b1']!.column), (0, 0));
      expect((byId['b2']!.row, byId['b2']!.column), (0, 1));
      expect((byId['stay']!.row, byId['stay']!.column), (1, 2));
      expect(byId['b1']!.iconName, 'mic');
      expect(byId['b2']!.iconName, 'volume_up');
    });

    test('bloqueia soltar fora dos limites ou quando não há espaço para o deslocado', () {
      final buttons = [
        _btn('wide', 0, 0, colSpan: 2),
        _btn('a', 1, 0),
        _btn('b', 1, 1),
        _btn('c', 1, 2),
      ];
      // 2×1 na última coluna (col 3 em grade de 4 colunas) sairia da borda.
      expect(
        SlotOps.moveSafely(buttons, (row: 0, column: 0), (row: 0, column: 3), rows: 2, columns: 4),
        isNull,
      );
      expect(
        SlotOps.canDrop(buttons, (row: 0, column: 0), (row: 0, column: 3), rows: 2, columns: 4),
        isFalse,
      );
      // 1×1 em (1,0) tentando trocar com 2×1 em (0,0) quando (1,1) está ocupado por 'b'.
      expect(
        SlotOps.moveSafely(buttons, (row: 1, column: 0), (row: 0, column: 0), rows: 2, columns: 4),
        isNull,
      );
    });

    test('minGrid inclui botões com rowSpan e columnSpan', () {
      final buttons = [
        _btn('a', 0, 0),
        _btn('big', 1, 2, rowSpan: 2, colSpan: 2),
      ];
      expect(SlotOps.minGrid(buttons), (rows: 3, columns: 4));
    });

    test('moveGroup respeita a área ocupada por botões grandes', () {
      final buttons = [
        _btn('wide', 0, 0, colSpan: 2),
        _btn('stay', 0, 2),
      ];
      // Mover wide 1 coluna à direita bateria em stay (0,2).
      expect(
        SlotOps.moveGroup(buttons, {(row: 0, column: 0)}, 0, 1, 2, 4),
        isNull,
      );
      // Mover para baixo (1,0) cabe.
      final down = SlotOps.moveGroup(buttons, {(row: 0, column: 0)}, 1, 0, 2, 4);
      expect(down, isNotNull);
      expect(down!.firstWhere((b) => b.id == 'wide').row, 1);
    });
  });

  group('DeckGridFit com espaçamentos e limites responsivos', () {
    const phoneLand = Size(915, 412);
    const phoneLandArea = Size(850, 340);
    const phonePort = Size(412, 915);
    const phonePortArea = Size(376, 790);

    test('todos os níveis de espaçamento cabem na área em retrato e paisagem', () {
      for (final sp in DeckSpacing.values) {
        final land = DeckGridFit.compute(
          area: phoneLandArea,
          screen: phoneLand,
          shared: {'rows': 3, 'columns': 5},
          spacing: sp,
        );
        expect(
          land.cols * land.cell + (land.cols - 1) * land.spacing,
          lessThanOrEqualTo(phoneLandArea.width + 0.01),
        );
        expect(
          land.rows * land.cell + (land.rows - 1) * land.spacing,
          lessThanOrEqualTo(phoneLandArea.height + 0.01),
        );

        final port = DeckGridFit.compute(
          area: phonePortArea,
          screen: phonePort,
          shared: {'rows': 3, 'columns': 5},
          spacing: sp,
        );
        expect(
          port.cols * port.cell + (port.cols - 1) * port.spacing,
          lessThanOrEqualTo(phonePortArea.width + 0.01),
        );
      }
    });

    test('espaçamento compacto gera teclas maiores que amplo na mesma grade', () {
      final compact = DeckGridFit.compute(
        area: phoneLandArea,
        screen: phoneLand,
        shared: {'rows': 2, 'columns': 4},
        spacing: DeckSpacing.compact,
      );
      final spacious = DeckGridFit.compute(
        area: phoneLandArea,
        screen: phoneLand,
        shared: {'rows': 2, 'columns': 4},
        spacing: DeckSpacing.spacious,
      );
      expect(compact.cell, greaterThan(spacious.cell));
      expect(compact.spacing, lessThan(spacious.spacing));
    });
  });

  group('Persistência de preferências de layout no ThemeController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('salva e recarrega espaçamento, tamanho de ícone, nomes e grade manual', () async {
      final tc = ThemeController.instance;
      await tc.update(const ThemeSettings(
        spacing: DeckSpacing.compact,
        iconSize: DeckIconSize.large,
        showLabels: true,
      ));
      await tc.setCustomGrid((rows: 3, columns: 5));

      // Recarrega do SharedPreferences simulando reabertura do app.
      await tc.load();
      expect(tc.settings.value.spacing, DeckSpacing.compact);
      expect(tc.settings.value.iconSize, DeckIconSize.large);
      expect(tc.settings.value.showLabels, isTrue);
      expect(tc.customGrid.value, (rows: 3, columns: 5));

      // Voltar ao automático remove a grade manual.
      await tc.setCustomGrid(null);
      await tc.load();
      expect(tc.customGrid.value, isNull);
    });
  });

  group('DeckLayoutSheet: limites seguros, salvar e cancelar', () {
    setUp(() {
      GetIt.I.registerSingleton<SignalRService>(SignalRService());
      AppLanguage.choice.value = 'pt';
    });
    tearDown(() async {
      await GetIt.I.reset();
    });

    testWidgets('impede reduzir abaixo dos botões existentes e cancelar não devolve mudanças',
        (tester) async {
      final profile = DeckProfile(
        id: 'p1',
        name: 'Principal',
        rows: 3,
        columns: 4,
        buttons: [
          _btn('b1', 0, 0, label: 'Calc', iconName: 'apps'),
          _btn('b2', 1, 2, colSpan: 2, label: 'Largo', iconName: 'play_arrow'),
        ],
      );
      DeckLayoutResult? captured;

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  captured = await DeckLayoutSheet.show(
                    context,
                    profile: profile,
                    allProfiles: [profile],
                    initialRows: 2,
                    initialColumns: 4,
                    initialAutoGrid: false,
                    autoRows: 2,
                    autoColumns: 4,
                    allowAutoGrid: true,
                    initialSettings: const ThemeSettings(),
                  );
                },
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();

      // Aviso de mínimo 4×2 (por causa do botão 2×1 em (1,2)).
      expect(find.textContaining('4×2'), findsWidgets);

      // Tocar em 3×2 (menor que 4 colunas) não muda o valor.
      await tester.tap(find.text('3×2'));
      await tester.pumpAndSettle();

      // Escolhe 5×3 e Compacto, depois cancela → deve retornar null.
      await tester.tap(find.text('5×3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(captured, isNull);

      // Abre de novo, escolhe 5×3 + Compacto + Grande e salva.
      await tester.tap(find.text('Abrir'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5×3'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Compacto'));
      await tester.tap(find.text('Compacto'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Grande'));
      await tester.tap(find.text('Grande'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Salvar'));
      await tester.pumpAndSettle();

      expect(captured, isNotNull);
      expect((captured!.columns, captured!.rows, captured!.autoGrid), (5, 3, false));
      expect(captured!.spacing, DeckSpacing.compact);
      expect(captured!.iconSize, DeckIconSize.large);
    });
  });

  group('ButtonLook com texto grande de acessibilidade e botão largo 2×1', () {
    setUp(() => GetIt.I.registerSingleton<SignalRService>(SignalRService()));
    tearDown(GetIt.I.reset);

    testWidgets('não estoura com escala de texto 1.8x nem em botão 2×1', (tester) async {
      final btn = _btn(
        'wide',
        0,
        0,
        colSpan: 2,
        label: 'OBS Studio',
        iconName: 'videocam',
        action: DeckAction(type: 'hotkey'),
      );
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
        child: MaterialApp(
          theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
          home: Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 96,
                  height: 96,
                  child: DeckGridButton(button: btn, onTap: () {}, onLongPress: () {}),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: 220,
                  height: 96,
                  child: DeckGridButton(button: btn, onTap: () {}, onLongPress: () {}),
                ),
              ],
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('OBS Studio'), findsNWidgets(2));
    });
  });

  group('Modo de edição do celular: sem disparar ações, cancelar não salva parcial', () {
    late List<String> pressedButtons;
    late List<Map<String, dynamic>> savedProfiles;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      AppLanguage.choice.value = 'pt';
      pressedButtons = [];
      savedProfiles = [];

      final profileJson = jsonDecode(jsonEncode(DeckProfile(
        id: 'p1',
        name: 'Default',
        rows: 2,
        columns: 4,
        buttons: [
          _btn('b1', 0, 0, label: 'Um', iconName: 'mic', action: DeckAction(type: 'media')),
          _btn('b2', 0, 1, label: 'Dois', iconName: 'play_arrow', action: DeckAction(type: 'media')),
        ],
      ).toJson())) as Map<String, dynamic>;

      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/api/StreamDeck/profiles' && options.method == 'GET') {
            return handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: [profileJson],
            ));
          }
          if (options.path == '/api/StreamDeck/profiles' && options.method == 'POST') {
            savedProfiles.add(Map<String, dynamic>.from(options.data as Map));
            return handler.resolve(Response(requestOptions: options, statusCode: 200));
          }
          if (options.path == '/api/StreamDeck/press') {
            pressedButtons.add('${(options.data as Map)['buttonId']}');
            return handler.resolve(Response(requestOptions: options, statusCode: 200));
          }
          if (options.path == '/api/StreamDeck/layout') {
            return handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'rows': 2, 'columns': 4},
            ));
          }
          if (options.path == '/api/actions/schema') {
            return handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: const [],
            ));
          }
          return handler.resolve(Response(requestOptions: options, statusCode: 200, data: {}));
        },
      ));

      GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
      GetIt.I.registerSingleton<SignalRService>(SignalRService());
    });

    tearDown(() async {
      await ThemeController.instance.setCustomGrid(null);
      await GetIt.I.reset();
    });

    testWidgets('entrar na edição bloqueia ações, arrastar fica em rascunho e cancelar não salva',
        (tester) async {
      tester.view.physicalSize = const Size(900, 420);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
        home: StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: false),
      ));
      await tester.pumpAndSettle();

      // Fora da edição, tocar dispara a ação.
      await tester.tap(find.text('Um'));
      await tester.pumpAndSettle();
      expect(pressedButtons, ['b1']);

      // Entra no modo de edição pelo atalho visível no canto inferior direito.
      await tester.tap(find.byTooltip('Editar layout'));
      await tester.pumpAndSettle();
      expect(find.text('Modo de edição'), findsOneWidget);

      // Arrasta 'Um' (0,0) sobre 'Dois' (0,1) para trocar de lugar no rascunho.
      final start = tester.getCenter(find.text('Um'));
      final end = tester.getCenter(find.text('Dois'));
      final drag = await tester.startGesture(start);
      await tester.pump(const Duration(milliseconds: 50));
      await drag.moveTo(end);
      await tester.pump(const Duration(milliseconds: 50));
      await drag.up();
      await tester.pumpAndSettle();

      // Nenhuma ação disparada e nada salvo ainda no servidor.
      expect(pressedButtons, ['b1']);
      expect(savedProfiles, isEmpty);

      // Cancelar pede confirmação e descarta sem salvar.
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(find.text('Descartar alterações do layout?'), findsOneWidget);
      await tester.tap(find.text('Descartar'));
      await tester.pumpAndSettle();

      expect(savedProfiles, isEmpty);
      expect(find.text('Modo de edição'), findsNothing);

      // Entra de novo, arrasta para trocar, testa Desfazer, arrasta de novo e Salva.
      await tester.tap(find.byTooltip('Editar layout'));
      await tester.pumpAndSettle();

      Future<void> swapUmDois() async {
        final s = tester.getCenter(find.text('Um'));
        final e = tester.getCenter(find.text('Dois'));
        final g = await tester.startGesture(s);
        await tester.pump(const Duration(milliseconds: 50));
        await g.moveTo(e);
        await tester.pump(const Duration(milliseconds: 50));
        await g.up();
        await tester.pumpAndSettle();
      }

      await swapUmDois();
      // Desfaz o movimento no rascunho.
      await tester.tap(find.byTooltip('Desfazer'));
      await tester.pumpAndSettle();
      expect(savedProfiles, isEmpty);

      // Troca novamente e salva.
      await swapUmDois();
      await tester.tap(find.text('Salvar').first);
      await tester.pumpAndSettle();

      expect(savedProfiles, hasLength(1));
      final savedBtns = (savedProfiles.single['buttons'] as List).cast<DeckButton>();
      final byId = {for (final b in savedBtns) b.id: (b.row, b.column)};
      expect(byId['b1'], (0, 1));
      expect(byId['b2'], (0, 0));
    });

    testWidgets('modo de edição em retrato com texto 1.8x não estoura barra nem pílula',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          textScaler: TextScaler.linear(1.8),
        ),
        child: MaterialApp(
          theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
          home: StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: false),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Editar layout'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Modo de edição'), findsOneWidget);
    });

    testWidgets('grade automática não reporta 5×3 ao abrir página com botão em (2,4)',
        (tester) async {
      await GetIt.I.reset();
      SharedPreferences.setMockInitialValues({});
      await ThemeController.instance.setCustomGrid(null);

      final reportedLayouts = <(int, int)>[];
      final bigPage = jsonDecode(jsonEncode(DeckProfile(
        id: 'kbd',
        name: 'Teclado',
        rows: 3,
        columns: 5,
        buttons: [
          _btn('k1', 0, 0, label: 'F1'),
          _btn('k2', 2, 4, label: 'Voltar'),
        ],
      ).toJson())) as Map<String, dynamic>;

      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path == '/api/StreamDeck/profiles' && options.method == 'GET') {
            return handler.resolve(Response(requestOptions: options, statusCode: 200, data: [bigPage]));
          }
          if (options.path == '/api/StreamDeck/layout' && options.method == 'POST') {
            final body = options.data as Map;
            reportedLayouts.add((body['rows'] as int, body['columns'] as int));
            return handler.resolve(Response(requestOptions: options, statusCode: 200, data: body));
          }
          if (options.path == '/api/StreamDeck/layout' && options.method == 'GET') {
            return handler.resolve(Response(requestOptions: options, statusCode: 200, data: {'rows': 2, 'columns': 4}));
          }
          if (options.path == '/api/actions/schema') {
            return handler.resolve(Response(requestOptions: options, statusCode: 200, data: const []));
          }
          return handler.resolve(Response(requestOptions: options, statusCode: 200, data: {}));
        },
      ));
      GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
      GetIt.I.registerSingleton<SignalRService>(SignalRService());

      tester.view.physicalSize = const Size(915, 412);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
        home: StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: false),
      ));
      await tester.pumpAndSettle();

      // Todos os botões da página 5×3 continuam visíveis, mas a grade automática reportada
      // ao PC permanece a natural da tela (4×2), sem virar 5×3 manual.
      expect(find.text('F1'), findsOneWidget);
      expect(find.text('Voltar'), findsOneWidget);
      expect(ThemeController.instance.customGrid.value, isNull);
      for (final (r, c) in reportedLayouts) {
        expect((r, c), isNot((3, 5)));
      }
    });

    testWidgets(
        'remove atalhos da faixa inferior, esconde controles após 5s sem mover teclas, revela ao tocar área livre ou teclado e pausa em edição/folhas',
        (tester) async {
      tester.view.physicalSize = const Size(900, 420);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var reportedChrome = true;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
        home: StreamDeckPage(
          onToggleFullscreen: () {},
          isFullscreen: false,
          onChromeVisibilityChanged: (v) => reportedChrome = v,
        ),
      ));
      await tester.pumpAndSettle();

      // Apenas um botão "Layout da grade" e um "Editar layout" (ambos na barra superior,
      // nenhum na faixa inferior).
      expect(find.byTooltip('Layout da grade'), findsOneWidget);
      expect(find.byTooltip('Editar layout'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('deck-bottom-strip')),
          matching: find.byTooltip('Layout da grade'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('deck-bottom-strip')),
          matching: find.byTooltip('Editar layout'),
        ),
        findsNothing,
      );

      final tilePosBefore = tester.getTopLeft(find.text('Um'));

      // Após 3 s com interação genuína, o temporizador reinicia e os controles continuam visíveis.
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.text('Um'));
      await tester.pump(const Duration(seconds: 3));
      expect(reportedChrome, isTrue);
      expect(
        tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('deck-top-chrome'))).opacity,
        1.0,
      );

      // Após 5 s completos sem interação, topo e rodapé recolhem sem mover as teclas.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(reportedChrome, isFalse);
      expect(
        tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('deck-top-chrome'))).opacity,
        0.0,
      );
      expect(
        tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('deck-bottom-strip'))).opacity,
        0.0,
      );
      expect(tester.getTopLeft(find.text('Um')), tilePosBefore);

      // Com os controles escondidos, tocar numa tecla dispara a ação sem piscar os controles.
      final countBefore = pressedButtons.length;
      await tester.tap(find.text('Dois'));
      await tester.pumpAndSettle();
      expect(pressedButtons.length, countBefore + 1);
      expect(reportedChrome, isFalse);

      // Tocar numa área livre (canto inferior direito sem teclas) revela os controles.
      await tester.tapAt(const Offset(880, 390));
      await tester.pumpAndSettle();
      expect(reportedChrome, isTrue);
      expect(
        tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('deck-top-chrome'))).opacity,
        1.0,
      );

      // Abrir o painel de Layout da grade pausa o recolhimento automático.
      await tester.tap(find.byTooltip('Layout da grade'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 8));
      expect(reportedChrome, isTrue);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      // Entrar em modo de edição também pausa o recolhimento automático.
      await tester.tap(find.byTooltip('Editar layout'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 8));
      expect(reportedChrome, isTrue);
      expect(find.text('Modo de edição'), findsOneWidget);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();

      // Depois de sair da edição, volta a esconder após 5 s.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(reportedChrome, isFalse);

      // Tecla Escape revela os controles novamente.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(reportedChrome, isTrue);
    });
  });
}
