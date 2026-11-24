import 'dart:async';
import 'dart:convert';
import 'package:deckos/core/core.dart';
import 'package:deckos/core/ui/tile_shape.dart';
import 'package:deckos/src/ai_limits/ai_account_privacy.dart';
import 'package:deckos/src/ai_limits/ai_limits_client.dart';
import 'package:deckos/src/ai_limits/ai_limits_combined.dart';
import 'package:deckos/src/ai_limits/ai_limits_editor_fields.dart';
import 'package:deckos/src/ai_limits/ai_limits_models.dart';
import 'package:deckos/src/ai_limits/ai_limits_settings_page.dart';
import 'package:deckos/src/ai_limits/ai_limits_store.dart';
import 'package:deckos/src/ai_limits/ai_provider_style.dart';
import 'package:deckos/src/connection/pc_store.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/widgets/dynamic_deck_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> fixtureAccount(
  String id,
  String provider,
  int used, {
  bool named = false,
  bool disabled = false,
}) => {
  'id': id,
  'sourceId': 'fixture_source',
  'sourceKind': 'cliproxy_passive',
  'provider': provider,
  'providerLabel': provider,
  'alias': named ? 'Fixture Person' : '$provider $id',
  'defaultAlias': '$provider $id',
  'hasReportedName': named,
  'automaticDisplayName': named ? 'Fixture Person' : '$provider $id',
  'enabled': !disabled,
  'connectionStatus': disabled ? 'disabled' : 'connected',
  'quotaStatus': 'ok',
  'freshness': 'fresh',
  'windows': [
    {
      'id': 'five_hour',
      'kind': 'five_hour',
      'label': '5h',
      'unit': 'percent',
      'status': 'available',
      'usedPercent': used,
      'resetsAt': DateTime.now()
          .add(const Duration(hours: 2))
          .toIso8601String(),
    },
    {
      'id': 'weekly',
      'kind': 'weekly',
      'label': 'Weekly',
      'unit': 'percent',
      'status': provider == 'antigravity' ? 'unavailable' : 'available',
      if (provider != 'antigravity') 'usedPercent': used + 3,
    },
  ],
};

class FixtureServer {
  bool hidden = false;
  String? alias;
  Completer<void>? privacyGate;
  final profiles = [
    DeckProfile(
      id: 'existing',
      name: 'Existing page',
      buttons: [
        DeckButton(id: 'existing-tile', row: 0, column: 0, label: 'Keep'),
      ],
    ).toJson(),
  ];
  final bodies = <Map<String, dynamic>>[];
  Map<String, dynamic> get snapshot => {
    'hideAccountNames': hidden,
    'accounts': [
      {
        ...fixtureAccount('a', 'codex', 17, named: true),
        'alias': alias ?? (hidden ? 'codex a' : 'Fixture Person'),
        'customAlias': alias,
        'automaticDisplayName': hidden ? 'codex a' : 'Fixture Person',
      },
      fixtureAccount('b', 'codex', 71),
      fixtureAccount('c', 'claude', 33),
      fixtureAccount('d', 'antigravity', 42),
      fixtureAccount('e', 'claude', 60, disabled: true),
    ],
    'sources': [
      {
        'id': 'fixture_source',
        'kind': 'cliproxy_passive',
        'label': 'Fixture proxy',
        'status': 'connected',
      },
    ],
  };
  late final DeckOSClient client = DeckOSClient(
    baseUrl: 'http://fixture.local',
    dio: Dio()
      ..interceptors.add(
        InterceptorsWrapper(
          onRequest: (o, h) async {
            if (o.path.endsWith('/privacy') && privacyGate != null)
              await privacyGate!.future;
            if (o.path.endsWith('/privacy'))
              hidden = (o.data as Map)['hideAccountNames'] == true;
            if (o.path.endsWith('/accounts/a') && o.method == 'PUT') {
              final value = (o.data as Map)['alias'] as String?;
              if (value != null) alias = value.isEmpty ? null : value;
              return h.resolve(
                Response(
                  requestOptions: o,
                  statusCode: 200,
                  data: {
                    'account': (snapshot['accounts'] as List).first,
                    'snapshot': snapshot,
                  },
                ),
              );
            }
            if (o.path == '/api/StreamDeck/profiles' && o.method == 'GET')
              return h.resolve(
                Response(
                  requestOptions: o,
                  statusCode: 200,
                  data: jsonDecode(jsonEncode(profiles)),
                ),
              );
            if (o.path.contains('layout'))
              return h.resolve(
                Response(
                  requestOptions: o,
                  statusCode: 200,
                  data: {'columns': 4, 'rows': 2},
                ),
              );
            if (o.method == 'POST' || o.method == 'PUT') {
              bodies.add(Map<String, dynamic>.from(o.data as Map));
            }
            return h.resolve(
              Response(requestOptions: o, statusCode: 200, data: snapshot),
            );
          },
        ),
      ),
  );
}

