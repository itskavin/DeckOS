import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/widgets/info_deck_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const style = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  testWidgets('valor cabe em tecla baixa com fonte ampliada', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: const Center(
          child: SizedBox(
            width: 72,
            height: 36,
            child: InfoValueText('Server status operational right now', style: style),
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(Text), findsOneWidget);
  });

  test('packWordLines não parte uma palavra longa ao meio', () {
    final lines = packWordLines(
      'Supercalifragilisticexpialidocious',
      maxWidth: 60,
      style: style,
      maxLines: 3,
    );
    expect(lines, ['Supercalifragilisticexpialidocious']);
  });

  test('packWordLines quebra apenas em limites de palavra e limita a maxLines', () {
    final lines = packWordLines(
      'Server status operational right now please',
      maxWidth: 70,
      style: style,
      maxLines: 3,
    );
    expect(lines.length, lessThanOrEqualTo(3));
    // Nenhuma linha contém parte de palavra partida: todas as palavras originais aparecem íntegras.
    expect(lines.join(' ').split(' '),
        ['Server', 'status', 'operational', 'right', 'now', 'please']);
  });

  testWidgets('InfoValueText usa reticências sem quebra no meio da palavra e dígitos tabulares',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: const Scaffold(
        body: Center(
          child: SizedBox(
            width: 72,
            height: 72,
            child: InfoValueText(
              '12,345.67ms SynchronizingService',
              maxLines: 3,
              style: style,
            ),
          ),
        ),
      ),
    ));

    final texts = tester.widgetList<Text>(find.descendant(
      of: find.byType(InfoValueText),
      matching: find.byType(Text),
    ));
    expect(texts, isNotEmpty);
    for (final t in texts) {
      expect(t.maxLines, 1);
      expect(t.softWrap, isFalse);
      expect(t.overflow, TextOverflow.ellipsis);
      expect(t.style?.fontFeatures, contains(const FontFeature.tabularFigures()));
    }
    expect(tester.takeException(), isNull);
  });
}
