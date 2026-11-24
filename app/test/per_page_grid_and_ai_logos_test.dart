import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/ai_limits/ai_limits_client.dart';
import 'package:deckos/src/ai_limits/ai_limits_store.dart';
import 'package:deckos/src/ai_limits/ai_provider_icon.dart';
import 'package:deckos/src/ai_limits/ai_provider_style.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/layout/grid_placement.dart';
import 'package:deckos/src/stream_deck/layout/slot_ops.dart';
import 'package:deckos/src/stream_deck/stream_deck_controller.dart';
import 'package:deckos/src/stream_deck/stream_deck_page.dart';
import 'package:deckos/src/stream_deck/widgets/deck_layout_sheet.dart';
import 'package:deckos/src/stream_deck/widgets/dynamic_deck_button.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

DeckButton _btn(
  String id,
  int row,
  int col, {
  int colSpan = 1,
  int rowSpan = 1,
  String? label,
  String? dynamicType,
  Map<String, String>? dynamicParameters,
  DeckAction? action,
}) =>
    DeckButton(
      id: id,
      row: row,
      column: col,
      columnSpan: colSpan,
      rowSpan: rowSpan,
      label: label ?? id,
      iconName: dynamicType == null ? 'play_arrow' : null,
      dynamicType: dynamicType,
      dynamicParameters: dynamicParameters,
      action: action,
    );

