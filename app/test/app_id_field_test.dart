import 'dart:convert';
import 'dart:typed_data';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/actions/action_schema.dart';
import 'package:deckos/src/stream_deck/actions/schema_action_form.dart';
import 'package:deckos/src/stream_deck/layout/app_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _launchAppSchema = ActionSchema(
  type: 'launch_app',
  title: 'Abrir programa',
  icon: 'launch',
  category: 'Sistema',
  privileged: true,
  fields: [
    ActionField(key: 'path', label: 'Caminho', required: true),
    ActionField(key: 'arguments', label: 'Argumentos (opcional)'),
    ActionField(key: 'appId', label: 'Aplicativo'),
  ],
);

const _sampleApps = [
  InstalledApp(id: 'app-firefox', name: 'Firefox', path: '/usr/bin/firefox', iconUrl: null),
  InstalledApp(
    id: 'app-calc',
    name: 'Calculadora',
    path: 'explorer.exe',
    arguments: r'shell:AppsFolder\Calc',
    iconUrl: null,
  ),
];

bool _hasClient() {
  try {
    Injector.get<DeckOSClient>();
    return true;
  } catch (_) {
    return false;
  }
}

Widget _wrap(Widget child) {
  final page = MaterialApp(
    theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
  if (_hasClient()) return page;
  return FlutterGetIt(
    bindingsBuilder: () => [
      Bind.singleton<DeckOSClient>((_) => DeckOSClient(baseUrl: 'http://127.0.0.1:4787')),
    ],
    pages: [
      FlutterGetItPageBuilder(
        page: (_) => Scaffold(body: SingleChildScrollView(child: child)),
        path: '/',
      ),
    ],
    builder: (context, routes, isReady) => MaterialApp(
      theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
      routes: routes,
    ),
  );
}

void main() {
  testWidgets('appId salvo mostra nome e ícone resolvidos de /api/apps e permite trocar',
      (tester) async {
    Map<String, String>? latest;
    String? suggestedLabel;
    String? suggestedIcon;
    final fakePng = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]);
    await tester.pumpWidget(_wrap(SchemaActionForm(
      schema: _launchAppSchema,
      initial: const {'appId': 'app-firefox', 'path': '/usr/bin/firefox'},
      onChanged: (v) => latest = v,
      loadApps: () async => _sampleApps,
      suggestLabel: (l) => suggestedLabel = l,
      suggestIcon: (b64) => suggestedIcon = b64,
      loadAppIcon: (_) async => fakePng,
    )));
    await tester.pumpAndSettle();

    // Linha somente leitura com ícone central (AppIconView) e nome resolvido, não campo de texto.
    expect(find.text('Firefox'), findsOneWidget);
    expect(find.byType(AppIconView), findsOneWidget);
    expect(find.text('app-firefox'), findsNothing);
    expect(find.text('Trocar'), findsOneWidget);

    // Abre o seletor e escolhe outro app.
    await tester.tap(find.text('Trocar'));
    await tester.pumpAndSettle();
    expect(find.text('Escolher aplicativo'), findsOneWidget);
    await tester.tap(find.text('Calculadora'));
    await tester.pumpAndSettle();

    expect(find.text('Calculadora'), findsOneWidget);
    expect(latest?['appId'], 'app-calc');
    expect(latest?['path'], 'explorer.exe');
    expect(latest?['arguments'], r'shell:AppsFolder\Calc');
    expect(suggestedLabel, 'Calculadora');
    expect(suggestedIcon, base64Encode(fakePng));
  });

  testWidgets('appId desconhecido mostra fallback com o ID salvo', (tester) async {
    await tester.pumpWidget(_wrap(SchemaActionForm(
      schema: _launchAppSchema,
      initial: const {'appId': 'deadbeef1234', 'path': '/missing'},
      onChanged: (_) {},
      loadApps: () async => _sampleApps,
    )));
    await tester.pumpAndSettle();

    expect(find.text('ID salvo: deadbeef1234'), findsOneWidget);
    expect(find.text('Trocar'), findsOneWidget);
  });
}
