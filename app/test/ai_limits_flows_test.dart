import 'package:deckos/core/core.dart';
import 'package:deckos/src/ai_limits/ai_limits_client.dart';
import 'package:deckos/src/ai_limits/ai_limits_editor_fields.dart';
import 'package:deckos/src/ai_limits/ai_limits_models.dart';
import 'package:deckos/src/ai_limits/ai_limits_settings_page.dart';
import 'package:deckos/src/ai_limits/ai_limits_store.dart';
import 'package:deckos/src/ai_limits/ai_provider_style.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/widgets/dynamic_deck_button.dart';
import 'package:deckos/src/stream_deck/widgets/usage_bars.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Regression and flow tests for the real `ai_limits` tiles and Settings → AI Limits,
// against contract §9 (docs/ai-limits-api-contract.md). Fixtures only: no live PC,
// proxy or provider is touched.

Map<String, dynamic> _w(
  String id,
  String kind, {
  String? pool,
  double? used,
  String status = 'available',
  String? resetsAt,
  bool? ordinaryUsageAllowed,
  String unit = 'percent',
}) =>
    {
      'id': id,
      'kind': kind,
      'label': kind == 'five_hour' ? '5h' : (kind == 'weekly' ? 'Weekly' : kind),
      'unit': unit,
      'status': status,
      'usedPercent': used,
      'remainingPercent': used == null ? null : 100 - used,
      'resetsAt': resetsAt,
      'modelPool': pool,
      'ordinaryUsageAllowed': ordinaryUsageAllowed,
    };

String _inHours(int h) => DateTime.now().toUtc().add(Duration(hours: h)).toIso8601String();

/// Codex account with the main pool plus one extra model pool, deliberately in mixed
/// order (pool windows first, main 5h last, main 5h with a null pool).
Map<String, dynamic> _codexPoolsAccount() => {
      'id': 'acct_codex_pools',
      'sourceId': 'src_codex',
      'sourceKind': 'codex_local',
      'provider': 'codex',
      'providerLabel': 'Codex',
      'alias': 'Codex #1',
      'enabled': true,
      'connectionStatus': 'connected',
      'quotaStatus': 'ok',
      'freshness': 'fresh',
      'windows': [
        _w('pool:spark:five_hour', 'five_hour', pool: 'Spark', used: 90, resetsAt: _inHours(1)),
        _w('weekly', 'weekly', pool: 'all', used: 30, resetsAt: _inHours(48)),
        _w('pool:spark:weekly', 'weekly', pool: 'Spark', used: 55, resetsAt: _inHours(40)),
        _w('five_hour', 'five_hour', used: 12, resetsAt: _inHours(3)),
      ],
    };

Map<String, dynamic> _snapshot({
  List<Map<String, dynamic>> sources = const [],
  List<Map<String, dynamic>> accounts = const [],
  Map<String, dynamic>? detected,
}) =>
    {
      'schemaVersion': 1,
      'capabilities': {
        'platform': 'windows',
        'claudeStatusLineInstallerAvailable': true,
        'detected': detected ??
            {
              'cliProxySuggestedUrl': 'http://127.0.0.1:8317',
              'cliProxyReachable': true,
              'codexCliAvailable': true,
              'codexDefaultHomeExists': true,
              'claudeCliAvailable': true,
              'claudeConfigDirExists': true,
              'claudeStatusLineConfigured': false,
              'geminiDirExists': false,
            },
        'supportedSourceKinds': [
          for (final k in [
            ('cliproxy_passive', 'CLIProxyAPI (Passive Local)', true),
            ('codex_local', 'Codex (app-server)', false),
            ('claude_statusline', 'Claude Code (statusLine)', false),
            ('gemini_local_otel', 'Gemini CLI (local OTel)', false),
            ('external_monitor_cache', 'Reserved monitor', false),
          ])
            {
              'kind': k.$1,
              'title': k.$2,
              'description': 'desc ${k.$1}',
              'accessMode': 'passive_local_file',
              'requiresCredential': k.$3,
              'supportsTestConnection': true,
            },
        ],
      },
      'refresh': {'cooldownSeconds': 15, 'autoRefreshIntervalSeconds': 180},
      'sources': sources,
      'accounts': accounts,
    };

class _Server {
  Map<String, dynamic> snapshot;
  final requests = <String>[];
  final bodies = <String, List<Map<String, dynamic>>>{};
  Response<dynamic> Function(RequestOptions o)? installHook;

