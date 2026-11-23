import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/home/home_page.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/stream_deck_page.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _PressRecord {
  final String profileId;
  final String buttonId;
  final String gesture;

  const _PressRecord(this.profileId, this.buttonId, this.gesture);
}

List<DeckProfile> _sampleProfiles() => [
      DeckProfile(
        id: 'p1',
        name: 'Apps',
        rows: 2,
        columns: 4,
        buttons: [
          DeckButton(
            id: 'b_app',
            row: 0,
            column: 0,
            label: 'Explorer',
            iconName: 'folder',
            action: DeckAction(
              type: 'launch_app',
              parameters: {'path': 'explorer.exe'},
            ),
          ),
          DeckButton(
            id: 'b_hotkey',
            row: 0,
            column: 1,
            label: 'Copy',
            iconName: 'keyboard',
            action: DeckAction(
              type: 'hotkey',
              parameters: {'keys': '^c'},
            ),
            longPressAction: DeckAction(
              type: 'hotkey',
              parameters: {'keys': '^v'},
            ),
          ),
        ],
      ),
      DeckProfile(
        id: 'p2',
        name: 'Media Controls',
        rows: 2,
        columns: 4,
        buttons: [
          DeckButton(
            id: 'b_play',
            row: 0,
            column: 0,
            label: 'Play',
            iconName: 'play_arrow',
            action: DeckAction(
              type: 'media',
              parameters: {'command': 'playpause'},
            ),
          ),
        ],
      ),
    ];

void _registerMockBackend({
  required List<_PressRecord> presses,
  int pressStatusCode = 200,
  bool failPressConnection = false,
}) {
  final profilesJson = _sampleProfiles()
      .map((p) => jsonDecode(jsonEncode(p.toJson())))
      .toList();

  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      if (options.path == '/api/StreamDeck/profiles' &&
          options.method == 'GET') {
        return handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: profilesJson,
        ));
      }
      if (options.path == '/api/StreamDeck/layout' && options.method == 'GET') {
        return handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: {'rows': 2, 'columns': 4},
        ));
      }
      if (options.path == '/api/StreamDeck/press') {
        final data = Map<String, dynamic>.from(options.data as Map);
        presses.add(_PressRecord(
          '${data['profileId']}',
          '${data['buttonId']}',
          '${data['gesture'] ?? 'tap'}',
        ));
        if (failPressConnection) {
          return handler.reject(DioException(
            requestOptions: options,
            type: DioExceptionType.receiveTimeout,
          ));
        }
        if (pressStatusCode >= 400) {
          return handler.reject(DioException(
            requestOptions: options,
            response: Response(
              requestOptions: options,
              statusCode: pressStatusCode,
              data: {'error': 'Execution failed'},
            ),
            type: DioExceptionType.badResponse,
          ));
        }
        return handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
        ));
      }
      if (options.path == '/api/actions/schema') {
        return handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: const [],
        ));
      }
      return handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: const [],
      ));
    },
  ));

  GetIt.I.registerSingleton<DeckOSClient>(
    DeckOSClient(baseUrl: 'http://localhost', dio: dio),
  );
  GetIt.I.registerSingleton<SignalRService>(SignalRService());
}

/// Wraps [child] with Android-like 8.0 dp touchSlop (matching Android
/// `ViewConfiguration.getScaledTouchSlop()`) to reproduce real phone behavior
/// that default `WidgetTester` (18 dp) otherwise masks.
Widget _androidMediaQuery(Widget child, {Size size = const Size(915, 412)}) {
  return MediaQuery(
    data: MediaQueryData(
      size: size,
      gestureSettings: const DeviceGestureSettings(touchSlop: 8.0),
    ),
    child: MaterialApp(
      theme: buildAppTheme(const ThemeSettings(showLabels: true), Brightness.dark),
      home: child,
    ),
  );
}

