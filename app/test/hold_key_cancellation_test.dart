import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/widgets/deck_grid_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Hub extends SignalRService {
  _Hub(this.connected);
  final bool connected;
  int downs = 0;
  int ups = 0;
  @override
  bool holdKey(String buttonId) { downs++; return connected; }
  @override
  bool releaseKey(String buttonId) { ups++; return connected; }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => GetIt.I.reset());

  for (final connected in [false, true]) {
    testWidgets('hold key cancellation releases without fallback tap (connected=$connected)', (tester) async {
      final hub = _Hub(connected);
      GetIt.I.registerSingleton<SignalRService>(hub);
      var fallbackTaps = 0;
      await tester.pumpWidget(MaterialApp(home: Center(child: SizedBox(width: 160, height: 160,
        child: DeckGridButton(button: DeckButton(id: 'held', row: 0, column: 0,
          action: DeckAction(type: 'key', parameters: {'key': 'F24', 'mode': 'hold'})),
          liveKeys: true, onTap: () => fallbackTaps++, onLongPress: () {}),
      ))));
      final center = tester.getCenter(find.byType(DeckGridButton));
      final cancelled = await tester.startGesture(center);
      await cancelled.cancel();
      await tester.pumpAndSettle();
      expect(fallbackTaps, 0);
      expect(hub.downs, 0);
      expect(hub.ups, 0);

      final swipe = await tester.startGesture(center);
      await swipe.moveBy(const Offset(60, 0));
      await swipe.up();
      await tester.pumpAndSettle();
      expect(fallbackTaps, 0);
      expect(hub.downs, 0);
      expect(hub.ups, 0);

      // A short real tap executes promptly on release in either connection state.
      await tester.tap(find.byType(DeckGridButton));
      await tester.pumpAndSettle();
      expect(fallbackTaps, 1);
      expect(hub.downs, 0);

      final held = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 120));
      expect(hub.downs, 1);
      await held.up();
      await tester.pumpAndSettle();
      expect(hub.ups, connected ? 1 : 0);
      expect(fallbackTaps, connected ? 1 : 2);

      // Disposal makes a best-effort release and never sends another tap.
      final disposing = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await disposing.cancel();
      expect(hub.ups, connected ? 2 : 0);
      expect(fallbackTaps, connected ? 1 : 2);
    });
  }

  testWidgets('a page swipe starting on a hold key changes page without any key action', (tester) async {
    final hub = _Hub(true);
    GetIt.I.registerSingleton<SignalRService>(hub);
    final pages = PageController();
    addTearDown(pages.dispose);
    var taps = 0;
    await tester.pumpWidget(MaterialApp(home: PageView(controller: pages, children: [
      Center(child: SizedBox(width: 160, height: 160, child: DeckGridButton(
        button: DeckButton(id: 'held', row: 0, column: 0,
          action: DeckAction(type: 'key', parameters: {'key': 'F24', 'mode': 'hold'})),
        liveKeys: true, onTap: () => taps++, onLongPress: () {},
      ))),
      const Center(child: Text('Next page')),
    ])));
    final swipe = await tester.startGesture(tester.getCenter(find.byType(DeckGridButton)));
    await tester.pump(const Duration(milliseconds: 40));
    await swipe.moveBy(const Offset(-60, 0));
    await tester.pump(const Duration(milliseconds: 20));
    await swipe.moveBy(const Offset(-500, 0));
    await swipe.up();
    await tester.pumpAndSettle();
    expect(pages.page, 1);
    expect(hub.downs, 0);
    expect(hub.ups, 0);
    expect(taps, 0);
  });
}
