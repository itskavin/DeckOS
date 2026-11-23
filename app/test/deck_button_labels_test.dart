import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:deckos/src/stream_deck/widgets/deck_grid_button.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get_it/get_it.dart';

void main() {
  setUp(() => GetIt.I.registerSingleton<SignalRService>(SignalRService()));
  tearDown(GetIt.I.reset);

  Future<void> pump(
    WidgetTester tester,
    DeckButton button, {
    ThemeSettings settings = const ThemeSettings(),
  }) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(settings, Brightness.dark),
      home: Center(
        child: SizedBox(
          width: 120,
          height: 120,
          child: DeckGridButton(button: button, onTap: () {}, onLongPress: () {}),
        ),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
  }

  DeckButton glyphButton() => DeckButton(
        id: 'b1',
        row: 0,
        column: 0,
        label: 'Gravar',
        iconName: 'mic',
        action: DeckAction(type: 'hotkey'),
      );

  group('nomes nos botões', () {
    test('no tema padrão (arredondado) começam escondidos; nos estilos antigos, visíveis', () {
      expect(const ThemeSettings().effectiveShowLabels, isFalse);
      expect(const ThemeSettings(presetId: 'neon').effectiveShowLabels, isTrue);
      expect(const ThemeSettings(showLabels: true).effectiveShowLabels, isTrue);
      final deck = buildAppTheme(const ThemeSettings(), Brightness.dark).extension<DeckTheme>()!;
      expect(deck.showLabels, isFalse);
    });

    testWidgets('botão com glifo mostra só o glifo (o nome fica para o leitor de tela)', (tester) async {
      await pump(tester, glyphButton());
      expect(find.byIcon(CupertinoIcons.mic_fill), findsOneWidget);
      expect(find.text('Gravar'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Gravar')), findsWidgets);
    });

    testWidgets('com a opção ligada o nome aparece embaixo do glifo', (tester) async {
      await pump(tester, glyphButton(), settings: const ThemeSettings(showLabels: true));
      expect(find.byIcon(CupertinoIcons.mic_fill), findsOneWidget);
      expect(find.text('Gravar'), findsOneWidget);
    });

    testWidgets('botão só de texto continua mostrando o texto, sem a mãozinha', (tester) async {
      await pump(
        tester,
        DeckButton(id: 'b2', row: 0, column: 0, label: 'Ctrl+S', action: DeckAction(type: 'hotkey')),
      );
      expect(find.text('Ctrl+S'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.hand_point_right_fill), findsNothing);
    });

    testWidgets('cena do OBS mantém o nome: é ele que diz qual cena é', (tester) async {
      await pump(
        tester,
        DeckButton(
          id: 'b3',
          row: 0,
          column: 0,
          action: DeckAction(type: 'obs', parameters: {'operation': 'setScene', 'scene': 'Cam 1'}),
        ),
      );
      expect(find.text('Cam 1'), findsOneWidget);
    });
  });

  testWidgets('mídia usa os glifos dos controles do sistema', (tester) async {
    for (final (command, icon) in [
      ('previous', CupertinoIcons.backward_fill),
      ('playpause', CupertinoIcons.playpause_fill),
      ('next', CupertinoIcons.forward_fill),
    ]) {
      await pump(
        tester,
        DeckButton(
          id: command,
          row: 0,
          column: 0,
          action: DeckAction(type: 'media', parameters: {'command': command}),
        ),
      );
      expect(find.byIcon(icon), findsOneWidget, reason: command);
    }
  });
}
