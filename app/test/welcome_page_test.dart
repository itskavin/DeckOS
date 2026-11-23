import 'package:deckos/src/connection/constants.dart';
import 'package:deckos/src/welcome/welcome_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app() => MaterialApp(
        routes: {
          '/': (_) => const WelcomePage(),
          '/config': (_) => const Scaffold(body: Text('tela de pareamento')),
        },
      );

  testWidgets('mostra o endereço do site para digitar no PC', (tester) async {
    await tester.pumpWidget(app());
    // A lista é preguiçosa: rola até o endereço aparecer.
    await tester.scrollUntilVisible(find.text(Constants.siteDisplay), 200);

    expect(find.text(Constants.siteDisplay), findsOneWidget);
    expect(find.text('Enviar link'), findsOneWidget);
  });

  testWidgets('no primeiro uso, "mais opções" segue para a configuração',
      (tester) async {
    await tester.pumpWidget(app());

    await tester.ensureVisible(find.text('Mais opções de conexão'));
    await tester.tap(find.text('Mais opções de conexão'));
    await tester.pumpAndSettle();

    expect(find.text('tela de pareamento'), findsOneWidget);
    expect(find.byType(WelcomePage), findsNothing);
  });

  testWidgets('aberta pela configuração, "mais opções" só volta', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const WelcomePage()),
            ),
            child: const Text('configuração'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('configuração'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Mais opções de conexão'));
    await tester.tap(find.text('Mais opções de conexão'));
    await tester.pumpAndSettle();

    expect(find.text('configuração'), findsOneWidget);
    expect(find.byType(WelcomePage), findsNothing);
  });

  test('o link do site aponta para a versão em português', () {
    expect(Constants.siteUrl, startsWith('https://${Constants.siteDisplay}/'));
    expect(Constants.siteUrl, contains('lang=pt'));
  });
}
