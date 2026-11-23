import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/ai_limits/ai_limits_client.dart';
import 'package:deckos/src/ai_limits/ai_limits_models.dart';
import 'package:deckos/src/ai_limits/ai_limits_settings_page.dart';
import 'package:deckos/src/ai_limits/ai_limits_store.dart';
import 'package:deckos/src/ai_limits/ai_provider_style.dart';
import 'package:deckos/src/config/config_page.dart';
import 'package:deckos/src/home/home_page.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/layout/slot_ops.dart';
import 'package:deckos/src/stream_deck/widgets/button_property_panel.dart';
import 'package:deckos/src/stream_deck/widgets/dynamic_deck_button.dart';
import 'package:deckos/src/stream_deck/widgets/usage_bars.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _sampleSnapshotJson({
  List<Map<String, dynamic>>? sources,
  List<Map<String, dynamic>>? accounts,
  int cooldownSeconds = 15,
  String? nextRefreshAllowedAt,
}) =>
    {
      'schemaVersion': 1,
      'generatedAt': '2026-11-23T06:20:00Z',
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
            'kind': 'cliproxy_passive',
            'title': 'CLIProxyAPI (Passive Local)',
            'description':
                'Reads already-captured passive headers from your local CLIProxyAPI.',
            'accessMode': 'passive_local_proxy',
            'requiresCredential': true,
            'supportsMultiAccount': true,
            'supportsGuidedSetup': false,
            'supportsTestConnection': true,
            'provenanceNote':
                'Reads passive local proxy metadata only; never sends upstream probes.',
          },
          {
            'kind': 'codex_local',
            'title': 'Codex (app-server)',
            'description': 'Official local Codex app-server RPC with JSONL fallback.',
            'accessMode': 'official_local_rpc',
            'requiresCredential': false,
            'supportsMultiAccount': true,
            'supportsGuidedSetup': false,
            'supportsTestConnection': true,
          },
          {
            'kind': 'claude_statusline',
            'title': 'Claude Code (statusLine)',
            'description': 'Official passive statusLine hook snapshot.',
            'accessMode': 'official_local_hook',
            'requiresCredential': false,
            'supportsMultiAccount': false,
            'supportsGuidedSetup': true,
            'supportsTestConnection': true,
          },
        ],
      },
      'refresh': {
        'cooldownSeconds': cooldownSeconds,
        'nextRefreshAllowedAt': nextRefreshAllowedAt,
        'autoRefreshIntervalSeconds': 180,
        'isRefreshing': false,
      },
      'sources': sources ??
          [
            {
              'id': 'src_cpa1',
              'kind': 'cliproxy_passive',
              'label': 'Local CLIProxyAPI',
              'enabled': true,
              'accessMode': 'passive_local_proxy',
              'supportLevel': 'passive_local_proxy',
              'hasCredential': true,
              'baseUrl': 'http://127.0.0.1:8317',
              'status': 'connected',
              'statusMessage': 'Connected via CLIProxyAPI v8',
              'detectedApiVersion': 'v8',
              'accountCount': 6,
            },
          ],
      'accounts': accounts ??
          [
            {
              'id': 'acct_claude_1',
              'sourceId': 'src_cpa1',
              'sourceKind': 'cliproxy_passive',
              'provider': 'claude',
              'providerLabel': 'Claude',
              'alias': 'Personal',
              'plan': 'Pro',
              'enabled': true,
              'connectionStatus': 'connected',
              'quotaStatus': 'ok',
              'freshness': 'fresh',
              'supportLevel': 'passive_local_proxy',
              'coverageScope': 'proxy_observed_only',
              'provenanceLabel': 'CLIProxyAPI · Passive',
              'provenanceDetails': 'Captured passively from local proxy headers.',
              'observedAt': '2026-11-23T06:18:00Z',
              'dashboardUrl': 'https://claude.ai/settings/usage',
              'windows': [
                {
                  'id': 'five_hour',
                  'kind': 'five_hour',
                  'label': '5h Limit',
                  'unit': 'percent',
                  'status': 'available',
                  'usedPercent': 42.0,
                  'remainingPercent': 58.0,
                  'resetsAt': '2026-11-23T09:00:00Z',
                },
                {
                  'id': 'weekly',
                  'kind': 'weekly',
                  'label': 'Weekly',
                  'unit': 'percent',
                  'status': 'available',
                  'usedPercent': 61.0,
                  'remainingPercent': 39.0,
                  'resetsAt': '2026-11-28T00:00:00Z',
                },
              ],
            },
            {
              'id': 'acct_codex_pro',
              'sourceId': 'src_cpa1',
              'sourceKind': 'codex_local',
              'provider': 'codex',
              'providerLabel': 'Codex',
              'alias': 'Pro Account',
              'plan': 'Pro',
              'enabled': true,
              'connectionStatus': 'connected',
              'quotaStatus': 'ok',
              'freshness': 'fresh',
              'ordinaryUsageAllowed': true,
              'windows': [
                {
                  'id': 'five_hour',
                  'kind': 'five_hour',
                  'label': '5h Limit',
                  'unit': 'percent',
                  'status': 'not_applicable',
                  'usedPercent': null,
                  'remainingPercent': null,
                  'note': 'No 5h cap on Pro',
                },
                {
                  'id': 'weekly',
                  'kind': 'weekly',
                  'label': 'Weekly',
                  'unit': 'percent',
                  'status': 'available',
                  'usedPercent': 38.0,
                  'remainingPercent': 62.0,
                },
              ],
            },
            {
              'id': 'acct_gemini_cli',
              'sourceId': 'src_cpa1',
              'sourceKind': 'gemini_local_otel',
              'provider': 'gemini_cli',
              'providerLabel': 'Gemini CLI',
              'alias': 'Local',
              'enabled': true,
              'connectionStatus': 'connected',
              'quotaStatus': 'local_only',
              'freshness': 'local_only',
              'windows': [
                {
                  'id': 'daily',
                  'kind': 'daily',
                  'label': 'Daily local',
                  'unit': 'requests',
                  'status': 'available',
                  'used': 340.0,
                  'limit': null,
                },
              ],
            },
            {
              'id': 'acct_antigravity',
              'sourceId': 'src_cpa1',
              'sourceKind': 'manual_dashboard',
              'provider': 'antigravity',
              'providerLabel': 'Antigravity',
              'alias': 'Personal',
              'enabled': true,
              'connectionStatus': 'connected',
              'quotaStatus': 'manual_only',
              'freshness': 'manual_only',
              'dashboardUrl': 'https://antigravity.google',
              'windows': [
                {
                  'id': 'five_hour',
                  'kind': 'five_hour',
                  'label': '5h Limit',
                  'unit': 'percent',
                  'status': 'unavailable',
                  'usedPercent': null,
                  'remainingPercent': null,
                },
              ],
            },
            {
              'id': 'acct_stale',
              'sourceId': 'src_cpa1',
              'sourceKind': 'claude_statusline',
              'provider': 'claude',
              'providerLabel': 'Claude',
              'alias': 'Work',
              'enabled': true,
              'connectionStatus': 'connected',
              'quotaStatus': 'stale',
              'freshness': 'stale',
              'windows': [
                {
                  'id': 'five_hour',
                  'kind': 'five_hour',
                  'label': '5h Limit',
                  'unit': 'percent',
                  'status': 'stale',
                  'usedPercent': 78.0,
                  'remainingPercent': 22.0,
                },
              ],
            },
            {
              'id': 'acct_429',
              'sourceId': 'src_cpa1',
              'sourceKind': 'cliproxy_passive',
              'provider': 'claude',
              'providerLabel': 'Claude',
              'alias': 'Busy',
              'enabled': true,
              'connectionStatus': 'connected',
              'quotaStatus': 'rate_limited',
              'freshness': 'unavailable',
              'windows': const [],
            },
            {
              'id': 'acct_auth',
              'sourceId': 'src_cpa1',
              'sourceKind': 'cliproxy_passive',
              'provider': 'codex',
              'providerLabel': 'Codex',
              'alias': 'Expired',
              'enabled': true,
              'connectionStatus': 'auth_required',
              'quotaStatus': 'auth_required',
              'freshness': 'unavailable',
              'windows': const [],
            },
          ],
    };

