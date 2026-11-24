// Revamp tests for live AI Limits deck tiles, responsive portrait/landscape grid
// sizing, default 2×1 new-tile span, and streamlined provider-first onboarding.
// Optional SCREENS_OUT captures are fixture design QA only, never live phone proof.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:deckos/core/core.dart';
import 'package:deckos/src/ai_limits/ai_limits_client.dart';
import 'package:deckos/src/ai_limits/ai_limits_settings_page.dart';
import 'package:deckos/src/ai_limits/ai_limits_store.dart';
import 'package:deckos/src/ai_limits/ai_provider_style.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/home/home_page.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/stream_deck_page.dart';
import 'package:deckos/src/stream_deck/widgets/button_property_panel.dart';
import 'package:deckos/src/stream_deck/widgets/dynamic_deck_button.dart';
import 'package:deckos/src/stream_deck/widgets/editor/info_section.dart';
import 'package:deckos/src/stream_deck/widgets/usage_bars.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _screensOut = String.fromEnvironment('SCREENS_OUT', defaultValue: '');

Future<void> _loadFont(String family, String asset) async {
  try {
    await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
  } catch (_) {}
}

String _inHours(double h) =>
    DateTime.now().toUtc().add(Duration(minutes: (h * 60).round())).toIso8601String();

Map<String, dynamic> _win(
  String id,
  String kind, {
  double? used,
  String status = 'available',
  String? resetsAt,
  String unit = 'percent',
  double? usedCount,
  double? limit,
  String? pool,
  bool? ordinaryUsageAllowed,
}) =>
    {
      'id': id,
      'kind': kind,
      'label': kind == 'five_hour' ? '5h' : (kind == 'weekly' ? 'Weekly' : kind),
      'unit': unit,
      'status': status,
      'usedPercent': used,
      'remainingPercent': used == null ? null : 100 - used,
      'used': usedCount,
      'limit': limit,
      'resetsAt': resetsAt,
      'modelPool': pool,
      'ordinaryUsageAllowed': ordinaryUsageAllowed,
    };