Future<void> _quickDriftedTap(
  WidgetTester tester,
  Offset start,
  Offset drift, {
  Duration hold = const Duration(milliseconds: 35),
}) async {
  final gesture = await tester.startGesture(start);
  await tester.pump(const Duration(milliseconds: 15));
  await gesture.moveBy(drift);
  await tester.pump(hold - const Duration(milliseconds: 15));
  await gesture.up();
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppLanguage.choice.value = 'en';
  });

  tearDown(() async {
    await ThemeController.instance.setDeckOnly(false);
    await ThemeController.instance.setCustomGrid(null);
    await GetIt.I.reset();
  });

  testWidgets(
      'quick light taps with 12-16 dp micro-drift under Android 8 dp slop register cleanly',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final presses = <_PressRecord>[];
    _registerMockBackend(presses: presses);

    await tester.pumpWidget(_androidMediaQuery(
      StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: true),
    ));
    await tester.pumpAndSettle();

    final explorerCenter = tester.getCenter(find.text('Explorer'));

    // Horizontal 12 dp micro-drift (would be stolen by PageView at Android 8 dp slop).
    await _quickDriftedTap(tester, explorerCenter, const Offset(12, 0));
    await tester.pumpAndSettle();

    // Vertical 14 dp micro-drift (would be self-rejected by TapGestureRecognizer at 8 dp slop).
    await _quickDriftedTap(tester, explorerCenter, const Offset(0, 14));
    await tester.pumpAndSettle();

    // Diagonal 16 dp micro-drift (~11.3, 11.3) while staying inside the tile.
    await _quickDriftedTap(tester, explorerCenter, const Offset(11, 11));
    await tester.pumpAndSettle();

    expect(presses.length, 3);
    expect(presses.every((p) => p.buttonId == 'b_app' && p.gesture == 'tap'), isTrue);
    // Page did not accidentally switch away from Apps.
    expect(find.text('Explorer'), findsOneWidget);
  });

  testWidgets(
      'quick tap (< 100 ms) triggers immediate onTap and still renders brief visual press pulse',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(_androidMediaQuery(
      Scaffold(
        body: Center(
          child: SizedBox.square(
            dimension: 110,
            child: DeckSquircleTile(
              icon: Icons.folder,
              label: 'Explorer',
              onTap: () => taps++,
            ),
          ),
        ),
      ),
    ));

    double scale() =>
        tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
    expect(scale(), 1.0);

    final center = tester.getCenter(find.byType(DeckSquircleTile));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 30));
    await gesture.up();
    await tester.pump();

    // Action fires immediately on PointerUp (zero delay).
    expect(taps, 1);
    // Visual depressed state is held briefly so quick taps visibly pulse.
    expect(scale(), lessThan(1.0));

    await tester.pump(ApplePressable.quickTapVisualHold);
    await tester.pumpAndSettle();
    expect(scale(), 1.0);
  });

  testWidgets(
      'intentional horizontal swipe changes page and never fires tile tap',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final presses = <_PressRecord>[];
    _registerMockBackend(presses: presses);

    await tester.pumpWidget(_androidMediaQuery(
      StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: true),
    ));
    await tester.pumpAndSettle();

    final start = tester.getCenter(find.text('Explorer'));
    await tester.flingFrom(start, const Offset(-320, 0), 1000);
    await tester.pumpAndSettle();

    expect(presses, isEmpty);
    expect(find.text('Play'), findsOneWidget);
  });

  testWidgets(
      'slide-off cancel and pointer cancel never fire tile tap; long press fires only longPress',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final presses = <_PressRecord>[];
    _registerMockBackend(presses: presses);

    await tester.pumpWidget(_androidMediaQuery(
      StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: true),
    ));
    await tester.pumpAndSettle();

    final copyCenter = tester.getCenter(find.text('Copy'));

    // 1. Slide far off vertically (65 dp > slop) -> cancelled, no press.
    final slideOff = await tester.startGesture(copyCenter);
    await tester.pump(const Duration(milliseconds: 25));
    await slideOff.moveBy(const Offset(0, 65));
    await tester.pump(const Duration(milliseconds: 25));
    await slideOff.up();
    await tester.pumpAndSettle();
    expect(presses, isEmpty);

    // 2. OS pointer cancel mid-press -> cancelled, no press.
    final cancelled = await tester.startGesture(copyCenter);
    await tester.pump(const Duration(milliseconds: 30));
    await cancelled.cancel();
    await tester.pumpAndSettle();
    expect(presses, isEmpty);

    // 3. Long press (>= 500 ms) -> fires longPress only, never tap.
    await tester.longPressAt(copyCenter);
    await tester.pumpAndSettle();
    expect(presses.length, 1);
    expect(presses.single.buttonId, 'b_hotkey');
    expect(presses.single.gesture, 'longPress');
  });

  testWidgets(
      'after 5 s idle chrome hide, top-row tile fires on first tap without edge-reveal intercept',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final presses = <_PressRecord>[];
    _registerMockBackend(presses: presses);

    await tester.pumpWidget(_androidMediaQuery(
      StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: true),
    ));
    await tester.pumpAndSettle();

    // Wait for 5 s idle hide.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();

    final tileRect = tester.getRect(
      find.ancestor(of: find.text('Explorer'), matching: find.byType(DeckSquircleTile)).first,
    );
    final edgeRect = tester.getRect(find.byKey(const ValueKey('deck-edge-reveal')));

    // Edge-reveal strip must not overlap the top of the tile.
    expect(edgeRect.bottom, lessThanOrEqualTo(tileRect.top + 0.5));

    // Light tap near top edge of top-row tile fires action on first tap.
    await _quickDriftedTap(
      tester,
      Offset(tileRect.center.dx, tileRect.top + 4),
      const Offset(10, 6),
    );
    await tester.pumpAndSettle();
    expect(presses.length, 1);
    expect(presses.single.buttonId, 'b_app');
  });

  testWidgets(
      'HTTP 500 or post-connect timeout shows failure feedback without auto-replay',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final presses = <_PressRecord>[];
    _registerMockBackend(presses: presses, pressStatusCode: 500);

    await tester.pumpWidget(_androidMediaQuery(
      StreamDeckPage(onToggleFullscreen: () {}, isFullscreen: true),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Explorer'));
    await tester.pumpAndSettle();

    // Strictly one request (no replay) and visible failure feedback.
    expect(presses.length, 1);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets(
      'HomePage (deckOnly=false) under Android 8 dp slop does not steal 12 dp rightward tile tap',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final presses = <_PressRecord>[];
    _registerMockBackend(presses: presses);

    await tester.pumpWidget(_androidMediaQuery(const HomePage()));
    await tester.pumpAndSettle();

    final explorerCenter = tester.getCenter(find.text('Explorer'));
    await _quickDriftedTap(tester, explorerCenter, const Offset(12, 0));
    await tester.pumpAndSettle();

    expect(presses.length, 1);
    expect(presses.single.buttonId, 'b_app');
    expect(find.text('Explorer'), findsOneWidget);
  });
}