Widget app(Widget child, {double scale = 1}) => MaterialApp(
  theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(body: child),
  ),
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppLanguage.load();
    AppLanguage.choice.value = 'en';
    PcStore.currentId = 'fixture_pc';
  });
  tearDown(() async {
    AiLimitsStore.resetForTest();
    await GetIt.I.reset();
    PcStore.currentId = null;
    AiAccountPrivacy.hideNames.value = true;
  });

  Future<FixtureServer> register() async {
    final server = FixtureServer();
    GetIt.I.registerSingleton<DeckOSClient>(server.client);
    GetIt.I.registerSingleton<SignalRService>(SignalRService());
    AiLimitsStore.resetForTest(client: AiLimitsClient(server.client));
    await AiLimitsStore.instance.load();
    return server;
  }

  test(
    'combined selection keeps missing IDs, interleaves providers and follows enabled accounts only when chosen',
    () {
      final snap = AiLimitsSnapshot.fromJson(FixtureServer().snapshot);
      const config = AiLimitsTileConfig(
        combined: true,
        accountIds: ['a', 'b', 'c', 'd', 'gone'],
      );
      expect(combinedAiAccounts(config, snap).map((a) => a?.id), [
        'a',
        'c',
        'd',
        null,
        'b',
      ]);
      expect(
        combinedAiAccounts(
          config.copyWith(allAccounts: true),
          snap,
        ).whereType<AiLimitsAccount>().map((a) => a.id).toSet(),
        {'a', 'b', 'c', 'd'},
      );
      final saved = AiLimitsTileConfig.fromParams(config.toParams());
      expect(saved.accountIds, config.accountIds);
      expect(saved.combined, isTrue);
      expect(
        AiLimitsTileConfig.fromParams({'accountId': 'legacy'}).combined,
        isFalse,
      );
      expect(
        AiLimitsTileConfig.fromParams({'accountId': 'legacy'}).accountId,
        'legacy',
      );
      final unavailable = snap.accountById('d')!.windows.last;
      expect(combinedWindowValue(unavailable, false), 'Unavailable');
    },
  );

  testWidgets(
    'combined metrics remain independent, all providers visible and compact/large text layouts do not overflow',
    (tester) async {
      await tester.runAsync(register);
      const cfg = AiLimitsTileConfig(combined: true, allAccounts: true);
      for (final shape in [null, 'square', 'rounded', 'squircle']) {
        for (final dimensions in [
          (400.0, 430.0, 1.0),
          (620.0, 280.0, 1.0),
          (320.0, 220.0, 2.0),
          (95.0, 95.0, 2.0),
        ]) {
          await tester.pumpWidget(
            app(
              Center(
                child: SizedBox(
                  width: dimensions.$1,
                  height: dimensions.$2,
                  child: DynamicDeckButton(
                    button: DeckButton(
                      id: 'combo',
                      row: 0,
                      column: 0,
                      dynamicType: aiLimitsDynamicType,
                      dynamicParameters: cfg.toParams(),
                      tileShape: shape,
                    ),
                    onTap: () {},
                    onLongPress: () {},
                  ),
                ),
              ),
              scale: dimensions.$3,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$shape $dimensions');
          if (dimensions.$1 == 400) {
            expect(find.textContaining('5h 17%'), findsOneWidget);
            expect(find.textContaining('5h 71%'), findsOneWidget);
            expect(find.textContaining('5h 33%'), findsOneWidget);
            expect(find.textContaining('5h 42%'), findsOneWidget);
          }
        }
      }
    },
  );

  testWidgets(
    'privacy changes hide already-open account objects, aliases stay usable and clearing restores masked fallback',
    (tester) async {
      await tester.runAsync(register);
      final capturedPreview =
          AiLimitsStore.instance.snapshot.value!.accounts.first;
      await tester.pumpWidget(
        app(Watch((context) => Text(capturedPreview.displayTitle))),
      );
      expect(find.text('Fixture Person'), findsOneWidget);
      await tester.runAsync(() => AiLimitsStore.instance.updatePrivacy(true));
      await tester.pumpAndSettle();
      expect(find.text('Fixture Person'), findsNothing);
      expect(find.text('codex a'), findsOneWidget);
      await tester.runAsync(
        () => AiLimitsStore.instance.updateAccount('a', alias: 'Travel'),
      );
      expect(
        AiLimitsStore.instance.snapshot.value!.accounts.first.displayTitle,
        'Travel',
      );
      await tester.runAsync(
        () => AiLimitsStore.instance.updateAccount('a', alias: ''),
      );
      expect(
        AiLimitsStore.instance.snapshot.value!.accounts.first.displayTitle,
        'codex a',
      );
      final tile = AiLimitsStore.buildAccountTileButton(
        capturedPreview,
        row: 2,
        column: 1,
      );
      expect(
        tile.dynamicParameters.toString(),
        isNot(contains('Fixture Person')),
      );
      expect(tile.dynamicParameters!['accountId'], 'a');
    },
  );

  testWidgets(
    'Settings exposes privacy and alias editor with clear action; account picker obeys masking',
    (tester) async {
      await tester.runAsync(register);
      await tester.runAsync(() => AiLimitsStore.instance.updatePrivacy(true));
      await tester.pumpWidget(app(const AiLimitsSettingsPage()));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Privacy and names'));
      await tester.pumpAndSettle();
      expect(find.text('Hide account names'), findsOneWidget);
      await tester.tap(find.text('Edit alias').first);
      await tester.pumpAndSettle();
      expect(find.text('Account alias'), findsOneWidget);
      expect(find.textContaining('Preview: codex a'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Travel');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        AiLimitsStore.instance.snapshot.value!.accounts.first.displayTitle,
        'Travel',
      );
      await tester.pumpWidget(
        app(
          SingleChildScrollView(
            child: AiLimitsEditorFields(
              params: const {'accountId': 'a'},
              onChanged: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fixture Person'), findsNothing);
      expect(find.text('Travel'), findsWidgets);
    },
  );

  test(
    'privacy response from a previous PC cannot overwrite the selected PC',
    () async {
      final server = await register();
      server.privacyGate = Completer<void>();
      final result = AiLimitsStore.instance.updatePrivacy(true);
      final checked = expectLater(result, throwsA(isA<AiLimitsApiException>()));
      PcStore.currentId = 'other_fixture_pc';
      server.privacyGate!.complete();
      await checked;
      expect(AiLimitsStore.instance.snapshot.value!.hideAccountNames, isFalse);
    },
  );

  test(
    'adding combined overview preserves existing profiles and binds only opaque account IDs',
    () async {
      final server = await register();
      final before = jsonEncode(server.profiles);
      final created = await AiLimitsStore.addCombinedAccountsPage(
        AiLimitsStore.instance.snapshot.value!.enabledAccounts,
        client: server.client,
      );
      expect(jsonEncode(server.profiles), before);
      expect(created.id, 'ai_overview');
      expect(created.customRows, 3);
      expect(created.buttons.single.rowSpan, 3);
      final cfg = AiLimitsTileConfig.fromParams(
        created.buttons.single.dynamicParameters,
      );
      expect(cfg.accountIds.toSet(), {'a', 'b', 'c', 'd'});
      expect(cfg.allAccounts, isFalse);
      expect(jsonEncode(created.toJson()), isNot(contains('Fixture Person')));
    },
  );

  testWidgets(
    'per-tile shape survives save and move, changes only one tile and preserves taps',
    (tester) async {
      final a = DeckButton(
        id: 'square',
        row: 0,
        column: 0,
        label: 'One',
        tileShape: 'square',
      );
      final restored = DeckButton.fromJson(
        a.toJson(),
      ).copyWith(row: 2, column: 3, columnSpan: 2);
      expect(restored.tileShape, 'square');
      expect(restored.id, 'square');
      var taps = 0;
      await tester.pumpWidget(
        app(
          Row(
            children: [
              SizedBox(
                width: 100,
                height: 100,
                child: DynamicDeckButton(
                  button: restored,
                  onTap: () => taps++,
                  onLongPress: () {},
                ),
              ),
              SizedBox(
                width: 100,
                height: 100,
                child: DynamicDeckButton(
                  button: DeckButton(
                    id: 'inherit',
                    row: 0,
                    column: 1,
                    label: 'Two',
                  ),
                  onTap: () {},
                  onLongPress: () {},
                ),
              ),
            ],
          ),
        ),
      );
      final scopes = tester
          .widgetList<DeckTileShapeScope>(find.byType(DeckTileShapeScope))
          .toList();
      expect(scopes.map((s) => s.shape), ['square', null]);
      await tester.tap(find.text('One'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
