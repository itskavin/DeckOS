import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/widgets/button_property_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // O painel fica aberto depois de "Salvar": fechar logo em seguida perguntava
  // "Descartar as alterações?" do que acabou de ser salvo.
  testWidgets('depois de salvar, o painel não tem mudanças pendentes', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final key = GlobalKey<ButtonPropertyPanelState>();
    DeckButton? saved;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: Scaffold(
        body: ButtonPropertyPanel(
          key: key,
          button: DeckButton(id: 'b1', row: 0, column: 0, label: 'Antes'),
          onSave: (b) => saved = b,
        ),
      ),
    ));
    // O retrato inicial é tirado 400 ms depois de abrir.
    await tester.pump(const Duration(milliseconds: 500));
    expect(key.currentState!.isDirty, isFalse);

    await tester.enterText(find.byType(TextField).first, 'Depois');
    await tester.pump();
    expect(key.currentState!.isDirty, isTrue);

    await tester.tap(find.text('Salvar'));
    await tester.pump();
    expect(saved?.label, 'Depois');
    expect(key.currentState!.isDirty, isFalse);
  });
}