Map<String, dynamic> _revampSnapshot({bool includeExistingCodex = true}) => {
      'schemaVersion': 1,
      'generatedAt': DateTime.now().toUtc().toIso8601String(),
      'capabilities': {
        'platform': 'windows',
        'claudeStatusLineInstallerAvailable': true,
        'detected': {
          'cliProxySuggestedUrl': 'http://127.0.0.1:8317',
          'cliProxyReachable': true,
          'codexCliAvailable': true,
          'codexDefaultHomeExists': true,
          'claudeCliAvailable': true,
          'claudeConfigDirExists': true,
          'claudeStatusLineConfigured': false,
          'geminiDirExists': true,
        },
        'supportedSourceKinds': [
          {
            'kind': 'codex_local',
            'title': 'OpenAI Codex (Official Local)',
            'description': 'Official local Codex app-server RPC.',
            'accessMode': 'official_local_rpc',
            'requiresCredential': false,
            'supportsMultiAccount': true,
            'supportsTestConnection': true,
          },
          {
            'kind': 'claude_statusline',
            'title': 'Claude Code (statusLine Hook)',
            'description': 'Passive official statusLine snapshot.',
            'accessMode': 'official_local_hook',
            'requiresCredential': false,
            'supportsGuidedSetup': true,
            'supportsTestConnection': true,
          },
          {
            'kind': 'cliproxy_passive',
            'title': 'CLIProxyAPI (Passive Local)',
            'description': 'Passive headers from local CLIProxyAPI.',
            'accessMode': 'passive_local_proxy',
            'requiresCredential': true,
            'supportsMultiAccount': true,
            'supportsTestConnection': true,
          },
          {
            'kind': 'manual_dashboard',
            'title': 'Official Dashboard Link',
            'description': 'Manual shortcut card.',
            'accessMode': 'manual_dashboard',
            'requiresCredential': false,
            'supportsTestConnection': false,
          },
        ],
      },
      'refresh': {'cooldownSeconds': 15, 'autoRefreshIntervalSeconds': 180},
      'sources': includeExistingCodex
          ? [
              {
                'id': 'src_codex',
                'kind': 'codex_local',
                'label': 'Codex on this PC',
                'status': 'connected',
                'accountCount': 1,
              },
              {
                'id': 'src_cpa',
                'kind': 'cliproxy_passive',
                'label': 'Local CLIProxyAPI',
                'baseUrl': 'http://127.0.0.1:8317',
                'hasCredential': true,
                'status': 'connected',
                'accountCount': 6,
              },
            ]
          : const [],
      'accounts': [
        {
          'id': 'acct_codex_pc',
          'sourceId': 'src_codex',
          'sourceKind': 'codex_local',
          'provider': 'codex',
          'providerLabel': 'Codex',
          'alias': 'Codex on this PC',
          'plan': 'Plus',
          'enabled': true,
          'connectionStatus': 'connected',
          'quotaStatus': 'ok',
          'freshness': 'fresh',
          'observedAt': DateTime.now().toUtc().toIso8601String(),
          'windows': [
            _win('five_hour', 'five_hour', used: 3, resetsAt: _inHours(2.9)),
            _win('weekly', 'weekly', used: 55, resetsAt: _inHours(96)),
          ],
        },
        {
          'id': 'acct_codex_429_with_bars',
          'sourceId': 'src_cpa',
          'sourceKind': 'cliproxy_passive',
          'provider': 'codex',
          'providerLabel': 'Codex',
          'alias': 'Codex #3',
          'plan': 'Plus',
          'enabled': true,
          'connectionStatus': 'connected',
          'quotaStatus': 'rate_limited',
          'freshness': 'fresh',
          'ordinaryUsageAllowed': false,
          'windows': [
            _win('five_hour', 'five_hour',
                used: 100, status: 'available', resetsAt: _inHours(2.4), ordinaryUsageAllowed: false),
            _win('weekly', 'weekly', used: 54, status: 'available', resetsAt: _inHours(118)),
          ],
        },
        {
          'id': 'acct_claude_wait',
          'sourceId': 'src_cpa',
          'sourceKind': 'cliproxy_passive',
          'provider': 'claude',
          'providerLabel': 'Claude',
          'alias': 'Claude #1',
          'enabled': true,
          'connectionStatus': 'connected',
          'quotaStatus': 'awaiting_data',
          'freshness': 'unavailable',
          'dashboardUrl': 'https://claude.ai/settings/usage',
          'windows': [
            _win('five_hour', 'five_hour', status: 'unavailable'),
            _win('weekly', 'weekly', status: 'unavailable'),
          ],
        },
        {
          'id': 'acct_ag_unavail',
          'sourceId': 'src_cpa',
          'sourceKind': 'cliproxy_passive',
          'provider': 'antigravity',
          'providerLabel': 'Antigravity',
          'alias': 'Antigravity #1',
          'enabled': true,
          'connectionStatus': 'connected',
          'quotaStatus': 'unavailable',
          'freshness': 'unavailable',
          'dashboardUrl': 'https://antigravity.google/docs/plans',
          'windows': [
            _win('five_hour', 'five_hour', status: 'unavailable'),
            _win('weekly', 'weekly', status: 'unavailable'),
          ],
        },
        {
          'id': 'acct_claude_live',
          'sourceId': 'src_cpa',
          'sourceKind': 'cliproxy_passive',
          'provider': 'claude',
          'providerLabel': 'Claude',
          'alias': 'Personal',
          'plan': 'Max',
          'enabled': true,
          'connectionStatus': 'connected',
          'quotaStatus': 'ok',
          'freshness': 'fresh',
          'observedAt': DateTime.now().toUtc().toIso8601String(),
          'windows': [
            _win('five_hour', 'five_hour', used: 78, resetsAt: _inHours(1.2)),
            _win('weekly', 'weekly', used: 34, resetsAt: _inHours(84)),
          ],
        },
        {
          'id': 'acct_codex_stale',
          'sourceId': 'src_cpa',
          'sourceKind': 'cliproxy_passive',
          'provider': 'codex',
          'providerLabel': 'Codex',
          'alias': 'Codex #1',
          'plan': 'Plus',
          'enabled': true,
          'connectionStatus': 'connected',
          'quotaStatus': 'stale',
          'freshness': 'stale',
          'windows': [
            _win('five_hour', 'five_hour', used: 11, status: 'stale'),
            _win('weekly', 'weekly', used: 8, status: 'stale'),
          ],
        },
        {
          'id': 'acct_codex_2',
          'sourceId': 'src_cpa',
          'sourceKind': 'cliproxy_passive',
          'provider': 'codex',
          'providerLabel': 'Codex',
          'alias': 'Codex #2',
          'enabled': true,
          'connectionStatus': 'connected',
          'quotaStatus': 'awaiting_data',
          'freshness': 'unavailable',
          'windows': [
            _win('five_hour', 'five_hour', status: 'unavailable'),
            _win('weekly', 'weekly', status: 'unavailable'),
          ],
        },
      ],
    };