class _MockServer {
  Map<String, dynamic> snapshot;
  List<DeckProfile> profiles;
  final List<String> pressed = [];
  final List<Map<String, dynamic>> postedSources = [];
  final List<Map<String, dynamic>> testedSources = [];
  final List<Map<String, dynamic>> updatedSources = [];
  int refreshCalls = 0;
  bool throttleRefresh = false;

  _MockServer({
    Map<String, dynamic>? snapshot,
    List<DeckProfile>? profiles,
  })  : snapshot = snapshot ?? _sampleSnapshotJson(),
        profiles = profiles ??
            [
              DeckProfile(
                id: 'default',
                name: 'Default',
                rows: 2,
                columns: 4,
                isDefault: true,
                buttons: [
                  DeckButton(
                    id: 'u1',
                    row: 0,
                    column: 0,
                    label: 'Music',
                    iconName: 'music_note',
                    action: DeckAction(type: 'media'),
                  ),
                ],
              ),
              DeckProfile(
                id: 'ai_usage',
                name: 'AI Usage',
                rows: 2,
                columns: 4,
                buttons: [
                  DeckButton(
                    id: 'tile_claude',
                    row: 0,
                    column: 0,
                    columnSpan: 2,
                    rowSpan: 1,
                    dynamicType: aiLimitsDynamicType,
                    dynamicParameters: const {
                      'accountId': 'acct_claude_1',
                      'sourceId': 'src_cpa1',
                      'provider': 'claude',
                      'alias': 'Personal',
                    },
                  ),
                  DeckButton(
                    id: 'tile_codex',
                    row: 0,
                    column: 2,
                    columnSpan: 2,
                    rowSpan: 1,
                    dynamicType: aiLimitsDynamicType,
                    dynamicParameters: const {
                      'accountId': 'acct_codex_pro',
                      'sourceId': 'src_cpa1',
                      'provider': 'codex',
                      'alias': 'Pro Account',
                    },
                  ),
                ],
              ),
            ];