  _Server(this.snapshot);

  DeckOSClient client() {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(onRequest: (o, h) {
      final key = '${o.method.toUpperCase()} ${o.path}';
      requests.add(key);
      if (o.data is Map) {
        (bodies[key] ??= []).add(Map<String, dynamic>.from(o.data as Map));
      }
      if (key == 'GET /api/ai-limits') {
        return h.resolve(Response(requestOptions: o, statusCode: 200, data: snapshot));
      }
      if (key.endsWith('/setup')) {
        return h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'sourceId': 'src_claude',
          'kind': 'claude_statusline',
          'supported': true,
          'isInstalled': false,
          'canAutoInstall': true,
          'steps': ['Install the wrapper.'],
          'caveats': const [],
          'commandPreview': 'deckos-capture --passthru',
        }));
      }
      if (key.endsWith('/install-hook') && installHook != null) {
        final r = installHook!(o);
        if ((r.statusCode ?? 200) >= 400) {
          return h.reject(DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: r,
          ));
        }
        return h.resolve(r);
      }
      if (key == 'POST /api/ai-limits/sources/test') {
        return h.resolve(Response(requestOptions: o, statusCode: 200, data: {
          'ok': false,
          'reachable': true,
          'status': 'auth_required',
          'errorCode': 'auth_failed',
          'message': 'Key rejected.',
          'accounts': const [],
        }));
      }
      if (key == 'POST /api/ai-limits/sources') {
        final body = Map<String, dynamic>.from(o.data as Map);
        final src = {
          'id': 'src_new',
          'kind': body['kind'],
          'label': body['label'],
          'status': 'awaiting_data',
        };
        return h.resolve(Response(requestOptions: o, statusCode: 201, data: {
          'source': src,
          'accounts': const [],
          'snapshot': snapshot,
        }));
      }
      return h.resolve(Response(requestOptions: o, statusCode: 200, data: const []));
    }));
    return DeckOSClient(baseUrl: 'http://localhost', dio: dio);
  }
}

_Server _register(Map<String, dynamic> snapshot) {
  final server = _Server(snapshot);
  final client = server.client();
  GetIt.I.registerSingleton<DeckOSClient>(client);
  GetIt.I.registerSingleton<SignalRService>(SignalRService());
  AiLimitsStore.resetForTest(client: AiLimitsClient(client));
  return server;
}

