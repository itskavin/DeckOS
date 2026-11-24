// Dashboard fixtures exercise the real settings route. Optional SCREENS_OUT captures
// are design verification only; no real accounts or provider data are used.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:deckos/core/core.dart';
import 'package:deckos/src/ai_limits/ai_limits_client.dart';
import 'package:deckos/src/ai_limits/ai_limits_dashboard.dart';
import 'package:deckos/src/ai_limits/ai_limits_models.dart';
import 'package:deckos/src/ai_limits/ai_limits_settings_page.dart';
import 'package:deckos/src/ai_limits/ai_limits_store.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _out = String.fromEnvironment('SCREENS_OUT', defaultValue: '');

Future<void> _loadFont(String family, String asset) async {
  try {
    await (FontLoader(family)..addFont(rootBundle.load(asset))).load();
  } catch (_) {
    // Screenshots are optional; assertions also run with the test font.
  }
}

String _inH(double h) =>
    DateTime.now().toUtc().add(Duration(minutes: (h * 60).round())).toIso8601String();
String _agoMin(int m) => DateTime.now().toUtc().subtract(Duration(minutes: m)).toIso8601String();

Map<String, dynamic> _w(
  String id,
  String kind,
  String label, {
  double? used,
  String status = 'available',
  String? resetsAt,
  String unit = 'percent',
  double? usedCount,
  double? limit,
  String? pool,
}) => {
  'id': id,
  'kind': kind,
  'label': label,
  'unit': unit,
  'status': status,
  'usedPercent': used,
  'remainingPercent': used == null ? null : 100 - used,
  'resetsAt': resetsAt,
  'used': usedCount,
  'limit': limit,
  'modelPool': pool,
};

Map<String, dynamic> _snapshot({bool empty = false}) => {
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
      'claudeStatusLineConfigured': !empty,
      'geminiDirExists': true,
    },
    'supportedSourceKinds': [
      for (final k in [
        ('cliproxy_passive', 'CLIProxyAPI (Passive Local)', true),
        ('codex_local', 'Codex (app-server)', false),
        ('claude_statusline', 'Claude Code (statusLine)', false),
        ('gemini_local_otel', 'Gemini CLI (local OTel)', false),
        ('manual_dashboard', 'Manual dashboard', false),
      ])
        {
          'kind': k.$1,
          'title': k.$2,
          'description': 'Reads limits from ${k.$2}.',
          'accessMode': 'passive_local_file',
          'requiresCredential': k.$3,
          'supportsTestConnection': true,
        },
    ],
  },
  'refresh': {'cooldownSeconds': 15, 'autoRefreshIntervalSeconds': 180},
  'sources': empty
      ? const []
      : [
          {
            'id': 'src_codex',
            'kind': 'codex_local',
            'label': 'Codex CLI',
            'status': 'connected',
            'accountCount': 1,
            'lastSyncedAt': _agoMin(1),
          },
          {
            'id': 'src_claude',
            'kind': 'claude_statusline',
            'label': 'Claude Code',
            'status': 'connected',
            'accountCount': 1,
            'lastSyncedAt': _agoMin(3),
          },
          {
            'id': 'src_proxy',
            'kind': 'cliproxy_passive',
            'label': 'Local CLIProxyAPI',
            'status': 'connected',
            'baseUrl': 'http://127.0.0.1:8317',
            'hasCredential': true,
            'accountCount': 2,
            'lastSyncedAt': _agoMin(2),
          },
        ],
  'accounts': empty
      ? const []
      : [
          {
            'id': 'acct_codex',
            'sourceId': 'src_codex',
            'sourceKind': 'codex_local',
            'provider': 'codex',
            'providerLabel': 'Codex',
            'alias': 'Work',
            'plan': 'Pro',
            'enabled': true,
            'connectionStatus': 'connected',
            'quotaStatus': 'ok',
            'freshness': 'fresh',
            'observedAt': _agoMin(1),
            'windows': [
              _w('five_hour', 'five_hour', '5h', used: 34, resetsAt: _inH(2.3)),
              _w('weekly', 'weekly', 'Weekly', used: 61, resetsAt: _inH(77)),
            ],
          },
          {
            'id': 'acct_claude',
            'sourceId': 'src_claude',
            'sourceKind': 'claude_statusline',
            'provider': 'claude',
            'providerLabel': 'Claude',
            'alias': 'Personal',
            'plan': 'Max 5x',
            'enabled': true,
            'connectionStatus': 'connected',
            'quotaStatus': 'ok',
            'freshness': 'fresh',
            'observedAt': _agoMin(3),
            'windows': [
              _w('five_hour', 'five_hour', '5h', used: 88, resetsAt: _inH(0.7)),
              _w('weekly', 'weekly', 'Weekly', used: 42, resetsAt: _inH(110)),
            ],
          },
          {
            'id': 'acct_gem',
            'sourceId': 'src_proxy',
            'sourceKind': 'cliproxy_passive',
            'provider': 'gemini_cli',
            'providerLabel': 'Gemini CLI',
            'alias': 'Gemini CLI',
            'enabled': true,
            'connectionStatus': 'connected',
            'quotaStatus': 'local_only',
            'freshness': 'local_only',
            'observedAt': _agoMin(2),
            'windows': [
              _w('five_hour', 'five_hour', '5h', status: 'not_applicable'),
              _w('daily', 'daily', 'Today', unit: 'requests', usedCount: 340, limit: 1000),
            ],
          },
          {
            'id': 'acct_ag',
            'sourceId': 'src_proxy',
            'sourceKind': 'cliproxy_passive',
            'provider': 'antigravity',
            'providerLabel': 'Antigravity',
            'alias': 'Antigravity',
            'enabled': false,
            'connectionStatus': 'connected',
            'quotaStatus': 'unavailable',
            'freshness': 'fresh',
            'windows': const [],
          },
        ],
};