  DeckOSClient buildClient() {
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        final path = options.path;
        final method = options.method.toUpperCase();
        if (path == '/api/ai-limits' && method == 'GET') {
          return handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: snapshot),
          );
        }
        if (path == '/api/ai-limits/sources/test' && method == 'POST') {
          final body = Map<String, dynamic>.from(options.data as Map);
          testedSources.add(body);
          return handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'ok': true,
                'reachable': true,
                'status': 'connected',
                'message': 'Connected via CLIProxyAPI v8',
                'detectedApiVersion': 'v8',
                'accounts': (snapshot['accounts'] as List).take(2).toList(),
              },
            ),
          );
        }
        if (path == '/api/ai-limits/sources' && method == 'POST') {
          final body = Map<String, dynamic>.from(options.data as Map);
          postedSources.add(body);
          final created = {
            'id': 'src_new_1',
            'kind': body['kind'],
            'label': body['label'],
            'enabled': true,
            'hasCredential': (body['credential'] as String?)?.isNotEmpty == true,
            'baseUrl': body['baseUrl'],
            'status': 'connected',
            'accountCount': 1,
          };
          final newAcct = (snapshot['accounts'] as List).first;
          snapshot = {
            ...snapshot,
            'sources': [...(snapshot['sources'] as List), created],
          };
          return handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 201,
              data: {
                'source': created,
                'accounts': [newAcct],
                'snapshot': snapshot,
              },
            ),
          );
        }
        if (path.startsWith('/api/ai-limits/sources/') && method == 'PUT') {
          final body = Map<String, dynamic>.from(options.data as Map);
          updatedSources.add(body);
          final updated = {
            ...(snapshot['sources'] as List).first as Map<String, dynamic>,
            'label': body['label'],
            'hasCredential': body['clearCredential'] == true
                ? false
                : ((body['credential'] as String?)?.isNotEmpty == true || true),
          };
          snapshot = {
            ...snapshot,
            'sources': [updated],
          };
          return handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'source': updated,
                'accounts': snapshot['accounts'],
                'snapshot': snapshot,
              },
            ),
          );
        }
        if (path.endsWith('/refresh') && method == 'POST') {
          refreshCalls++;
          if (throttleRefresh) {
            return handler.reject(DioException(
              requestOptions: options,
              type: DioExceptionType.badResponse,
              response: Response(
                requestOptions: options,
                statusCode: 429,
                data: {
                  'errorCode': 'cooldown_active',
                  'message': 'Please wait 12s before refreshing again.',
                  'retryAfterSeconds': 12,
                  'nextRefreshAllowedAt':
                      DateTime.now().toUtc().add(const Duration(seconds: 12)).toIso8601String(),
                  'snapshot': snapshot,
                },
              ),
            ));
          }
          return handler.resolve(
            Response(requestOptions: options, statusCode: 200, data: snapshot),
          );
        }
        if (path == '/api/StreamDeck/profiles' && method == 'GET') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: profiles.map((p) => jsonDecode(jsonEncode(p.toJson()))).toList(),
          ));
        }
        if (path == '/api/StreamDeck/profiles' && method == 'POST') {
          final saved = DeckProfile.fromJson(
            Map<String, dynamic>.from(options.data as Map),
          );
          final idx = profiles.indexWhere((p) => p.id == saved.id);
          if (idx >= 0) {
            profiles[idx] = saved;
          } else {
            profiles.add(saved);
          }
          return handler.resolve(Response(requestOptions: options, statusCode: 200));
        }
        if (path == '/api/StreamDeck/layout' && method == 'GET') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'rows': 2, 'columns': 4},
          ));
        }
        if (path == '/api/StreamDeck/press') {
          pressed.add('${(options.data as Map)['buttonId']}');
          return handler.resolve(Response(requestOptions: options, statusCode: 200));
        }
        return handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: const []),
        );
      },
    ));
    return DeckOSClient(baseUrl: 'http://localhost', dio: dio);
  }
}

