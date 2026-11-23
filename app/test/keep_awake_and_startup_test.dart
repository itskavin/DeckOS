import 'dart:async';

import 'package:deckos/src/config/keep_awake.dart';
import 'package:deckos/src/connection/usb_route.dart';
import 'package:deckos/src/services/client_identity.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('KeepAwake lifecycle and default behavior', () {
    setUp(() {
      KeepAwake.resetForTest();
      KeepAwake.isConfiguratorOverride = false;
    });

    tearDown(() {
      KeepAwake.resetForTest();
    });

    testWidgets('defaults to enabled and defers plugin toggle until after first frame',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final calls = <bool>[];
      // Simulate a slow/never-completing platform channel call to prove startup is never blocked.
      final neverCompletes = Completer<void>();
      KeepAwake.toggleOverride = (enable) {
        calls.add(enable);
        return neverCompletes.future;
      };

      await KeepAwake.load(deferApplyUntilFirstFrame: true);

      expect(KeepAwake.enabled.value, isTrue);
      // Plugin channel must NOT have been invoked before the first frame paints.
      expect(calls, isEmpty);

      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      // Post-frame callback applies wake lock after first frame without blocking pumpWidget.
      expect(calls, [true]);
    });

    testWidgets('respects persisted false preference', (tester) async {
      SharedPreferences.setMockInitialValues({'keep_screen_on': false});
      final calls = <bool>[];
      KeepAwake.toggleOverride = (enable) async => calls.add(enable);

      await KeepAwake.load();

      expect(KeepAwake.enabled.value, isFalse);
      expect(calls, [false]);
    });

    testWidgets('releases wake lock when backgrounded/closed and reapplies on resume across routes',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final calls = <bool>[];
      KeepAwake.toggleOverride = (enable) async => calls.add(enable);

      await KeepAwake.load();
      expect(calls, [true]);

      // Simulate app navigating across Deck -> Audio -> Settings routes: wake lock stays on.
      await tester.pumpWidget(MaterialApp(
        initialRoute: '/deck',
        routes: {
          '/deck': (_) => const Text('Deck'),
          '/audio': (_) => const Text('Audio'),
          '/settings': (_) => const Text('Settings'),
        },
      ));
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      nav.pushNamed('/audio');
      await tester.pumpAndSettle();
      nav.pushNamed('/settings');
      await tester.pumpAndSettle();
      expect(KeepAwake.shouldHoldWakeLock, isTrue);

      // Backgrounded / inactive / paused / detached releases wake lock.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      expect(KeepAwake.shouldHoldWakeLock, isFalse);
      expect(calls.last, isFalse);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(KeepAwake.shouldHoldWakeLock, isFalse);

      // Returning to foreground force-reapplies wake lock on whichever route is active.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(KeepAwake.shouldHoldWakeLock, isTrue);
      expect(calls.last, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
      expect(KeepAwake.shouldHoldWakeLock, isFalse);
      expect(calls.last, isFalse);
    });

    testWidgets('set(false) disables and persists, repeated load() attaches observer once',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final calls = <bool>[];
      KeepAwake.toggleOverride = (enable) async => calls.add(enable);

      await KeepAwake.load();
      await KeepAwake.load(); // e.g., ConfigPage.initState()
      await KeepAwake.set(false);
      expect(KeepAwake.enabled.value, isFalse);
      expect(calls.last, isFalse);

      // Background -> foreground while disabled must stay disabled (and fire once, not duplicated).
      calls.clear();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(calls, [false]);
      expect(KeepAwake.shouldHoldWakeLock, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('keep_screen_on'), isFalse);
    });

    testWidgets('desktop configurator does not hold wake lock', (tester) async {
      SharedPreferences.setMockInitialValues({});
      KeepAwake.isConfiguratorOverride = true;
      final calls = <bool>[];
      KeepAwake.toggleOverride = (enable) async => calls.add(enable);

      await KeepAwake.load();
      expect(KeepAwake.enabled.value, isTrue);
      expect(KeepAwake.shouldHoldWakeLock, isFalse);
      expect(calls, [false]);
    });
  });

  group('ClientIdentity and SignalRService startup/identity contract', () {
    tearDown(() {
      ClientIdentity.resetForTest();
    });

    test('formatDisplayName produces coarse readable name without duplicating brand', () {
      expect(ClientIdentity.formatDisplayName('Nothing', 'AIN065'), 'Nothing AIN065');
      expect(ClientIdentity.formatDisplayName('nothing', 'AIN065'), 'Nothing AIN065');
      expect(ClientIdentity.formatDisplayName('Google', 'Google Pixel 9'), 'Google Pixel 9');
      expect(ClientIdentity.formatDisplayName('unknown', 'AIN065'), 'AIN065');
      expect(ClientIdentity.formatDisplayName('', ''), isNull);
    });

    test('buildPayload emits aligned contract fields with usb/wifi transport', () async {
      ClientIdentity.deviceInfoOverride = () async => (name: 'Test Phone', model: 'TP-1');

      final usb = await ClientIdentity.buildPayload(UsbRoute.usbBaseUrl);
      expect(usb, {
        'role': 'mobile',
        'name': 'Test Phone',
        'model': 'TP-1',
        'platform': ClientIdentity.platform,
        'transport': 'usb',
      });

      final wifi = await ClientIdentity.buildPayload('http://192.168.1.50:4787');
      expect(wifi['transport'], 'wifi');
      expect(wifi['role'], 'mobile');
      expect(wifi.containsKey('apiKey'), isFalse);
      expect(wifi.containsKey('serial'), isFalse);
    });

    test('SignalRService init is non-blocking and pre-registers ReceiveConnectedClients',
        () async {
      final sr = SignalRService();
      addTearDown(sr.dispose);

      // Even for a dead port, init() must return promptly without blocking navigation.
      final sw = Stopwatch()..start();
      await sr.init('http://127.0.0.1:1', apiKey: 'test-key');
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(1000));

      sr.seedState('ReceiveConnectedClients', {
        'clients': [
          {'id': 'c1', 'role': 'mobile', 'name': 'Test Phone', 'transport': 'usb', 'connected': true},
        ],
      });
      final state = sr.stateOf('ReceiveConnectedClients');
      expect((state['clients'] as List).length, 1);
    });
  });
}
