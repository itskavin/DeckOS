import 'package:deckos/core/core.dart';
import 'package:deckos/src/config/integrations_page.dart';
import 'package:deckos/src/config/settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('o aviso de erro mostra o texto amigável e o "tentar de novo"', (tester) async {
    var retried = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AppleBanner.error(Exception('x'), title: 'Falhou', onRetry: () => retried++),
      ),
    ));
    expect(find.text('Falhou'), findsOneWidget);
    expect(find.text('Algo deu errado. Tente de novo.'), findsOneWidget);
    await tester.tap(find.text('Tentar de novo'));
    expect(retried, 1);
  });

  testWidgets('a linha de senha esconde o texto até tocar no olho', (tester) async {
    final ctrl = TextEditingController(text: 'segredo');
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FormTextRow(label: 'Senha', controller: ctrl, secure: true)),
    ));
    bool obscured() => tester.widget<EditableText>(find.byType(EditableText)).obscureText;
    expect(obscured(), isTrue);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(obscured(), isFalse);
  });

  test('toda integração com ícone de marca tem tela', () {
    for (final key in IntegrationBrand.all.keys) {
      expect(IntegrationsPage.pageFor(key), isNotNull, reason: key);
    }
  });
}