DeckProfile _sevenTileAiProfile() {
  const ids = [
    ('acct_codex_pc', 'codex', 'Codex on this PC'),
    ('acct_claude_live', 'claude', 'Personal'),
    ('acct_codex_429_with_bars', 'codex', 'Codex #3'),
    ('acct_claude_wait', 'claude', 'Claude #1'),
    ('acct_ag_unavail', 'antigravity', 'Antigravity #1'),
    ('acct_codex_stale', 'codex', 'Codex #1'),
    ('acct_codex_2', 'codex', 'Codex #2'),
  ];
  return DeckProfile(
    id: 'ai_usage',
    name: 'AI Usage',
    rows: 4,
    columns: 4,
    buttons: [
      for (var i = 0; i < ids.length; i++)
        DeckButton(
          id: 'ai_$i',
          row: i ~/ 2,
          column: (i % 2) * 2,
          columnSpan: 2,
          rowSpan: 1,
          dynamicType: aiLimitsDynamicType,
          dynamicParameters: {
            'accountId': ids[i].$1,
            'provider': ids[i].$2,
            'alias': ids[i].$3,
          },
        ),
    ],
  );
}

DeckOSClient _mockClient(
  Map<String, dynamic> snap, {
  List<DeckProfile>? profiles,
  bool failSnapshot = false,
}) {
  final list = profiles ?? [_sevenTileAiProfile()];
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
    final m = o.method.toUpperCase();
    if (o.path == '/api/ai-limits' && m == 'GET') {
      if (failSnapshot) {
        return h.reject(DioException(requestOptions: o, type: DioExceptionType.connectionError));
      }
      return h.resolve(Response(requestOptions: o, statusCode: 200, data: snap));
    }
    if (o.path == '/api/ai-limits/sources/test' && m == 'POST') {
      return h.resolve(Response(
        requestOptions: o,
        statusCode: 200,
        data: {
          'ok': true,
          'reachable': true,
          'status': 'connected',
          'message': 'Connected via CLIProxyAPI v8',
          'accounts': (snap['accounts'] as List).take(3).toList(),
        },
      ));
    }
    if (o.path == '/api/StreamDeck/profiles' && m == 'GET') {
      return h.resolve(Response(
        requestOptions: o,
        statusCode: 200,
        data: list.map((p) => jsonDecode(jsonEncode(p.toJson()))).toList(),
      ));
    }
    if (o.path == '/api/StreamDeck/layout' && m == 'GET') {
      return h.resolve(Response(requestOptions: o, statusCode: 200, data: {'rows': 2, 'columns': 4}));
    }
    return h.resolve(Response(requestOptions: o, statusCode: 200, data: const []));
  }));
  return DeckOSClient(baseUrl: 'http://localhost', dio: dio);
}

void _register(DeckOSClient client) {
  GetIt.I.registerSingleton<DeckOSClient>(client);
  GetIt.I.registerSingleton<SignalRService>(SignalRService());
  AiLimitsStore.resetForTest(client: AiLimitsClient(client));
}