class _Fake {
  final Map<String, dynamic> snap;
  _Fake(this.snap);
  DeckOSClient client() {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (o, h) {
          if (o.method.toUpperCase() == 'GET' && o.path == '/api/ai-limits') {
            return h.resolve(Response(requestOptions: o, statusCode: 200, data: snap));
          }
          return h.resolve(Response(requestOptions: o, statusCode: 200, data: const []));
        },
      ),
    );
    return DeckOSClient(baseUrl: 'http://localhost', dio: dio);
  }
}

void main() {
  setUpAll(() async {
    await _loadFont('Inter', 'assets/fonts/InterVariable.ttf');
    await _loadFont(
      'packages/cupertino_icons/CupertinoIcons',
      'packages/cupertino_icons/assets/CupertinoIcons.ttf',
    );
    // The runner ships the material font next to its engine artifacts.
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
    await GetIt.I.reset();
    PcStore.currentId = null;
  });

  Future<void> shoot(
    WidgetTester tester,
    String name,
    Size size,
    Brightness b, {
    bool empty = false,
    double textScale = 1,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final client = _Fake(_snapshot(empty: empty)).client();
    GetIt.I.registerSingleton<DeckOSClient>(client);
    GetIt.I.registerSingleton<SignalRService>(SignalRService());
    AiLimitsStore.resetForTest(client: AiLimitsClient(client));
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(const ThemeSettings(), b),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: const AiLimitsSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
    if (empty) {
      expect(find.text('Track your AI limits'), findsOneWidget);
    } else {
      expect(find.byType(AiLimitsOverview), findsOneWidget);
      // Accounts may be below the fold; scroll assertions exercise those separately.
      expect(find.text('Highest use'), findsOneWidget);
      // The usage section can be below the fold at large text sizes.
    }
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    if (_out.isNotEmpty)
      await tester.runAsync(() async {
        final img = await boundary.toImage(pixelRatio: 2);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        final f = File('$_out/$name.png');
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(data!.buffer.asUint8List());
      });
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('phone dark', (t) => shoot(t, 'phone_dark', const Size(390, 1700), Brightness.dark));
  testWidgets(
    'phone light',
    (t) => shoot(t, 'phone_light', const Size(390, 1700), Brightness.light),
  );
  testWidgets(
    'phone empty',
    (t) => shoot(t, 'phone_empty', const Size(390, 1000), Brightness.dark, empty: true),
  );
  testWidgets(
    'tablet dark',
    (t) => shoot(t, 'tablet_dark', const Size(1180, 1100), Brightness.dark),
  );

  testWidgets(
    'narrow phone at double text scale',
    (t) => shoot(t, 'phone_large_text', const Size(320, 840), Brightness.dark, textScale: 2),
  );
  testWidgets(
    'landscape phone',
    (t) => shoot(t, 'landscape', const Size(900, 400), Brightness.dark),
  );

  test('primary gauges keep main 5h and weekly ahead of extra pools', () {
    final account = AiLimitsAccount.fromJson({
      'id': 'mixed',
      'provider': 'codex',
      'windows': [
        _w('spark', 'five_hour', '5h', used: 99, pool: 'Spark'),
        _w('daily', 'daily', 'Daily', used: 70),
        _w('week', 'weekly', 'Weekly', used: 25, pool: 'all'),
        _w('five', 'five_hour', '5h', used: 10),
      ],
    });
    expect(aiRingWindows(account).map((w) => w.id), ['five', 'week']);
  });

  testWidgets('account states stay explicit with large text and long names', (tester) async {
    tester.view.physicalSize = const Size(320, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final account = AiLimitsAccount.fromJson({
      'id': 'states',
      'provider': 'codex',
      'providerLabel': 'Codex',
      'alias': 'A long work account name that should remain readable',
      'plan': 'An unusually long subscription plan name',
      'enabled': true,
      'connectionStatus': 'connected',
      'quotaStatus': 'stale',
      'windows': [
        _w('five', 'five_hour', '5h', used: 72, resetsAt: _agoMin(5)),
        _w('week', 'weekly', 'Weekly', status: 'unavailable'),
        _w('pool', 'five_hour', '5h', used: 99, pool: 'Spark'),
        _w('na', 'daily', 'Daily', status: 'not_applicable'),
      ],
    });
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: AiAccountUsageCard(
              account: account,
              width: 320,
              showRemaining: false,
              onOpen: () => opened = true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('72% used'), findsOneWidget);
    expect(find.text('Awaiting a new reading'), findsOneWidget);
    expect(find.text('Usage unavailable'), findsOneWidget);
    expect(find.text('Not applicable'), findsOneWidget);
    expect(find.text('5h · Spark'), findsOneWidget);
    expect(find.text('Live'), findsNothing);
    await tester.tap(find.byTooltip('Account options'));
    expect(opened, isTrue);
  });

  testWidgets('overview excludes stale, offline and disabled readings from highest usage', (
    tester,
  ) async {
    AiLimitsAccount account(
      String id,
      double used, {
      String freshness = 'fresh',
      bool enabled = true,
      String connection = 'connected',
    }) => AiLimitsAccount.fromJson({
      'id': id,
      'provider': 'codex',
      'providerLabel': 'Codex',
      'alias': id,
      'enabled': enabled,
      'connectionStatus': connection,
      'freshness': freshness,
      'windows': [_w('five', 'five_hour', '5h', used: used, resetsAt: _inH(2))],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiLimitsOverview(
            accounts: [
              account('Live', 23),
              account('Old', 99, freshness: 'stale'),
              account('Offline', 95, connection: 'offline'),
              account('Disabled', 98, enabled: false),
            ],
          ),
        ),
      ),
    );
    expect(find.text('23%'), findsOneWidget);
    expect(find.text('99%'), findsNothing);
    expect(find.text('95%'), findsNothing);
    expect(find.text('98%'), findsNothing);
  });

  testWidgets('remaining switch changes account readings and account actions remain reachable', (
    tester,
  ) async {
    await shoot(tester, 'actions', const Size(800, 1400), Brightness.dark);
    // shoot disposes the page to release store timers. Mount a fresh route for interaction.
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: const AiLimitsSettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remaining'));
    await tester.pumpAndSettle();
    expect(find.textContaining('66'), findsWidgets);
    final options = find.descendant(
      of: find.byKey(const ValueKey('ai-account-acct_codex')),
      matching: find.byTooltip('Account options'),
    );
    await tester.tap(options);
    await tester.pumpAndSettle();
    expect(find.text('Disable account'), findsOneWidget);
    expect(find.text('Edit alias'), findsOneWidget);
    expect(find.text('Add tile to AI Usage page'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
  });
}
