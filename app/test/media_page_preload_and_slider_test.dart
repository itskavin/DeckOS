import 'dart:async';
import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/home/home_controller.dart';
import 'package:deckos/src/home/home_page.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/deck_preloader.dart';
import 'package:deckos/src/stream_deck/slider_state_store.dart';
import 'package:deckos/src/stream_deck/stream_deck_controller.dart';
import 'package:deckos/src/stream_deck/stream_deck_page.dart';
import 'package:deckos/src/stream_deck/widgets/slider_deck_button.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<Map<String, dynamic>> _profilesToJson(List<DeckProfile> list) =>
    list.map((p) => jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>).toList();

List<DeckProfile> _fourPageUserDeck() => [
      DeckProfile(
        id: 'p1_default',
        name: 'Default',
        rows: 2,
        columns: 4,
        buttons: [
          DeckButton(
            id: 'b_default_1',
            row: 0,
            column: 0,
            label: 'Browser',
            iconName: 'public',
            action: DeckAction(type: 'launch_app'),
          ),
        ],
      ),
      DeckProfile(
        id: 'p2_keyboard',
        name: 'Keyboard',
        rows: 2,
        columns: 4,
        buttons: [
          DeckButton(
            id: 'b_key_1',
            row: 0,
            column: 0,
            label: 'ESC',
            action: DeckAction(type: 'key', parameters: {'key': 'ESC'}),
          ),
        ],
      ),
      DeckProfile(
        id: 'p3_layout',
        name: 'Layout Check',
        rows: 2,
        columns: 4,
        buttons: [
          DeckButton(
            id: 'b_layout_1',
            row: 0,
            column: 0,
            label: 'Record',
            action: DeckAction(type: 'obs', parameters: {'operation': 'toggleRecord'}),
          ),
        ],
      ),
      DeckProfile(
        id: 'p4_media',
        name: 'Media Controls',
        rows: 2,
        columns: 4,
        buttons: [
          DeckButton(
            id: 'b_media_prev',
            row: 0,
            column: 0,
            label: 'Prev',
            action: DeckAction(type: 'media', parameters: {'command': 'previous'}),
          ),
          DeckButton(
            id: 'b_media_play',
            row: 0,
            column: 1,
            label: 'Play',
            action: DeckAction(type: 'media', parameters: {'command': 'playpause'}),
          ),
          DeckButton(
            id: 'b_media_next',
            row: 0,
            column: 2,
            label: 'Next',
            action: DeckAction(type: 'media', parameters: {'command': 'next'}),
          ),
          DeckButton(
            id: 'b_media_slider',
            row: 1,
            column: 0,
            columnSpan: 3,
            rowSpan: 1,
            label: 'Volume',
            dynamicType: 'volume_slider',
            dynamicParameters: const {},
          ),
        ],
      ),
    ];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.choice.value = 'en';
    SliderStateStore.resetForTest();
    DeckPreloader.resetForTest();
    StreamDeckController.clearMemoryCacheForTest();
  });

  tearDown(() async {
    SliderStateStore.resetForTest();
    DeckPreloader.resetForTest();
    StreamDeckController.clearMemoryCacheForTest();
    await ThemeController.instance.setDeckOnly(false);
    await ThemeController.instance.setCustomGrid(null);
    await GetIt.I.reset();
  });

  testWidgets(
      '4th page Media Controls preloads non-blockingly and never double-reloads or remounts during/after swipe',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final profilesJson = _profilesToJson(_fourPageUserDeck());
    final sliderCompleter = Completer<Map<String, dynamic>>();
    var sliderGets = 0;
    var profileGets = 0;

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/api/StreamDeck/profiles' && options.method == 'GET') {
          profileGets++;
          return handler.resolve(Response(requestOptions: options, statusCode: 200, data: profilesJson));
        }
        if (options.path == '/api/StreamDeck/layout' && options.method == 'GET') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'rows': 2, 'columns': 4},
          ));
        }
        if (options.path == '/api/slider' && options.method == 'GET') {
          sliderGets++;
          if (sliderCompleter.isCompleted) {
            return handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'volume': 64, 'max': 100, 'mute': false, 'label': 'Speakers'},
            ));
          }
          sliderCompleter.future.then((data) {
            handler.resolve(Response(requestOptions: options, statusCode: 200, data: data));
          });
          return;
        }
        if (options.path == '/api/actions/schema') {
          return handler.resolve(Response(requestOptions: options, statusCode: 200, data: const []));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: const []));
      },
    ));

    final signalR = SignalRService();
    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(signalR);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
      home: StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: false),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    // Page 1 renders immediately without waiting for slow background slider prewarm!
    expect(find.text('Browser'), findsOneWidget);
    expect(sliderGets, 1, reason: 'Background prewarm must fetch Page 4 slider while on Page 1');

    // SignalR finishing its initial connect right after initState must NOT cause duplicate profile GET.
    signalR.connectionStatus.value = 'Connected';
    await tester.pump(const Duration(milliseconds: 50));
    expect(profileGets, 1);

    // Complete the prewarm slider fetch while still on Page 1.
    sliderCompleter.complete({'volume': 64, 'max': 100, 'mute': false, 'label': 'Speakers'});
    await tester.pump(const Duration(milliseconds: 50));

    // Tap the 4th page dot (Media Controls) and animate across multiple frames (0 < t < 1 -> t == 0).
    await tester.tap(find.byKey(const ValueKey('page-dot-3')));
    await tester.pump();
    // Cross three pages: page 4 is built near the end of the 480 ms transition.
    await tester.pump(const Duration(milliseconds: 360));

    // Capture the mounted SliderDeckButton State mid-transition.
    final sliderFinder = find.byType(SliderDeckButton);
    expect(sliderFinder, findsOneWidget);
    final stateMidTransition = tester.state(sliderFinder);
    // Already shows 64% on first appearance — NEVER flashes '—'!
    expect(find.text('64%'), findsWidgets);
    expect(find.text('—'), findsNothing);

    // Finish the page transition so _PageDepth reaches t == 0.
    await tester.pumpAndSettle();

    // State identity MUST be preserved across t -> 0 (proving zero unmount/remount double-reload).
    final stateAfterSettle = tester.state(sliderFinder);
    expect(identical(stateMidTransition, stateAfterSettle), isTrue);
    expect(find.text('64%'), findsWidgets);
    expect(find.text('—'), findsNothing);
    // Still only 1 GET /api/slider total (prewarmed once, reused on mount & across settle).
    expect(sliderGets, 1);
  });

  testWidgets('slider drag protects value under finger, handles cancel, and applies confirmed PUT',
      (tester) async {
    var getCount = 0;
    final putVolumes = <int>[];
    final staleGetCompleter = Completer<Map<String, dynamic>>();

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/api/slider' && options.method == 'GET') {
          getCount++;
          if (getCount == 1) {
            return handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'volume': 40, 'max': 100, 'mute': false},
            ));
          }
          // Subsequent GET stays in flight so we can complete it with stale data mid-drag.
          staleGetCompleter.future.then((data) {
            handler.resolve(Response(requestOptions: options, statusCode: 200, data: data));
          });
          return;
        }
        if (options.path == '/api/slider' && options.method == 'PUT') {
          final v = (options.data as Map)['volume'] as int;
          putVolumes.add(v);
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'volume': v, 'max': 100, 'mute': false},
          ));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: {}));
      },
    ));

    final signalR = SignalRService();
    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(signalR);

    final button = DeckButton(
      id: 's1',
      row: 0,
      column: 0,
      columnSpan: 3,
      rowSpan: 1,
      label: 'Volume',
      dynamicType: 'volume_slider',
      dynamicParameters: const {'target': 'output'},
    );

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            height: 80,
            child: SliderDeckButton(
              button: button,
              onTap: () {},
              onLongPress: () {},
              interactive: true,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('40%'), findsWidgets);

    // Trigger a refresh that stays in-flight (will return stale 40%).
    unawaited(SliderStateStore.instance.refresh('output', const {}));
    await tester.pump();

    // Start dragging horizontally across touch slop toward ~80%.
    final rect = tester.getRect(find.byType(SliderDeckButton));
    final gesture = await tester.startGesture(Offset(rect.left + rect.width * 0.4, rect.center.dy));
    await gesture.moveTo(Offset(rect.left + rect.width * 0.55, rect.center.dy));
    await tester.pump();
    await gesture.moveTo(Offset(rect.left + rect.width * 0.8, rect.center.dy));
    await tester.pump();

    // Complete the stale GET with old value 40% while user is still dragging!
    staleGetCompleter.complete({'volume': 40, 'max': 100, 'mute': false});
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump();

    // Slider MUST NOT reset back to 40% under the user's finger.
    expect(find.text('40%'), findsNothing);
    expect(putVolumes.isNotEmpty, isTrue);
    expect(putVolumes.last, greaterThanOrEqualTo(75));

    // Cancel the drag (e.g. gesture interruption) -> must release drag lock cleanly!
    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 100));
    expect(SliderStateStore.instance.isDragging('output'), isFalse);

    // Unmount slider -> polling must stop immediately (no timer leak).
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    expect(SliderStateStore.instance.isPolling, isFalse);
  });

  testWidgets(
      'preserves 0%, input mute, explicit 404 absence, real 503 error, and offline/reconnect recovery',
      (tester) async {
    var mode = 'zero';

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/api/slider' && options.method == 'GET') {
          final target = options.queryParameters['target'];
          if (target == 'input') {
            return handler.resolve(Response(
              requestOptions: options,
              statusCode: 200,
              data: {'volume': 55, 'max': 100, 'mute': true, 'label': 'Mic'},
            ));
          }
          switch (mode) {
            case 'zero':
              return handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data: {'volume': 0, 'max': 100, 'mute': false},
              ));
            case 'offline':
              return handler.reject(DioException.connectionError(
                requestOptions: options,
                reason: 'PC unreachable',
              ));
            case 'reconnected':
              return handler.resolve(Response(
                requestOptions: options,
                statusCode: 200,
                data: {'volume': 72, 'max': 100, 'mute': false},
              ));
            case 'missing':
              return handler.reject(DioException(
                requestOptions: options,
                response: Response(requestOptions: options, statusCode: 404),
                type: DioExceptionType.badResponse,
              ));
            case 'error503':
              return handler.reject(DioException(
                requestOptions: options,
                response: Response(
                  requestOptions: options,
                  statusCode: 503,
                  data: {'error': 'OBS disconnected'},
                ),
                type: DioExceptionType.badResponse,
              ));
          }
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: {}));
      },
    ));

    final signalR = SignalRService();
    signalR.connectionStatus.value = 'Connected';
    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(signalR);

    final outputBtn = DeckButton(
      id: 'out1',
      row: 0,
      column: 0,
      label: 'Master',
      dynamicType: 'volume_slider',
      dynamicParameters: const {'target': 'output'},
    );
    final inputBtn = DeckButton(
      id: 'in1',
      row: 0,
      column: 1,
      label: 'Mic',
      dynamicType: 'volume_slider',
      dynamicParameters: const {'target': 'input'},
    );

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: Scaffold(
        body: Row(
          children: [
            SizedBox(
              width: 120,
              height: 120,
              child: SliderDeckButton(button: outputBtn, onTap: () {}, onLongPress: () {}),
            ),
            SizedBox(
              width: 120,
              height: 120,
              child: SliderDeckButton(button: inputBtn, onTap: () {}, onLongPress: () {}),
            ),
          ],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // 1. 0% is a real value (NOT '—'), and muted input shows 55% + mic_slash_fill.
    expect(find.text('0%'), findsWidgets);
    expect(find.text('55%'), findsWidgets);
    expect(find.byIcon(CupertinoIcons.mic_slash_fill), findsWidgets);

    // 2. Transient offline error retains last valid reading (0%) without flickering to '—'.
    mode = 'offline';
    await tester.runAsync(() => SliderStateStore.instance.refresh('output', const {}));
    await tester.pumpAndSettle();
    expect(find.text('0%'), findsWidgets);
    expect(find.text('—'), findsNothing);

    // 3. Reconnect automatically fetches fresh live value (72%).
    signalR.connectionStatus.value = 'Disconnected';
    await tester.pump();
    mode = 'reconnected';
    signalR.connectionStatus.value = 'Connected';
    await tester.pumpAndSettle();
    expect(find.text('72%'), findsWidgets);

    // 4. Explicit 404 (target truly absent) clears to '—' (never fakes stale value).
    mode = 'missing';
    await tester.runAsync(() => SliderStateStore.instance.refresh('output', const {}));
    await tester.pumpAndSettle();
    expect(find.text('—'), findsWidgets);
    expect(find.text('72%'), findsNothing);

    // 5. Real 503 error is shown (never hidden to appear preloaded).
    mode = 'error503';
    await tester.runAsync(() => SliderStateStore.instance.refresh('output', const {}));
    await tester.pumpAndSettle();
    expect(find.text('OBS disconnected'), findsWidgets);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
  });

  test('single-flight coalescing, bounded preload caps, and cold offline graceful state', () async {
    var sliderGets = 0;
    var discordGets = 0;
    var muteGets = 0;
    final sliderGate = Completer<void>();

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (options.path == '/api/slider') {
          sliderGets++;
          await sliderGate.future;
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'volume': 50, 'max': 100, 'mute': false},
          ));
        }
        if (options.path == '/api/discord/state') {
          discordGets++;
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'connected': true, 'mute': false, 'deaf': false},
          ));
        }
        if (options.path.startsWith('/api/Software/mute-state/')) {
          muteGets++;
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'muted': true},
          ));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: {}));
      },
    ));

    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(SignalRService());

    // Single-flight coalescing: 3 concurrent calls for the same slider -> 1 HTTP GET.
    final f1 = SliderStateStore.instance.refresh('output', const {});
    final f2 = SliderStateStore.instance.refresh('output', const {});
    final f3 = SliderStateStore.instance.ensureLoaded('output', const {});
    sliderGate.complete();
    final results = await Future.wait([f1, f2, f3]);
    expect(sliderGets, 1);
    expect(results.every((r) => r?.volume == 50), isTrue);

    // Bounded prewarm cap: 20 distinct slider buttons + 5 duplicate discord + 4 duplicate mute buttons.
    final manyButtons = <DeckButton>[
      for (var i = 0; i < 20; i++)
        DeckButton(
          id: 'sl_$i',
          row: i ~/ 5,
          column: i % 5,
          dynamicType: 'volume_slider',
          dynamicParameters: {'target': 'app', 'app': 'app_$i'},
        ),
      for (var i = 0; i < 5; i++)
        DeckButton(
          id: 'dc_$i',
          row: 5,
          column: i,
          action: DeckAction(type: 'discord', parameters: {'operation': 'toggleMute'}),
        ),
      for (var i = 0; i < 4; i++)
        DeckButton(
          id: 'mx_$i',
          row: 6,
          column: i,
          action: DeckAction(
            type: 'mixer',
            parameters: {'operation': 'toggleMute', 'processName': 'spotify'},
          ),
        ),
    ];
    final profile = DeckProfile(
      id: 'big',
      name: 'Big',
      rows: 7,
      columns: 5,
      buttons: manyButtons,
    );

    sliderGets = 0;
    DeckPreloader.instance.prewarm(profiles: [profile], current: profile, decodeImages: false);
    // Allow microtasks / bounded worker pool to drain.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(sliderGets, DeckPreloader.maxSliderPrewarm);
    expect(discordGets, 1);
    expect(muteGets, 1);

    // LRU cap stays bounded even with > maxEntries distinct keys.
    for (var i = 0; i < SliderStateStore.maxEntries + 15; i++) {
      SliderStateStore.instance.setOptimistic('app', {'app': 'lru_$i'}, i % 100);
    }
    expect(SliderStateStore.instance.cachedCount, SliderStateStore.maxEntries);
  });

  test('HomeController single-flights overlapping fetches, retains last valid data, and syncs sliders',
      () async {
    var outCalls = 0;
    var sliderCalls = 0;
    final firstOut = Completer<void>();

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        if (options.path == '/api/v1/Mixer/out' && options.method == 'GET') {
          outCalls++;
          if (outCalls == 1) await firstOut.future;
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: [
              {
                'id': 'dev-1',
                'volume': 50,
                'mute': false,
                'config': {'enabled': true},
                'device': {'id': 'dev-1', 'title': 'Speakers', 'volume': 50, 'mute': false, 'channels': []},
              },
            ],
          ));
        }
        if (options.path == '/api/v1/Mixer/out/dev-1' && options.method == 'PUT') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'id': 'dev-1', 'title': 'Speakers', 'volume': 80, 'mute': false, 'channels': []},
          ));
        }
        if (options.path == '/api/slider' && options.method == 'GET') {
          sliderCalls++;
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'volume': 80, 'max': 100, 'mute': false},
          ));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: const []));
      },
    ));

    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(SignalRService());

    // Prime an audio slider in cache so HomeController.setVolume triggers refresh.
    await SliderStateStore.instance.refresh('output', const {});
    expect(sliderCalls, 1);

    final hc = HomeController();
    addTearDown(hc.dispose);

    // 3 overlapping fetchOutputs calls coalesce into 1 in-flight + 1 queued follow-up (never 3 parallel).
    final a = hc.fetchOutputs();
    final b = hc.fetchOutputs();
    final c = hc.fetchOutputs();
    firstOut.complete();
    await Future.wait([a, b, c]);
    expect(outCalls, 2);
    expect(hc.outputs.value.length, 1);

    // Audio tab setVolume triggers debounced audio slider store refresh.
    await hc.setVolume('dev-1', 80);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(sliderCalls, greaterThanOrEqualTo(2));
  });

  testWidgets('switching Deck -> Audio -> Deck preserves 4th page and preloaded slider on frame 0',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final profilesJson = _profilesToJson(_fourPageUserDeck());
    var sliderGets = 0;

    final dio = Dio();
    dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path == '/api/StreamDeck/profiles' && options.method == 'GET') {
          return handler.resolve(Response(requestOptions: options, statusCode: 200, data: profilesJson));
        }
        if (options.path == '/api/StreamDeck/layout' && options.method == 'GET') {
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'rows': 2, 'columns': 4},
          ));
        }
        if (options.path == '/api/slider' && options.method == 'GET') {
          sliderGets++;
          return handler.resolve(Response(
            requestOptions: options,
            statusCode: 200,
            data: {'volume': 77, 'max': 100, 'mute': false},
          ));
        }
        return handler.resolve(Response(requestOptions: options, statusCode: 200, data: const []));
      },
    ));

    GetIt.I.registerSingleton<DeckOSClient>(DeckOSClient(baseUrl: 'http://localhost', dio: dio));
    GetIt.I.registerSingleton<SignalRService>(SignalRService());

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
      home: const HomePage(),
    ));
    await tester.pumpAndSettle();

    // Go to 4th page (Media Controls).
    await tester.tap(find.byKey(const ValueKey('page-dot-3')));
    await tester.pumpAndSettle();
    expect(find.text('77%'), findsWidgets);
    expect(sliderGets, 1);

    // Switch to Audio tab.
    final rail = find.byKey(const ValueKey('home-side-nav'));
    await tester.tap(find.descendant(of: rail, matching: find.byTooltip('Audio')));
    await tester.pumpAndSettle();
    expect(find.text('Outputs'), findsOneWidget);

    // Switch back to Deck tab: opens directly on Media Controls with 77% on frame 0 (no spinner, no '—').
    await tester.tap(find.descendant(of: rail, matching: find.byTooltip('Deck')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('—'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('77%'), findsWidgets);
    expect(sliderGets, 1);
  });
}
