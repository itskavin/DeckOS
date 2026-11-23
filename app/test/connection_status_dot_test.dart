import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/widgets/connection_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('texto do SignalR vira o estado da ligação', () {
    expect(DeckLink.of('Connected'), DeckLink.connected);
    expect(DeckLink.of('Connecting...'), DeckLink.connecting);
    expect(DeckLink.of('Reconnecting...'), DeckLink.reconnecting);
    // Espera entre tentativas: o PC não responde.
    expect(DeckLink.of('Reconnecting in 8s...'), DeckLink.offline);
    expect(DeckLink.of('Disconnected'), DeckLink.offline);
  });

  Future<void> pump(WidgetTester tester, DeckLink link, {bool reduce = false}) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Center(child: ConnectionStatusDot(link: link)),
      ),
    ));
  }

  Color dotColor(WidgetTester tester) =>
      tester.widget<StatusDot>(find.byType(StatusDot)).color!;

  testWidgets('verde conectado, laranja tentando, vermelho sem conexão', (tester) async {
    final c = AppleColors.dark();
    await pump(tester, DeckLink.connected);
    expect(dotColor(tester), c.green);
    await pump(tester, DeckLink.reconnecting);
    expect(dotColor(tester), c.orange);
    await pump(tester, DeckLink.connecting);
    expect(dotColor(tester), c.orange);
    await pump(tester, DeckLink.offline);
    expect(dotColor(tester), c.red);
  });

  testWidgets('pulsa só enquanto tenta', (tester) async {
    await pump(tester, DeckLink.reconnecting);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.hasRunningAnimations, isTrue);

    await pump(tester, DeckLink.connected);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('com "reduzir movimento" não pulsa', (tester) async {
    await pump(tester, DeckLink.reconnecting, reduce: true);
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.hasRunningAnimations, isFalse);
  });
}