void _registerMock(_MockServer server) {
  final client = server.buildClient();
  GetIt.I.registerSingleton<DeckOSClient>(client);
  GetIt.I.registerSingleton<SignalRService>(SignalRService());
  AiLimitsStore.resetForTest(client: AiLimitsClient(client));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.choice.value = 'en';
  });

  tearDown(() async {
    AiLimitsStore.resetForTest();
    await ThemeController.instance.setDeckOnly(false);
    await ThemeController.instance.setCustomGrid(null);
    await GetIt.I.reset();
    AppLanguage.choice.value = 'pt';
  });

  test('parses real v1 /api/ai-limits snapshot cleanly and tile params stay secret-free', () {
    final snap = AiLimitsSnapshot.fromJson(_sampleSnapshotJson());
    expect(snap.schemaVersion, 1);
    expect(snap.capabilities.platform, 'windows');
    expect(snap.capabilities.detected.cliProxyReachable, isTrue);
    expect(snap.capabilities.detected.cliProxySuggestedUrl, 'http://127.0.0.1:8317');
    expect(snap.sources.length, 1);
    expect(snap.sources.first.hasCredential, isTrue);
    expect(snap.accounts.length, 7);

    final claude = snap.accountById('acct_claude_1')!;
    expect(claude.windows.length, 2);
    expect(claude.windowByKind('five_hour')!.usedPercent, 42.0);
    expect(claude.windowByKind('five_hour')!.remainingPercent, 58.0);

    final codexPro = snap.accountById('acct_codex_pro')!;
    expect(codexPro.windowByKind('five_hour')!.isNotApplicable, isTrue);
    expect(codexPro.windowByKind('five_hour')!.hasPercent, isFalse);
    expect(codexPro.windowByKind('weekly')!.usedPercent, 38.0);

    final btn = AiLimitsStore.buildAccountTileButton(
      claude,
      row: 0,
      column: 0,
      columnSpan: 2,
      rowSpan: 1,
    );
    expect(btn.dynamicType, aiLimitsDynamicType);
    expect(btn.columnSpan, 2);
    expect(btn.rowSpan, 1);
    final params = btn.dynamicParameters!;
    expect(params['accountId'], 'acct_claude_1');
    expect(params.containsKey('credential'), isFalse);
    expect(params.containsKey('token'), isFalse);
    expect(params.containsKey('email'), isFalse);
    expect(params.values.any((v) => v.contains('@')), isFalse);
  });

  testWidgets(
      'renders honest states across available, remaining, no-5h, local-only, unavailable, stale, 429, auth, removed, loading, unbound',
      (tester) async {
    final server = _MockServer();
    _registerMock(server);
    await tester.runAsync(() => AiLimitsStore.instance.load());

    Future<void> pumpTile(DeckButton button, {Size size = const Size(290, 145)}) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: DynamicDeckButton(
                button: button,
                onTap: () {},
                onLongPress: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    // 1. Claude Personal (wide 2x1, used %): 2 bars with non-zero CapsuleBar fill height.
    await pumpTile(DeckButton(
      id: 't1',
      row: 0,
      column: 0,
      columnSpan: 2,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {'accountId': 'acct_claude_1'},
    ));
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('42% used'), findsOneWidget);
    expect(find.text('61% used'), findsOneWidget);
    expect(find.byType(CapsuleBar), findsNWidgets(2));
    final fillBox = find.descendant(
      of: find.byType(CapsuleBar).first,
      matching: find.byType(FractionallySizedBox),
    );
    expect(tester.getSize(fillBox).height, greaterThanOrEqualTo(5.0));

    // 2. Same Claude account in remaining % mode.
    await pumpTile(DeckButton(
      id: 't1_rem',
      row: 0,
      column: 0,
      columnSpan: 2,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {
        'accountId': 'acct_claude_1',
        'displayMode': 'remaining',
      },
    ));
    expect(find.text('58% left'), findsOneWidget);
    expect(find.text('39% left'), findsOneWidget);

    // 3. Codex Pro: No 5h limit (no fake 0%), Weekly 38% used (1 bar).
    await pumpTile(DeckButton(
      id: 't2',
      row: 0,
      column: 0,
      columnSpan: 2,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {'accountId': 'acct_codex_pro'},
    ));
    expect(find.text('No 5h limit'), findsOneWidget);
    expect(find.text('38% used'), findsOneWidget);
    expect(find.byType(CapsuleBar), findsOneWidget);

    // 4. Gemini CLI: local daily requests only (no invented denominator, 0 percent bars).
    await pumpTile(DeckButton(
      id: 't3',
      row: 0,
      column: 0,
      columnSpan: 2,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {'accountId': 'acct_gemini_cli'},
    ));
    expect(find.text('340 req'), findsOneWidget);
    expect(find.byType(CapsuleBar), findsNothing);

    // 5. Antigravity: unavailable / manual dashboard only (no fake 0%).
    await pumpTile(DeckButton(
      id: 't4',
      row: 0,
      column: 0,
      columnSpan: 2,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {'accountId': 'acct_antigravity'},
    ));
    expect(find.text('Unavailable'), findsOneWidget);
    expect(find.text('0%'), findsNothing);
    expect(find.byType(CapsuleBar), findsNothing);

    // 6. Stale: keeps last observed 78% used with Stale badge (never auto-zeroed).
    await pumpTile(DeckButton(
      id: 't5',
      row: 0,
      column: 0,
      columnSpan: 2,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {'accountId': 'acct_stale'},
    ));
    expect(find.text('Stale'), findsOneWidget);
    expect(find.text('78% used'), findsOneWidget);

    // 7. Rate limited (429) & Auth required.
    await pumpTile(DeckButton(
      id: 't6',
      row: 0,
      column: 0,
      columnSpan: 2,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {'accountId': 'acct_429'},
    ));
    expect(find.text('Rate limited (429)'), findsOneWidget);

    await pumpTile(DeckButton(
      id: 't7',
      row: 0,
      column: 0,
      columnSpan: 2,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {'accountId': 'acct_auth'},
    ));
    expect(find.text('Authentication required'), findsOneWidget);

    // 8. Removed account -> repair path without crashing.
    await pumpTile(DeckButton(
      id: 't8',
      row: 0,
      column: 0,
      columnSpan: 2,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {'accountId': 'acct_deleted', 'alias': 'Old'},
    ));
    expect(find.text('Repair'), findsOneWidget);

    // 9. Unbound tile -> Configure / Connect a source.
    await pumpTile(DeckButton(
      id: 't9',
      row: 0,
      column: 0,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {},
    ));
    expect(find.text('Connect a source'), findsOneWidget);
  });

  testWidgets(
      'Settings → AI Limits onboarding tests connection, sends secret once, clears input, preserves on edit, and supports Cancel safely',
      (tester) async {
    final server = _MockServer(
      snapshot: _sampleSnapshotJson(sources: const [], accounts: const []),
    );
    _registerMock(server);
    tester.view.physicalSize = const Size(800, 4000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Discoverable in ConfigPage with compact "Not configured" summary.
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: const ConfigPage(),
    ));
    await tester.pumpAndSettle();
    final configRow = find.text('AI Limits');
    await tester.scrollUntilVisible(configRow, 300, scrollable: find.byType(Scrollable).first);
    expect(configRow, findsOneWidget);

    // Navigate into Settings → AI Limits.
    await tester.tap(configRow);
    await tester.pumpAndSettle();
    expect(find.text('Connect a source'), findsAtLeastNWidgets(1));

    // Start onboarding wizard and pick CLIProxyAPI.
    await tester.tap(find.text('Connect a source').first);
    await tester.pumpAndSettle();
    expect(find.text('CLIProxyAPI (Passive Local)'), findsOneWidget);
    await tester.tap(find.text('CLIProxyAPI (Passive Local)'));
    await tester.pumpAndSettle();

    // Plain loopback help explains 127.0.0.1 refers to PC, not phone.
    expect(find.textContaining('127.0.0.1'), findsAtLeastNWidgets(1));

    // Enter masked management key and test connection.
    final secretFields = find.byType(TextFormField);
    await tester.enterText(secretFields.at(2), 'super-secret-mgmt-key');
    await tester.pump();
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();

    expect(server.testedSources.length, 1);
    expect(server.testedSources.first['credential'], 'super-secret-mgmt-key');
    expect(find.text('Connected via CLIProxyAPI v8'), findsOneWidget);

    // Save source -> submits secret once and does not leak to SharedPreferences.
    await tester.ensureVisible(find.text('Save source'));
    await tester.tap(find.text('Save source'));
    await tester.pumpAndSettle();

    expect(server.postedSources.length, 1);
    expect(server.postedSources.first['credential'], 'super-secret-mgmt-key');
    final prefs = await SharedPreferences.getInstance();
    for (final k in prefs.getKeys()) {
      expect('${prefs.get(k)}', isNot(contains('super-secret-mgmt-key')));
    }
  });

  testWidgets(
      'editing and rebinding ai_limits tile preserves columnSpan/rowSpan and persists via SlotOps',
      (tester) async {
    final server = _MockServer();
    _registerMock(server);
    await tester.runAsync(() => AiLimitsStore.instance.load());

    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    DeckButton? saved;
    final original = DeckButton(
      id: 'b_ai_1',
      row: 0,
      column: 0,
      columnSpan: 2,
      rowSpan: 1,
      dynamicType: aiLimitsDynamicType,
      dynamicParameters: const {
        'accountId': 'acct_claude_1',
        'sourceId': 'src_cpa1',
      },
    );

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: Scaffold(
        body: ButtonPropertyPanel(
          button: original,
          onSave: (b) => saved = b,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Switch display mode to Left %.
    await tester.tap(find.text('Left %'));
    await tester.pumpAndSettle();

    // Save button and verify layout spans are completely preserved.
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, isNotNull);
    expect(saved!.columnSpan, 2);
    expect(saved!.rowSpan, 1);
    expect(saved!.dynamicType, aiLimitsDynamicType);
    expect(saved!.dynamicParameters?['displayMode'], 'remaining');
    expect(saved!.dynamicParameters?['accountId'], 'acct_claude_1');

    // Drag/move 2x1 tile via normal SlotOps.moveSafely preserves dynamicParameters and spans.
    final moved = SlotOps.moveSafely(
      [saved!],
      (row: 0, column: 0),
      (row: 1, column: 2),
      rows: 2,
      columns: 4,
    );
    expect(moved, isNotNull);
    expect((moved!.first.row, moved.first.column), (1, 2));
    expect((moved.first.columnSpan, moved.first.rowSpan), (2, 1));
    expect(moved.first.dynamicParameters?['accountId'], 'acct_claude_1');
  });

  testWidgets(
      'deck_only=true AI Usage page works in portrait, landscape, 1.8x font, detail sheet refresh cooldown, and 5s chrome hide',
      (tester) async {
    await ThemeController.instance.setDeckOnly(true);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final server = _MockServer()..throttleRefresh = true;
    _registerMock(server);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
      home: const HomePage(),
    ));
    await tester.pumpAndSettle();

    // Swipe from Default page to real AI Usage page.
    await tester.drag(find.byType(PageView), const Offset(-380, 0));
    await tester.pumpAndSettle();

    expect(find.text('AI Usage'), findsOneWidget);
    expect(find.text('42% used'), findsOneWidget);
    expect(find.text('No 5h limit'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Tapping live quota tile opens detail sheet without hitting /api/StreamDeck/press.
    await tester.tap(find.text('42% used'));
    await tester.pumpAndSettle();
    expect(server.pressed, isEmpty);
    expect(find.text('Source details'), findsOneWidget);

    // Tapping refresh handles 429 cooldown gracefully without crashing or storming.
    await tester.tap(find.byTooltip('Refresh now'));
    await tester.pumpAndSettle();
    expect(server.refreshCalls, 1);
    expect(find.textContaining('12s'), findsAtLeastNWidgets(1));

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    // 5s idle chrome auto-hide still works cleanly in deck_only=true.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final topOpacity = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('deck-top-chrome')),
    );
    expect(topOpacity.opacity, 0.0);

    // Landscape + light theme + 1.8x text scaling renders cleanly without overflow.
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(
        size: Size(844, 390),
        textScaler: TextScaler.linear(1.8),
        disableAnimations: true,
      ),
      child: MaterialApp(
        theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.light),
        home: const HomePage(key: ValueKey('ai-usage-landscape-large')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty AI Usage page shows Connect a source primary action and opens settings',
      (tester) async {
    await ThemeController.instance.setDeckOnly(true);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final server = _MockServer(
      snapshot: _sampleSnapshotJson(sources: const [], accounts: const []),
      profiles: [
        DeckProfile(
          id: 'default',
          name: 'Default',
          rows: 2,
          columns: 4,
          buttons: [
            DeckButton(
              id: 'u1',
              row: 0,
              column: 0,
              label: 'Music',
              action: DeckAction(type: 'media'),
            ),
          ],
        ),
        DeckProfile(
          id: 'ai_usage',
          name: 'AI Usage',
          rows: 2,
          columns: 4,
          buttons: const [],
        ),
      ],
    );
    _registerMock(server);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: const HomePage(),
    ));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(PageView), const Offset(-380, 0));
    await tester.pumpAndSettle();

    expect(find.text('Connect a source'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first 401/auth_failed locks Test Connection until key or URL is edited',
      (tester) async {
    var testCalls = 0;
    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/api/ai-limits' && options.method == 'GET') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: _sampleSnapshotJson(sources: const [], accounts: const []),
          ));
        }
        if (options.path == '/api/ai-limits/sources/test' && options.method == 'POST') {
          testCalls++;
          final body = Map<String, dynamic>.from(options.data as Map);
          final ok = body['credential'] == 'good-key';
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: ok
                ? {
                    'ok': true,
                    'reachable': true,
                    'status': 'connected',
                    'message': 'Connected',
                    'accounts': const [],
                  }
                : {
                    'ok': false,
                    'reachable': true,
                    'status': 'auth_required',
                    'errorCode': 'auth_failed',
                    'message': 'Invalid management key.',
                    'accounts': const [],
                  },
          ));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: const []));
      },
    ));
    final client = DeckOSClient(baseUrl: 'http://localhost', dio: dio);
    GetIt.I.registerSingleton<DeckOSClient>(client);
    GetIt.I.registerSingleton<SignalRService>(SignalRService());
    AiLimitsStore.resetForTest(client: AiLimitsClient(client));

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: const AiLimitsSettingsPage(openWizardOnStart: true),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('CLIProxyAPI (Passive Local)'));
    await tester.pumpAndSettle();

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(2), 'bad-key');
    await tester.pump();

    await tester.ensureVisible(find.text('Test connection'));
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    expect(testCalls, 1);
    expect(find.textContaining('Edit the management key or URL'), findsOneWidget);

    // Tapping Test connection again with the exact same rejected key is blocked client-side.
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    expect(testCalls, 1);

    // Editing the key unlocks Test connection and succeeds cleanly.
    await tester.enterText(fields.at(2), 'good-key');
    await tester.pump();
    await tester.tap(find.text('Test connection'));
    await tester.pumpAndSettle();
    expect(testCalls, 2);
  });
}
