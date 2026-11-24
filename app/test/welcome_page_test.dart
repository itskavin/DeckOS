import 'package:deckos/src/connection/constants.dart';
import 'package:deckos/src/welcome/welcome_page.dart';
import 'package:deckos/src/config/privacy_notice_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app() => MaterialApp(
    routes: {
      '/': (_) => const WelcomePage(),
      '/config': (_) => const Scaffold(body: Text('tela de pareamento')),
    },
  );

  testWidgets('privacy notice is readable before pairing without a PC', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.ensureVisible(find.text('Privacidade e conexão local'));
    await tester.tap(find.text('Privacidade e conexão local'));
    await tester.pumpAndSettle();

    expect(find.byType(PrivacyNoticePage), findsOneWidget);
    expect(find.text('Local connection security'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Removing data'), 300,
        scrollable: find.descendant(
          of: find.byType(PrivacyNoticePage),
          matching: find.byType(Scrollable),
        ).first);
    expect(find.text('Removing data'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mostra o endereço do site para digitar no PC', (tester) async {
    await tester.pumpWidget(app());
    // A lista é preguiçosa: rola até o endereço aparecer.
    await tester.scrollUntilVisible(find.text(Constants.siteDisplay), 200);

    expect(find.text(Constants.siteDisplay), findsOneWidget);
    expect(find.text('Enviar link'), findsOneWidget);
  });

  testWidgets('no primeiro uso, "mais opções" segue para a configuração', (
    tester,
  ) async {
    await tester.pumpWidget(app());

    await tester.ensureVisible(find.text('Mais opções de conexão'));
    await tester.tap(find.text('Mais opções de conexão'));
    await tester.pumpAndSettle();

    expect(find.text('tela de pareamento'), findsOneWidget);
    expect(find.byType(WelcomePage), findsNothing);
  });

  testWidgets('aberta pela configuração, "mais opções" só volta', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const WelcomePage())),
              child: const Text('configuração'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('configuração'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Mais opções de conexão'));
    await tester.tap(find.text('Mais opções de conexão'));
    await tester.pumpAndSettle();

    expect(find.text('configuração'), findsOneWidget);
    expect(find.byType(WelcomePage), findsNothing);
  });

  test('the download site matches the default English onboarding', () {
    expect(Constants.siteUrl, startsWith('https://${Constants.siteDisplay}/'));
    expect(Constants.siteUrl, contains('lang=en'));
  });
}
