import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/home/home_page.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/widgets/ai_limits_demo_tile.dart';
import 'package:deckos/src/stream_deck/widgets/dynamic_deck_button.dart';
import 'package:deckos/src/stream_deck/widgets/editor/info_section.dart';
import 'package:deckos/src/stream_deck/widgets/usage_bars.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _registerMockBackendWithDemoPage({List<String>? pressed}) {
  final profiles = [
    DeckProfile(
      id: 'user-default',
      name: 'Default',
      rows: 2,
      columns: 4,
      isDefault: true,
      buttons: [
        DeckButton(
          id: 'u1',
          row: 0,
          column: 0,
          label: 'T3 Code',
          iconName: 'code',
          action: DeckAction(type: 'media'),
        ),
        DeckButton(
          id: 'u2',
          row: 0,
          column: 1,
          label: 'Timer',
          iconName: 'timer',
          action: DeckAction(type: 'media'),
        ),
      ],
    ),
    buildAiLimitsDemoProfile(),
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
    AppLanguage.choice.value = 'en';
    aiLimitsDemoShowRemaining.value = false;
  });

  tearDown(() async {
    aiLimitsDemoShowRemaining.value = false;
    await ThemeController.instance.setDeckOnly(false);
    await ThemeController.instance.setCustomGrid(null);
    await GetIt.I.reset();
    AppLanguage.choice.value = 'pt';
  });

  test('demo profile fixture template stays isolated from genuine ai_usage and secrets', () {
    final profile = buildAiLimitsDemoProfile();
    expect(profile.id, aiLimitsDemoProfileId);
    expect(profile.name, aiLimitsDemoProfileName);
    expect(profile.rows, 2);
    expect(profile.columns, 4);
    expect(profile.buttons.length, 8);

    final ids = <String>{};
    for (final b in profile.buttons) {
      expect(ids.add(b.id), isTrue);
      expect(b.dynamicType, aiLimitsDemoDynamicType);
      expect(b.dynamicType, isNot('ai_usage'));
      expect(b.action, isNull);
      expect(b.label, isNot(contains('@')));
    }

    // Verify research-accurate window status invariants on the fixture dataset.
    final byId = {for (final s in aiLimitsDemoSamples) s.id: s};
    expect(byId['claude_personal']!.fiveHour.status, AiLimitWindowStatus.percent);
    expect(byId['claude_personal']!.weekly.status, AiLimitWindowStatus.percent);
    expect(byId['claude_work']!.freshness, AiLimitFreshness.stale);
    expect(byId['codex_personal']!.fiveHour.status, AiLimitWindowStatus.notApplicable);
    expect(byId['codex_personal']!.weekly.status, AiLimitWindowStatus.percent);
    expect(byId['codex_secondary']!.fiveHour.status, AiLimitWindowStatus.percent);
    expect(byId['gemini_cli']!.fiveHour.status, AiLimitWindowStatus.notApplicable);
    expect(byId['gemini_cli']!.weekly.status, AiLimitWindowStatus.notApplicable);
    expect(byId['google_antigravity']!.fiveHour.status, AiLimitWindowStatus.unavailable);
    expect(byId['google_antigravity']!.weekly.status, AiLimitWindowStatus.unavailable);
    expect(byId['github_copilot']!.fiveHour.status, AiLimitWindowStatus.notApplicable);
    expect(byId['github_copilot']!.weekly.status, AiLimitWindowStatus.notApplicable);
    expect(byId['cursor_personal']!.fiveHour.status, AiLimitWindowStatus.notApplicable);
    expect(byId['cursor_personal']!.weekly.status, AiLimitWindowStatus.unavailable);
  });

  testWidgets('honest tile rendering: percent bars only where supported, never fake 0% for unknown/N/A',
      (tester) async {
    Future<void> pumpTile(String sampleId) async {
      final button = buildAiLimitsDemoProfile()
          .buttons
          .firstWhere((b) => b.dynamicParameters?['sample'] == sampleId);
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 165,
              height: 165,
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

    // Claude Personal: both 5h and Weekly bars present with clear "% used" convention
    // and non-zero colored fill height inside CapsuleBar.
    await pumpTile('claude_personal');
    expect(find.text('Claude'), findsOneWidget);
    expect(find.text('DEMO'), findsOneWidget);
    expect(find.text('42% used'), findsOneWidget);
    expect(find.text('61% used'), findsOneWidget);
    expect(find.byType(CapsuleBar), findsNWidgets(2));
    final firstBar = find.byType(CapsuleBar).first;
    final fillBox = find.descendant(
      of: firstBar,
      matching: find.byType(FractionallySizedBox),
    );
    expect(tester.getSize(fillBox).height, greaterThanOrEqualTo(4.0));
    expect(tester.getSize(fillBox).width, greaterThan(20.0));

    // Codex Personal (Pro): 5h Not applicable (no bar), Weekly 38% used (1 bar).
    await pumpTile('codex_personal');
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Not applicable'), findsOneWidget);
    expect(find.text('38% used'), findsOneWidget);
    expect(find.byType(CapsuleBar), findsOneWidget);

    // Gemini CLI: both 5h and Weekly Not applicable (zero bars), compact local daily note.
    await pumpTile('gemini_cli');
    expect(find.text('Gemini CLI'), findsOneWidget);
    expect(find.text('Not applicable'), findsNWidgets(2));
    expect(find.text('Today: 340 req (local)'), findsOneWidget);
    expect(find.byType(CapsuleBar), findsNothing);

    // Google Antigravity: both 5h and Weekly Unavailable (zero bars, no 0%).
    await pumpTile('google_antigravity');
    expect(find.text('Antigravity'), findsOneWidget);
    expect(find.text('Unavailable'), findsNWidgets(2));
    expect(find.text('0%'), findsNothing);
    expect(find.byType(CapsuleBar), findsNothing);
  });

  testWidgets('deck_only=true + AI Limits Demo page works in portrait, landscape, light/dark, and 1.8x text without black screen or overflow',
      (tester) async {
    await ThemeController.instance.setDeckOnly(true);
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final pressed = <String>[];
    _registerMockBackendWithDemoPage(pressed: pressed);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
      home: const HomePage(),
    ));
    await tester.pumpAndSettle();

    // User's Default page renders untouched, no black screen.
    expect(find.text('Default'), findsOneWidget);
    expect(find.text('T3 Code'), findsOneWidget);

    // Normal user button still presses through backend.
    await tester.tap(find.text('T3 Code'));
    await tester.pumpAndSettle();
    expect(pressed, ['u1']);

    // Swipe to the extra AI Limits Demo page via existing deck paging.
    await tester.drag(find.byType(PageView), const Offset(-380, 0));
    await tester.pumpAndSettle();

    expect(find.text('AI Limits Demo'), findsOneWidget);
    expect(find.text('Claude'), findsNWidgets(2));
    expect(find.text('Codex'), findsNWidgets(2));
    expect(find.text('Gemini CLI'), findsOneWidget);
    expect(find.text('Antigravity'), findsOneWidget);
    expect(find.text('Copilot'), findsOneWidget);
    expect(find.text('Cursor'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Tapping a demo tile opens the honest demo detail sheet (does not hit backend /press).
    await tester.tap(find.text('42% used'));
    await tester.pumpAndSettle();
    expect(find.text('Demo data'), findsOneWidget);
    expect(pressed, ['u1']);

    // Switching to Left % inside the sheet updates tile labels immediately.
    await tester.tap(find.text('Left %'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('58% left'), findsOneWidget);

    // 5s idle chrome hide still works on the demo page.
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
        home: const HomePage(key: ValueKey('landscape-light-large')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('AI Limits Demo'), findsOneWidget);
  });

  testWidgets('InfoSection edits ai_limits_demo button without dropdown assertion error',
      (tester) async {
    String? changedType;
    Map<String, String> changedParams = {};

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: InfoSection(
            type: aiLimitsDemoDynamicType,
            params: const {'sample': 'codex_personal'},
            savedType: aiLimitsDemoDynamicType,
            remote: false,
            onChanged: (t, p) {
              changedType = t;
              changedParams = p;
            },
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('AI limits (Demo)'), findsAtLeastNWidgets(1));
    expect(find.text('Codex · Personal (Pro)'), findsOneWidget);
    expect(changedType, isNull);
    expect(changedParams, isEmpty);
  });
}