Future<void> _maybeSavePng(WidgetTester tester, GlobalKey key, String name) async {
  if (_screensOut.isEmpty) return;
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final img = await boundary.toImage(pixelRatio: 2);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final f = File('$_screensOut/$name.png');
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(() async {
    await _loadFont('Inter', 'assets/fonts/InterVariable.ttf');
    await _loadFont(
      'packages/cupertino_icons/CupertinoIcons',
      'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    );
    final artifacts = File(Platform.resolvedExecutable).parent.parent.parent;
    final material = File('${artifacts.path}/material_fonts/materialicons-regular.otf');
    if (material.existsSync()) {
      final loader = FontLoader('MaterialIcons');
      loader.addFont(Future.value(ByteData.sublistView(material.readAsBytesSync())));
      await loader.load();
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.choice.value = 'en';
    PcStore.currentId = 'pc_a';
  });

  tearDown(() async {
    AiLimitsStore.resetForTest();
    await ThemeController.instance.setDeckOnly(false);
    await ThemeController.instance.setCustomGrid(null);
    await GetIt.I.reset();
    PcStore.currentId = null;
  });

  group('DeckGridFit AI Usage responsive sizing', () {
    test('portrait 4x4 AI Usage reflows to 2 full-width columns without shrinking cards', () {
      const screen = Size(411, 919);
      const area = Size(379, 800);
      final g = DeckGridFit.compute(
        area: area,
        screen: screen,
        minCols: 4,
        minRows: 4,
        minCellHeight: DeckGridFit.aiLimitsMinCell,
        preferTwoColPortrait: true,
      );
      expect(g.reflow, isTrue);
      expect(g.cols, 2);
      expect(g.cell, greaterThanOrEqualTo(160));
      // Even with 7 stacked rows, cellFor keeps full card height and scrolls cleanly.
      expect(g.cellFor(7), greaterThanOrEqualTo(DeckGridFit.aiLimitsMinCell));
      final cardWidth = 2 * g.cell + g.spacing;
      expect(cardWidth, greaterThanOrEqualTo(350));
    });

    test('landscape 4x4 AI Usage guarantees comfortable wide cards (no 75dp slivers)', () {
      const screen = Size(919, 411);
      const area = Size(855, 330);
      final g = DeckGridFit.compute(
        area: area,
        screen: screen,
        minCols: 4,
        minRows: 4,
        minCellHeight: DeckGridFit.aiLimitsMinCell,
        preferTwoColPortrait: true,
      );
      expect(g.reflow, isTrue);
      expect(g.cols, 4);
      expect(g.cell, greaterThanOrEqualTo(165));
      expect(g.cellFor(4), greaterThanOrEqualTo(165));
      final cardWidth = 2 * g.cell + g.spacing;
      expect(cardWidth, greaterThanOrEqualTo(360));
    });
  });

  group('Revamped AiLimitsTile across sizes, states, and 2x font scale', () {
    testWidgets('rate-limited/blocked account with live percent windows still shows bars + header badge',
        (tester) async {
      _register(_mockClient(_revampSnapshot()));
      await tester.runAsync(() => AiLimitsStore.instance.load());

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 380,
              height: 175,
              child: DynamicDeckButton(
                button: DeckButton(
                  id: 'b_429',
                  row: 0,
                  column: 0,
                  columnSpan: 2,
                  dynamicType: aiLimitsDynamicType,
                  dynamicParameters: const {'accountId': 'acct_codex_429_with_bars'},
                ),
                onTap: () {},
                onLongPress: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Blocked'), findsOneWidget);
      expect(find.text('100% used'), findsOneWidget);
      expect(find.text('54% used'), findsOneWidget);
      expect(find.byType(CapsuleBar), findsNWidgets(2));
    });

    testWidgets('awaiting_data shows honest Waiting for traffic instead of double unavailable lines',
        (tester) async {
      _register(_mockClient(_revampSnapshot()));
      await tester.runAsync(() => AiLimitsStore.instance.load());

      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 380,
              height: 175,
              child: DynamicDeckButton(
                button: DeckButton(
                  id: 'b_wait',
                  row: 0,
                  column: 0,
                  columnSpan: 2,
                  dynamicType: aiLimitsDynamicType,
                  dynamicParameters: const {'accountId': 'acct_claude_wait'},
                ),
                onTap: () {},
                onLongPress: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Waiting for traffic'), findsOneWidget);
      expect(find.text('Limits appear after normal CLI use'), findsOneWidget);
    });

    testWidgets('spacious 2x1, roomy 2x2, compact horizontal, square 1x1, and micro preview render at 2.0x text scale with zero overflow',
        (tester) async {
      _register(_mockClient(_revampSnapshot()));
      await tester.runAsync(() => AiLimitsStore.instance.load());

      for (final size in const [
        Size(380, 175),
        Size(380, 360),
        Size(250, 96),
        Size(136, 136),
        Size(68, 68),
      ]) {
        await tester.pumpWidget(MediaQuery(
          data: const MediaQueryData(
            size: Size(500, 500),
            textScaler: TextScaler.linear(2.0),
          ),
          child: MaterialApp(
            theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: DynamicDeckButton(
                    button: DeckButton(
                      id: 'sz_${size.width}_${size.height}',
                      row: 0,
                      column: 0,
                      columnSpan: size.width >= 200 ? 2 : 1,
                      rowSpan: size.height >= 250 ? 2 : 1,
                      dynamicType: aiLimitsDynamicType,
                      dynamicParameters: const {'accountId': 'acct_claude_live'},
                    ),
                    onTap: () {},
                    onLongPress: () {},
                  ),
                ),
              ),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Failed at size $size');
        expect(find.byType(CapsuleBar), findsAtLeastNWidgets(1), reason: 'Bar missing at $size');
      }
    });
  });

  group('New-tile default span & direct deck connect entry', () {
    testWidgets('new button switching to ai_limits defaults to 2x1 span while existing tile keeps 1x1',
        (tester) async {
      _register(_mockClient(_revampSnapshot()));
      await tester.runAsync(() => AiLimitsStore.instance.load());
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      DeckButton? savedNew;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: Scaffold(
          body: ButtonPropertyPanel(
            button: DeckButton(id: '', row: 0, column: 0, label: ''),
            onSave: (b) => savedNew = b,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Show on button'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: find.byType(InfoSection), matching: find.text('None')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('AI Limits').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedNew, isNotNull);
      expect(savedNew!.dynamicType, aiLimitsDynamicType);
      expect(savedNew!.columnSpan, 2);
      expect(savedNew!.rowSpan, 1);

      // Existing 1×1 tile preserves its saved 1×1 span when edited.
      DeckButton? savedExisting;
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: Scaffold(
          body: ButtonPropertyPanel(
            key: const ValueKey('existing_1x1_panel'),
            button: DeckButton(
              id: 'existing_1x1',
              row: 0,
              column: 0,
              columnSpan: 1,
              rowSpan: 1,
              dynamicType: aiLimitsDynamicType,
              dynamicParameters: const {'accountId': 'acct_codex_pc'},
            ),
            onSave: (b) => savedExisting = b,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(savedExisting, isNotNull);
      expect(savedExisting!.columnSpan, 1);
      expect(savedExisting!.rowSpan, 1);
    });

    testWidgets('AI Usage deck page renders full-width portrait cards and exposes direct Connect AI accounts chrome button',
        (tester) async {
      await ThemeController.instance.setDeckOnly(true);
      tester.view.physicalSize = const Size(411, 919);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      _register(_mockClient(_revampSnapshot()));
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
          home: const HomePage(),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Verify full-width card rendering on portrait phone!
      final firstTile = find.byKey(const ValueKey('deck-btn-ai_0'));
      expect(firstTile, findsOneWidget);
      final tileSize = tester.getSize(firstTile);
      expect(tileSize.width, greaterThanOrEqualTo(340));
      expect(tileSize.height, greaterThanOrEqualTo(155));

      // Direct Connect AI accounts shortcut in floating top pill.
      expect(find.byTooltip('Connect AI accounts'), findsOneWidget);

      await _maybeSavePng(tester, key, 'deck_ai_portrait_dark');
    });

    testWidgets('AI Usage deck page landscape light & dark fixture QA renders cleanly',
        (tester) async {
      await ThemeController.instance.setDeckOnly(true);
      tester.view.physicalSize = const Size(919, 411);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      _register(_mockClient(_revampSnapshot()));
      for (final (b, name) in [(Brightness.dark, 'deck_ai_landscape_dark'), (Brightness.light, 'deck_ai_landscape_light')]) {
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(const ThemeSettings(), b),
            home: HomePage(key: ValueKey(name)),
          ),
        ));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final firstTile = find.byKey(const ValueKey('deck-btn-ai_0'));
        final tileSize = tester.getSize(firstTile);
        expect(tileSize.width, greaterThanOrEqualTo(350));
        expect(tileSize.height, greaterThanOrEqualTo(155));
        await _maybeSavePng(tester, key, name);
      }
    });
  });

  group('Streamlined provider-first onboarding', () {
    testWidgets('picker shows Ready on this PC with honest badges, hides Codex jargon, and supports batch account selection',
        (tester) async {
      tester.view.physicalSize = const Size(411, 919);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      _register(_mockClient(_revampSnapshot(includeExistingCodex: false)));
      final key = GlobalKey();
      await tester.pumpWidget(RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
          home: const AiLimitsSettingsPage(openWizardOnStart: true),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(find.text('Ready on this PC'), findsOneWidget);
      expect(find.text('Quick connect'), findsOneWidget);
      expect(find.text('Hook needed'), findsOneWidget);
      expect(find.text('Other providers & shortcuts'), findsOneWidget);
      await _maybeSavePng(tester, key, 'onboarding_picker_dark');

      // Tap Codex: Read mode jargon is tucked inside Advanced options.
      await tester.tap(find.text('OpenAI Codex (Official Local)'));
      await tester.pumpAndSettle();
      expect(find.text('Read mode'), findsNothing);
      expect(find.text('Advanced options (optional)'), findsOneWidget);

      // Expand Advanced options to confirm Read mode is still accessible.
      await tester.tap(find.text('Advanced options (optional)'));
      await tester.pumpAndSettle();
      expect(find.text('Read mode'), findsOneWidget);
    });

    testWidgets('landscape setup keeps Test connection, Save source, and Cancel immediately reachable',
        (tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      _register(_mockClient(_revampSnapshot(includeExistingCodex: false)));
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: const AiLimitsSettingsPage(openWizardOnStart: true),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('CLIProxyAPI (Passive Local)'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final testBtn = find.text('Test connection');
      final saveBtn = find.text('Save source');
      final cancelBtn = find.text('Cancel');
      expect(testBtn, findsOneWidget);
      expect(saveBtn, findsOneWidget);
      expect(cancelBtn, findsOneWidget);
      expect(tester.getRect(testBtn).bottom, lessThanOrEqualTo(390));
      expect(tester.getRect(saveBtn).bottom, lessThanOrEqualTo(390));
    });

    testWidgets('batch Select all / Clear all works after testing CLIProxyAPI', (tester) async {
      tester.view.physicalSize = const Size(411, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      _register(_mockClient(_revampSnapshot(includeExistingCodex: false)));
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: const AiLimitsSettingsPage(openWizardOnStart: true),
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('CLIProxyAPI (Passive Local)'));
      await tester.pumpAndSettle();

      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(2), 'mgmt-key-123');
      await tester.pump();
      await tester.tap(find.text('Test connection'));
      await tester.pumpAndSettle();

      expect(find.text('3 selected for deck'), findsOneWidget);
      expect(find.text('Clear all'), findsOneWidget);

      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();
      expect(find.text('0 selected for deck'), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);
    });

    testWidgets('offline error banner offers single Try again recovery button', (tester) async {
      _register(_mockClient(_revampSnapshot(), failSnapshot: true));
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: const AiLimitsSettingsPage(),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
    });
  });
}