Widget _app(Widget home) => MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: home,
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.choice.value = 'en';
    PcStore.currentId = 'pc_a';
  });

  tearDown(() async {
    AiLimitsStore.resetForTest();
    await GetIt.I.reset();
    PcStore.currentId = null;
    AppLanguage.choice.value = 'pt';
  });

  group('selectWindows (contract §9: one window per kind, main pool first)', () {
    final acct = AiLimitsAccount.fromJson(_codexPoolsAccount());

    test('5h + weekly picks the MAIN pool pair even when pool windows come first', () {
      final picked = acct.selectWindows(const ['five_hour', 'weekly']);
      expect(picked.map((w) => w.id), ['five_hour', 'weekly']);
      // Values are the windows' own readings, never summed across pools.
      expect(picked.map((w) => w.usedPercent), [12, 30]);
    });

    test('never returns two windows of one kind', () {
      final picked = acct.selectWindows(const ['five_hour', 'five_hour', 'weekly'], maxCount: 3);
      expect(picked.map((w) => w.kind), ['five_hour', 'weekly']);
    });

    test('an extra pool is used only when the tile asks for it', () {
      expect(acct.extraPools, ['Spark']);
      final pool = acct.selectWindows(const ['five_hour', 'weekly'], pool: 'Spark');
      expect(pool.map((w) => w.id), ['pool:spark:five_hour', 'pool:spark:weekly']);
    });

    test('a pool missing one kind falls back to the main window of that kind', () {
      final json = _codexPoolsAccount();
      (json['windows'] as List).removeWhere((w) => (w as Map)['id'] == 'pool:spark:weekly');
      final a = AiLimitsAccount.fromJson(json);
      final picked = a.selectWindows(const ['five_hour', 'weekly'], pool: 'Spark');
      expect(picked.map((w) => w.id), ['pool:spark:five_hour', 'weekly']);
    });

    test('"all windows" lists the main pool before extra pools', () {
      final picked = acct.selectWindows(const [], maxCount: 4);
      expect(picked.map((w) => w.id),
          ['weekly', 'five_hour', 'pool:spark:five_hour', 'pool:spark:weekly']);
    });

    test('no 5h/weekly (Gemini daily) falls back to native windows, one per kind', () {
      final a = AiLimitsAccount.fromJson({
        'id': 'acct_g',
        'provider': 'gemini_cli',
        'windows': [
          _w('daily', 'daily', unit: 'requests'),
          _w('daily2', 'daily', unit: 'requests'),
        ],
      });
      expect(a.selectWindows(const ['five_hour', 'weekly']).map((w) => w.id), ['daily']);
    });
  });

  test('past resets are stale (never zeroed) and ignored for the next reset', () {
    final past = DateTime.now().toUtc().subtract(const Duration(hours: 1)).toIso8601String();
    final a = AiLimitsAccount.fromJson({
      'id': 'acct_p',
      'provider': 'claude',
      'windows': [
        _w('five_hour', 'five_hour', used: 80, resetsAt: past),
        _w('weekly', 'weekly', used: 20, resetsAt: _inHours(30)),
      ],
    });
    final fiveHour = a.windowByKind('five_hour')!;
    expect(fiveHour.isPastReset(), isTrue);
    expect(fiveHour.isEffectivelyStale(), isTrue);
    expect(fiveHour.effectiveUsedPercent, 80);
    expect(a.nextResetAt!.isAfter(DateTime.now()), isTrue);

    // Unknown stays null, not 0 or 100.
    final unknown = AiLimitsWindow.fromJson(_w('five_hour', 'five_hour', status: 'unavailable'));
    expect(unknown.hasPercent, isFalse);
    expect(unknown.effectiveUsedPercent, isNull);
    expect(unknown.effectiveRemainingPercent, isNull);
  });

  test('setup guide keeps the refusal fields (errorCode/message)', () {
    final g = AiLimitsSetupGuide.fromJson(const {
      'sourceId': 's',
      'kind': 'claude_statusline',
      'supported': true,
      'isInstalled': false,
      'errorCode': 'internal_error',
      'message': 'settings.json is not plain JSON; left untouched.',
    });
    expect(g.hasError, isTrue);
    expect(g.message, contains('left untouched'));
  });

  testWidgets('tile shows main-pool 5h + weekly; pool tile labels its pool', (tester) async {
    _register(_snapshot(accounts: [_codexPoolsAccount()]));
    await tester.runAsync(() => AiLimitsStore.instance.load());

    Future<void> pump(Map<String, String> params) async {
      await tester.pumpWidget(_app(Scaffold(
        body: Center(
          child: SizedBox(
            width: 290,
            height: 145,
            child: DynamicDeckButton(
              button: DeckButton(
                id: 't',
                row: 0,
                column: 0,
                columnSpan: 2,
                dynamicType: aiLimitsDynamicType,
                dynamicParameters: params,
              ),
              onTap: () {},
              onLongPress: () {},
            ),
          ),
        ),
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await pump(const {'accountId': 'acct_codex_pools'});
    expect(find.text('12% used'), findsOneWidget);
    expect(find.text('30% used'), findsOneWidget);
    expect(find.text('90% used'), findsNothing);
    expect(find.byType(CapsuleBar), findsNWidgets(2));

    await pump(const {'accountId': 'acct_codex_pools', 'pool': 'Spark'});
    expect(find.text('90% used'), findsOneWidget);
    expect(find.text('55% used'), findsOneWidget);
    expect(find.textContaining('Spark'), findsNWidgets(2));
  });

  testWidgets('blocked usage stays visible after its timer expired; past reset shows stale',
      (tester) async {
    final past = DateTime.now().toUtc().subtract(const Duration(minutes: 5)).toIso8601String();
    _register(_snapshot(accounts: [
      {
        'id': 'acct_blocked',
        'sourceId': 'src',
        'sourceKind': 'cliproxy_passive',
        'provider': 'claude',
        'providerLabel': 'Claude',
        'alias': 'Claude #1',
        'connectionStatus': 'connected',
        'quotaStatus': 'ok',
        'freshness': 'fresh',
        'ordinaryUsageAllowed': false,
        'windows': [
          _w('five_hour', 'five_hour', used: 100, resetsAt: past, ordinaryUsageAllowed: false),
        ],
      },
      {
        'id': 'acct_past',
        'sourceId': 'src',
        'sourceKind': 'claude_statusline',
        'provider': 'claude',
        'providerLabel': 'Claude',
        'alias': 'Claude #2',
        'connectionStatus': 'connected',
        'quotaStatus': 'ok',
        'freshness': 'fresh',
        'windows': [_w('five_hour', 'five_hour', used: 64, resetsAt: past)],
      },
    ]));
    await tester.runAsync(() => AiLimitsStore.instance.load());

    for (final (id, pill, value) in [
      ('acct_blocked', 'Blocked', '100% used'),
      ('acct_past', 'Stale', '64% used'),
    ]) {
      await tester.pumpWidget(_app(Scaffold(
        body: Center(
          child: SizedBox(
            width: 290,
            height: 145,
            child: DynamicDeckButton(
              button: DeckButton(
                id: id,
                row: 0,
                column: 0,
                columnSpan: 2,
                dynamicType: aiLimitsDynamicType,
                dynamicParameters: {'accountId': id},
              ),
              onTap: () {},
              onLongPress: () {},
            ),
          ),
        ),
      )));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(pill), findsOneWidget, reason: id);
      expect(find.text(value), findsOneWidget, reason: id);
      expect(find.text('0% used'), findsNothing);
    }
  });

  testWidgets('settings lists tools found on the PC and opens the matching setup in one tap',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    _register(_snapshot(sources: [
      {
        'id': 'src_claude',
        'kind': 'claude_statusline',
        'label': 'Claude Code',
        'status': 'setup_required',
        'errorCode': 'hook_not_installed',
      },
    ]));

    await tester.pumpWidget(_app(const AiLimitsSettingsPage()));
    await tester.pumpAndSettle();

    expect(find.text('Found on this PC'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-detected-codex_local')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-detected-cliproxy_passive')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-detected-gemini_local_otel')), findsNothing);
    // Found-but-not-hooked is not shown as connected.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ai-detected-claude_statusline')),
        matching: find.text('Hook not installed'),
      ),
      findsOneWidget,
    );
    // No phone-local paths in the main flow.
    expect(find.textContaining('.codex'), findsNothing);

    // One tap on Codex goes straight to its form (picker skipped, reserved kind hidden).
    await tester.tap(find.byKey(const ValueKey('ai-detected-codex_local')));
    await tester.pumpAndSettle();
    expect(find.text('Codex (app-server)'), findsAtLeastNWidgets(1));
    expect(find.text('Save source'), findsOneWidget);
    expect(find.text('Reserved monitor'), findsNothing);
  });

  testWidgets('hook install refusal (200 + setup.errorCode) is shown, never as success',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final server = _register(_snapshot(sources: [
      {'id': 'src_claude', 'kind': 'claude_statusline', 'label': 'Claude Code', 'status': 'setup_required'},
    ]));
    server.installHook = (o) => Response(requestOptions: o, statusCode: 200, data: {
          'setup': {
            'sourceId': 'src_claude',
            'kind': 'claude_statusline',
            'supported': true,
            'isInstalled': false,
            'canAutoInstall': true,
            'errorCode': 'internal_error',
            'message': 'Claude settings.json has comments, so DeckOS left it untouched.',
            'commandPreview': 'deckos-capture --passthru',
          },
          'snapshot': server.snapshot,
        });

    await tester.pumpWidget(_app(const AiLimitsSettingsPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Hook setup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install hook on PC'));
    await tester.pumpAndSettle();

    expect(find.textContaining('left it untouched'), findsOneWidget);
    expect(find.textContaining('Hook installed'), findsNothing);
    expect(find.text('Install hook on PC'), findsOneWidget);
  });

  testWidgets('hook install from a remote phone (403 local_only_action) explains the PC-only step',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final server = _register(_snapshot(sources: [
      {'id': 'src_claude', 'kind': 'claude_statusline', 'label': 'Claude Code', 'status': 'setup_required'},
    ]));
    server.installHook = (o) => Response(requestOptions: o, statusCode: 403, data: {
          'errorCode': 'local_only_action',
          'message': 'Only on the PC.',
        });

    await tester.pumpWidget(_app(const AiLimitsSettingsPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Hook setup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Install hook on PC'));
    await tester.pumpAndSettle();

    expect(find.textContaining('only be installed from the PC itself'), findsOneWidget);
    expect(find.text('deckos-capture --passthru'), findsOneWidget);
    expect(find.text('Install hook on PC'), findsNothing);
  });

  testWidgets('editing a source whose key was rejected: name-only edits cannot re-test',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final server = _register(_snapshot(sources: [
      {
        'id': 'src_cpa',
        'kind': 'cliproxy_passive',
        'label': 'Local CLIProxyAPI',
        'baseUrl': 'http://127.0.0.1:8317',
        'hasCredential': true,
        'status': 'auth_required',
        'errorCode': 'auth_failed',
      },
    ]));

    await tester.pumpWidget(_app(const AiLimitsSettingsPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local CLIProxyAPI'));
    await tester.pumpAndSettle();

    final testButton = find.text('Test connection');
    await tester.ensureVisible(testButton);
    await tester.tap(testButton);
    await tester.pumpAndSettle();
    expect(server.requests.where((r) => r.endsWith('/sources/test')), isEmpty);

    // Renaming doesn't unlock it.
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Renamed proxy');
    await tester.pump();
    await tester.tap(testButton);
    await tester.pumpAndSettle();
    expect(server.requests.where((r) => r.endsWith('/sources/test')), isEmpty);

    // A new key unlocks exactly one attempt.
    await tester.enterText(fields.at(2), 'new-key');
    await tester.pump();
    await tester.tap(testButton);
    await tester.pumpAndSettle();
    expect(server.requests.where((r) => r.endsWith('/sources/test')).length, 1);
  });

  testWidgets('a key typed for one PC is wiped, not sent, if the active PC changes',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final server = _register(_snapshot());

    await tester.pumpWidget(_app(const AiLimitsSettingsPage(openWizardOnStart: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CLIProxyAPI (Passive Local)'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(2), 'key-for-pc-a');
    await tester.pump();

    PcStore.currentId = 'pc_b';
    await tester.ensureVisible(find.text('Save source'));
    await tester.tap(find.text('Save source'));
    await tester.pumpAndSettle();

    expect(server.requests.where((r) => r.contains('/api/ai-limits/sources')), isEmpty);
    expect(find.textContaining('active PC changed'), findsOneWidget);
    final secret = tester.widget<TextFormField>(fields.at(2));
    expect(secret.controller!.text, isEmpty);
  });

  testWidgets('an unsaved PC route change wipes a typed key before sending',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    PcStore.currentId = null;
    final server = _register(_snapshot());

    await tester.pumpWidget(_app(const AiLimitsSettingsPage(openWizardOnStart: true)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('CLIProxyAPI (Passive Local)'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(2), 'key-for-pc-a');
    await tester.pump();

    GetIt.I<DeckOSClient>().setBaseUrl('http://pc-b:4787');
    await tester.ensureVisible(find.text('Save source'));
    await tester.tap(find.text('Save source'));
    await tester.pumpAndSettle();

    expect(server.requests.where((r) => r.contains('/api/ai-limits/sources')), isEmpty);
    expect(find.textContaining('active PC changed'), findsOneWidget);
    final secret = tester.widget<TextFormField>(fields.at(2));
    expect(secret.controller!.text, isEmpty);
  });

  testWidgets('editor offers a pool picker only for accounts with extra pools', (tester) async {
    _register(_snapshot(accounts: [
      _codexPoolsAccount(),
      {
        'id': 'acct_plain',
        'sourceId': 's',
        'provider': 'claude',
        'providerLabel': 'Claude',
        'alias': 'Claude #1',
        'windows': [_w('five_hour', 'five_hour', used: 5)],
      },
    ]));
    await tester.runAsync(() => AiLimitsStore.instance.load());

    Map<String, String>? last;
    Future<void> pump(Map<String, String> params) async {
      await tester.pumpWidget(_app(Scaffold(
        body: SingleChildScrollView(
          child: AiLimitsEditorFields(params: params, onChanged: (p) => last = p),
        ),
      )));
      await tester.pumpAndSettle();
    }

    await pump(const {'accountId': 'acct_plain'});
    expect(find.text('Model pool'), findsNothing);

    await pump(const {'accountId': 'acct_codex_pools'});
    expect(find.text('Model pool'), findsOneWidget);
    await tester.tap(find.text('Main (whole account)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spark').last);
    await tester.pumpAndSettle();
    expect(last?['pool'], 'Spark');
    expect(last?['accountId'], 'acct_codex_pools');
    expect(last!.keys.any((k) => k.contains('key') || k.contains('token')), isFalse);
  });
}