void main() {
  group('AI Provider Brand Marks & Monogram Fallbacks', () {
    test('all bundled official SVG marks parse cleanly within 24x24 viewBox', () {
      const officialKinds = [
        AiProviderMarkKind.openai,
        AiProviderMarkKind.claude,
        AiProviderMarkKind.gemini,
        AiProviderMarkKind.antigravity,
        AiProviderMarkKind.copilot,
        AiProviderMarkKind.cursor,
        AiProviderMarkKind.windsurf,
      ];
      for (final kind in officialKinds) {
        final path = providerMarkPath(kind);
        expect(path, isNotNull, reason: 'Missing path for $kind');
        final bounds = path!.getBounds();
        expect(bounds.width, greaterThan(10), reason: 'Too narrow for $kind: $bounds');
        expect(bounds.height, greaterThan(10), reason: 'Too short for $kind: $bounds');
        expect(bounds.left, greaterThanOrEqualTo(-1.5), reason: 'Left out of viewBox for $kind: $bounds');
        expect(bounds.top, greaterThanOrEqualTo(-1.5), reason: 'Top out of viewBox for $kind: $bounds');
        expect(bounds.right, lessThanOrEqualTo(25.5), reason: 'Right out of viewBox for $kind: $bounds');
        expect(bounds.bottom, lessThanOrEqualTo(25.5), reason: 'Bottom out of viewBox for $kind: $bounds');
      }
    });

    testWidgets('tiles render real brand marks (not generic </> or rocket) across light/dark and 2x font scale',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      AppLanguage.choice.value = 'en';
      PcStore.currentId = 'pc_logo';

      final snap = {
        'schemaVersion': 1,
        'generatedAt': DateTime.now().toUtc().toIso8601String(),
        'capabilities': {'platform': 'windows', 'detected': {}, 'supportedSourceKinds': []},
        'refresh': {'cooldownSeconds': 15, 'autoRefreshIntervalSeconds': 180},
        'sources': [
          {'id': 'src_cpa', 'kind': 'cliproxy_passive', 'label': 'CLIProxyAPI', 'status': 'connected'},
        ],
        'accounts': [
          {
            'id': 'acct_codex',
            'sourceId': 'src_cpa',
            'sourceKind': 'cliproxy_passive',
            'provider': 'codex',
            'providerLabel': 'Codex',
            'alias': 'Codex #1',
            'enabled': true,
            'connectionStatus': 'connected',
            'quotaStatus': 'ok',
            'freshness': 'fresh',
            'windows': [
              {'id': 'w1', 'kind': 'five_hour', 'label': '5h', 'unit': 'percent', 'status': 'available', 'usedPercent': 22, 'remainingPercent': 78},
            ],
          },
          {
            'id': 'acct_claude',
            'sourceId': 'src_cpa',
            'sourceKind': 'cliproxy_passive',
            'provider': 'claude',
            'providerLabel': 'Claude',
            'alias': 'Personal',
            'enabled': true,
            'connectionStatus': 'connected',
            'quotaStatus': 'ok',
            'freshness': 'fresh',
            'windows': [
              {'id': 'w1', 'kind': 'five_hour', 'label': '5h', 'unit': 'percent', 'status': 'available', 'usedPercent': 40, 'remainingPercent': 60},
            ],
          },
          {
            'id': 'acct_ag',
            'sourceId': 'src_cpa',
            'sourceKind': 'cliproxy_passive',
            'provider': 'antigravity',
            'providerLabel': 'Antigravity',
            'alias': 'AG #1',
            'enabled': true,
            'connectionStatus': 'connected',
            'quotaStatus': 'unavailable',
            'freshness': 'unavailable',
            'windows': [],
          },
          {
            'id': 'acct_gemini',
            'sourceId': 'src_cpa',
            'sourceKind': 'cliproxy_passive',
            'provider': 'gemini_cli',
            'providerLabel': 'Gemini CLI',
            'alias': 'Gemini #1',
            'enabled': true,
            'connectionStatus': 'connected',
            'quotaStatus': 'ok',
            'freshness': 'local_only',
            'windows': [
              {'id': 'w1', 'kind': 'daily', 'label': 'Daily', 'unit': 'requests', 'status': 'available', 'used': 12, 'limit': 1000},
            ],
          },
          {
            'id': 'acct_devin',
            'sourceId': 'src_cpa',
            'sourceKind': 'cliproxy_passive',
            'provider': 'devin',
            'providerLabel': 'Devin',
            'alias': 'Team',
            'enabled': true,
            'connectionStatus': 'connected',
            'quotaStatus': 'unavailable',
            'freshness': 'unavailable',
            'windows': [],
          },
        ],
      };

      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
        if (o.path == '/api/ai-limits') {
          return h.resolve(Response(requestOptions: o, statusCode: 200, data: snap));
        }
        return h.resolve(Response(requestOptions: o, statusCode: 200, data: const []));
      }));
      final client = DeckOSClient(baseUrl: 'http://localhost', dio: dio);
      GetIt.I.registerSingleton<DeckOSClient>(client);
      GetIt.I.registerSingleton<SignalRService>(SignalRService());
      AiLimitsStore.resetForTest(client: AiLimitsClient(client));
      addTearDown(() async {
        AiLimitsStore.resetForTest();
        await GetIt.I.reset();
        PcStore.currentId = null;
      });
      await tester.runAsync(() => AiLimitsStore.instance.load());

      for (final brightness in [Brightness.light, Brightness.dark]) {
        await tester.pumpWidget(MediaQuery(
          data: const MediaQueryData(
            size: Size(900, 900),
            textScaler: TextScaler.linear(2.0),
          ),
          child: MaterialApp(
            theme: buildAppTheme(const ThemeSettings(), brightness),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final id in ['acct_codex', 'acct_claude', 'acct_ag', 'acct_gemini', 'acct_devin'])
                      SizedBox(
                        width: 340,
                        height: 155,
                        child: DynamicDeckButton(
                          button: _btn(
                            'tile_$id',
                            0,
                            0,
                            colSpan: 2,
                            dynamicType: aiLimitsDynamicType,
                            dynamicParameters: {'accountId': id},
                          ),
                          onTap: () {},
                          onLongPress: () {},
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('ai-brand-mark-openai')), findsOneWidget);
        expect(find.byKey(const ValueKey('ai-brand-mark-claude')), findsOneWidget);
        expect(find.byKey(const ValueKey('ai-brand-mark-antigravity')), findsOneWidget);
        expect(find.byKey(const ValueKey('ai-brand-mark-gemini')), findsOneWidget);
        expect(find.byKey(const ValueKey('ai-brand-monogram-devin')), findsOneWidget);
        // Generic placeholders must not be used for Codex or Antigravity.
        expect(find.byIcon(CupertinoIcons.chevron_left_slash_chevron_right), findsNothing);
        expect(find.byIcon(CupertinoIcons.rocket_fill), findsNothing);
      }
    });

    testWidgets('AiSourceKindBadge keeps CLIProxyAPI distinct from provider brand marks',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: const [
              AiSourceKindBadge(kind: 'cliproxy_passive', color: Colors.blue, dark: true),
              AiSourceKindBadge(kind: 'codex_local', color: Colors.green, dark: true),
              AiSourceKindBadge(kind: 'claude_statusline', color: Colors.orange, dark: true),
              AiSourceKindBadge(kind: 'gemini_local_otel', color: Colors.indigo, dark: true),
            ],
          ),
        ),
      ));
      expect(find.byIcon(Icons.lan_rounded), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-brand-mark-openai')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-brand-mark-claude')), findsOneWidget);
      expect(find.byKey(const ValueKey('ai-brand-mark-gemini')), findsOneWidget);
    });
  });

  group('Per-Page Grid Model, Orientation & Non-Destructive Fit', () {
    test('DeckProfile JSON round-trip preserves customRows/customColumns and null inherit', () {
      final inherited = DeckProfile(id: 'p1', name: 'Default', rows: 3, columns: 4);
      final inheritedJson = inherited.toJson();
      expect(inheritedJson.containsKey('customRows'), isFalse);
      expect(inheritedJson.containsKey('customColumns'), isFalse);
      final parsedInherited = DeckProfile.fromJson(inheritedJson);
      expect(parsedInherited.hasCustomGrid, isFalse);
      expect(parsedInherited.customGrid, isNull);

      final custom = inherited.withCustomGrid((rows: 3, columns: 2));
      expect(custom.hasCustomGrid, isTrue);
      expect(custom.customGrid, (rows: 3, columns: 2));
      final parsedCustom = DeckProfile.fromJson(jsonDecode(jsonEncode(custom.toJson())) as Map<String, dynamic>);
      expect(parsedCustom.hasCustomGrid, isTrue);
      expect(parsedCustom.customGrid, (rows: 3, columns: 2));

      // copyWith preserves override by default; withCustomGrid(null) clears back to inherit.
      expect(parsedCustom.copyWith(name: 'Renamed').customGrid, (rows: 3, columns: 2));
      expect(parsedCustom.withCustomGrid(null).hasCustomGrid, isFalse);
    });

    test('SlotOps.planGridFit never drops buttons, bindings, or creates overlap', () {
      final buttons = [
        _btn(
          'a1',
          0,
          0,
          colSpan: 2,
          dynamicType: aiLimitsDynamicType,
          dynamicParameters: {'accountId': 'acct_1', 'provider': 'codex'},
        ),
        _btn(
          'a2',
          0,
          2,
          colSpan: 2,
          dynamicType: aiLimitsDynamicType,
          dynamicParameters: {'accountId': 'acct_2', 'provider': 'claude'},
        ),
        _btn(
          'a3',
          1,
          0,
          colSpan: 2,
          dynamicType: aiLimitsDynamicType,
          dynamicParameters: {'accountId': 'acct_3', 'provider': 'antigravity'},
        ),
      ];

      // 3 wide 2x1 tiles fit into 2x3 after rearranging (rows=3, cols=2).
      final reflowPlan = SlotOps.planGridFit(buttons, rows: 3, columns: 2);
      expect(reflowPlan.status, GridFitStatus.needsReflow);
      expect(reflowPlan.buttons, hasLength(3));
      expect(reflowPlan.buttons.map((b) => b.id).toSet(), {'a1', 'a2', 'a3'});
      expect(
        reflowPlan.buttons.firstWhere((b) => b.id == 'a2').dynamicParameters?['accountId'],
        'acct_2',
      );
      final layout = GridLayout.of(reflowPlan.buttons, 3, 2);
      expect(layout.placements, hasLength(3));

      // Trying to squeeze 3 wide tiles into 2x2 needs expansion to 2x3 (zero loss).
      final expandPlan = SlotOps.planGridFit(buttons, rows: 2, columns: 2);
      expect(expandPlan.status, GridFitStatus.needsExpandAndReflow);
      expect((expandPlan.requiredColumns, expandPlan.requiredRows), (2, 3));
      expect(expandPlan.buttons, hasLength(3));
    });

    test('DeckGridFit honors explicit per-page grid in portrait without forced flip, and reflows only if too narrow',
        () {
      const portScreen = Size(411, 919);
      const portArea = Size(379, 790);

      // User explicitly picked 3x2 for a single page in portrait: cells are ~115dp (>= 72dp) -> honor 3x2 directly.
      final exact = DeckGridFit.compute(
        area: portArea,
        screen: portScreen,
        shared: {'rows': 2, 'columns': 3},
        explicitPageGrid: true,
      );
      expect((exact.cols, exact.rows, exact.reflow), (3, 2, false));
      expect(exact.cell, greaterThanOrEqualTo(DeckGridFit.minCell));

      // User picked 8x2 on landscape, then rotated to narrow portrait: 8 cols would be <72dp -> gracefully reflows.
      final narrow = DeckGridFit.compute(
        area: portArea,
        screen: portScreen,
        shared: {'rows': 2, 'columns': 8},
        explicitPageGrid: true,
      );
      expect(narrow.reflow, isTrue);
      expect(narrow.cols, lessThan(8));
      expect(narrow.cell, greaterThanOrEqualTo(DeckGridFit.minCell));
    });
  });

  group('Per-Page Grid UI Flows: Isolation, Persistence, Reset, Actionable Reflow, Edit Mode', () {
    late List<Map<String, dynamic>> serverProfiles;
    late Map<String, int> serverGlobalLayout;
    late int globalLayoutSaves;

    void setupMockServer() {
      SharedPreferences.setMockInitialValues({});
      StreamDeckController.clearMemoryCacheForTest();
      AppLanguage.choice.value = 'en';
      globalLayoutSaves = 0;
      serverGlobalLayout = {'rows': 2, 'columns': 4};
      serverProfiles = [
        jsonDecode(jsonEncode(DeckProfile(
          id: 'media',
          name: 'Media Controls',
          rows: 2,
          columns: 4,
          buttons: [
            _btn('m1', 0, 0, label: 'Play', action: DeckAction(type: 'media')),
            _btn('m2', 0, 1, label: 'Next', action: DeckAction(type: 'media')),
            _btn('m3', 0, 2, label: 'Prev', action: DeckAction(type: 'media')),
            _btn('m4', 0, 3, label: 'Mute', action: DeckAction(type: 'media')),
          ],
        ).toJson())) as Map<String, dynamic>,
        jsonDecode(jsonEncode(DeckProfile(
          id: 'other',
          name: 'Default',
          rows: 2,
          columns: 4,
          buttons: [
            _btn('d1', 0, 0, label: 'Calc', action: DeckAction(type: 'media')),
            _btn('d2', 0, 1, label: 'Notes', action: DeckAction(type: 'media')),
          ],
        ).toJson())) as Map<String, dynamic>,
      ];

      final dio = Dio();
      dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
        if (options.path == '/api/StreamDeck/profiles' && options.method == 'GET') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: serverProfiles.map((e) => Map<String, dynamic>.from(e)).toList(),
          ));
        }
        if (options.path == '/api/StreamDeck/profiles' && options.method == 'POST') {
          final incoming = jsonDecode(jsonEncode(options.data)) as Map<String, dynamic>;
          final idx = serverProfiles.indexWhere((p) => p['id'] == incoming['id']);
          if (idx >= 0) {
            serverProfiles[idx] = incoming;
          } else {
            serverProfiles.add(incoming);
          }
          return handler.resolve(Response(requestOptions: options, statusCode: 200));
        }
        if (options.path == '/api/StreamDeck/layout' && options.method == 'GET') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: Map<String, int>.from(serverGlobalLayout),
          ));
        }
        if (options.path == '/api/StreamDeck/layout' && options.method == 'POST') {
          globalLayoutSaves++;
          final body = Map<String, dynamic>.from(options.data as Map);
          serverGlobalLayout = {
            'rows': body['rows'] as int,
            'columns': body['columns'] as int,
          };
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: serverGlobalLayout,
          ));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: const []));
      }));

      GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
      GetIt.I.registerSingleton<SignalRService>(SignalRService());
    }

    tearDown(() async {
      await ThemeController.instance.setCustomGrid(null);
      StreamDeckController.clearMemoryCacheForTest();
      await GetIt.I.reset();
    });

    testWidgets(
        'adjusting single page grid via overflow menu isolates page, offers actionable reflow, persists across reload, and resets to global',
        (tester) async {
      setupMockServer();
      tester.view.physicalSize = const Size(411, 919);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
        home: StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: false),
      ));
      await tester.pumpAndSettle();
      final globalSavesAfterStartup = globalLayoutSaves;

      // Open overflow menu -> Page grid (opens directly on "This page" scope).
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      expect(find.text('Page grid'), findsOneWidget);
      await tester.tap(find.text('Page grid'));
      await tester.pumpAndSettle();

      expect(find.text('Grid for "Media Controls"'), findsOneWidget);

      // Select 2x2 for Media Controls (which currently has 4 buttons in 4x1 -> triggers non-destructive fit notice + dialog).
      await tester.tap(find.text('2×2'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('page-grid-fit-notice')), findsOneWidget);

      // Tap Save -> actionable rearrange dialog appears; choose "Rearrange & save".
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Rearrange tiles to fit 2×2?'), findsOneWidget);
      await tester.tap(find.text('Rearrange & save'));
      await tester.pumpAndSettle();

      // Verify ONLY Media Controls got customRows=2, customColumns=2; Default untouched; global untouched!
      final savedMedia = serverProfiles.firstWhere((p) => p['id'] == 'media');
      final savedOther = serverProfiles.firstWhere((p) => p['id'] == 'other');
      expect(savedMedia['customRows'], 2);
      expect(savedMedia['customColumns'], 2);
      expect((savedMedia['buttons'] as List).length, 4);
      expect(savedOther['customRows'], isNull);
      expect(savedOther['customColumns'], isNull);
      expect(globalLayoutSaves, globalSavesAfterStartup);

      // Simulate restart/reload by clearing memory cache and pumping a fresh StreamDeckPage.
      StreamDeckController.clearMemoryCacheForTest();
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
        home: StreamDeckPage(
          key: const ValueKey('reloaded-deck'),
          onToggleFullscreen: () {},
          isFullscreen: false,
        ),
      ));
      await tester.pumpAndSettle();

      // All 4 tiles still visible after reload.
      for (final label in ['Play', 'Next', 'Prev', 'Mute']) {
        expect(find.text(label), findsOneWidget);
      }

      // Open layout sheet again -> auto-selects "This page" because override exists -> reset to global!
      await tester.tap(find.byTooltip('Grid layout'));
      await tester.pumpAndSettle();
      expect(find.text('Grid for "Media Controls"'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('page-grid-reset-row')));
      await tester.tap(find.byKey(const ValueKey('page-grid-reset-row')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      final resetMedia = serverProfiles.firstWhere((p) => p['id'] == 'media');
      expect(resetMedia['customRows'], isNull);
      expect(resetMedia['customColumns'], isNull);
      expect((resetMedia['buttons'] as List).length, 4);
    });

    testWidgets('DeckLayoutSheet This page scope renders cleanly at 1.8x font scale with zero overflow',
        (tester) async {
      GetIt.I.registerSingleton<SignalRService>(SignalRService());
      AppLanguage.choice.value = 'en';
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final profile = DeckProfile(
        id: 'p_large',
        name: 'AI Usage',
        customRows: 3,
        customColumns: 2,
        buttons: [_btn('b1', 0, 0, label: 'One'), _btn('b2', 0, 1, label: 'Two')],
      );

      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(
          size: Size(390, 844),
          textScaler: TextScaler.linear(1.8),
        ),
        child: MaterialApp(
          theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () => DeckLayoutSheet.show(
                  context,
                  profile: profile,
                  allProfiles: [profile],
                  initialRows: 2,
                  initialColumns: 4,
                  initialAutoGrid: true,
                  autoRows: 2,
                  autoColumns: 4,
                  allowAutoGrid: true,
                  initialSettings: const ThemeSettings(),
                  initialScope: DeckGridScope.thisPage,
                  initialPageGrid: profile.customGrid,
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Grid for "AI Usage"'), findsOneWidget);
      expect(find.text('Use global grid'), findsOneWidget);
    });

    testWidgets('Edit mode per-page grid change discards on Cancel and persists on Save',
        (tester) async {
      setupMockServer();
      tester.view.physicalSize = const Size(900, 420);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
        home: StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: false),
      ));
      await tester.pumpAndSettle();

      // Enter Edit Mode, open layout sheet, switch to This page, pick 5x3, save sheet -> still in edit draft!
      await tester.tap(find.byTooltip('Edit layout'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Grid layout'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('This page'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('5×3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5×3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // Not persisted yet until Edit Mode Save!
      expect(serverProfiles.firstWhere((p) => p['id'] == 'media')['customColumns'], isNull);

      // Cancel Edit Mode -> discard -> still not persisted.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();
      expect(serverProfiles.firstWhere((p) => p['id'] == 'media')['customColumns'], isNull);

      // Repeat and Save Edit Mode -> persisted!
      await tester.tap(find.byTooltip('Edit layout'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Grid layout'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('This page'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('5×3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5×3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save').first);
      await tester.pumpAndSettle();

      final saved = serverProfiles.firstWhere((p) => p['id'] == 'media');
      expect(saved['customColumns'], 5);
      expect(saved['customRows'], 3);
      expect(serverProfiles.firstWhere((p) => p['id'] == 'other')['customColumns'], isNull);
    });
  });
}
