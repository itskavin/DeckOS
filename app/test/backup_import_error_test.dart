import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/backup/backup_buttons.dart';
import 'package:deckos/src/stream_deck/backup/backup_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('arquivo de backup ilegível mostra aviso de erro em vez de falhar em silêncio',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: Scaffold(
        body: BackupButtons(
          pickFile: ({accept = ''}) =>
              Future<List<int>?>.error(const BackupFileReadException('NotReadableError')),
        ),
      ),
    ));

    await tester.tap(find.text('Importar backup'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Não foi possível ler o arquivo selecionado.'), findsOneWidget);
  });

  testWidgets('arquivo do Stream Deck ilegível também mostra aviso de erro', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: Scaffold(
        body: BackupButtons(
          dense: true,
          pickFile: ({accept = ''}) =>
              Future<List<int>?>.error(const BackupFileReadException('NotReadableError')),
        ),
      ),
    ));

    await tester.tap(find.text('Importar do Stream Deck'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Não foi possível ler o arquivo selecionado.'), findsOneWidget);
  });

  testWidgets('cancelar o seletor de arquivo libera os botões de backup', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      home: Scaffold(
        body: BackupButtons(
          pickFile: ({accept = ''}) async {
            calls++;
            return null;
          },
        ),
      ),
    ));

    await tester.tap(find.text('Importar backup'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Importar backup'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
