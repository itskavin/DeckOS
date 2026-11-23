import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/layout/connected_clients.dart';
import 'package:deckos/src/stream_deck/layout/desktop_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    AppLanguage.choice.value = 'pt';
  });

  group('ConnectedClientsState', () {
    test('separa celulares/decks do configurador e preserva identidade real', () {
      final state = ConnectedClientsState.fromPayload({
        'clients': [
          {
            'id': 'cfg11111',
            'role': 'configurator',
            'name': 'MARK-4 Browser',
            'platform': 'windows',
            'transport': 'local',
            'connected': true,
          },
          {
            'id': 'a1b2c3d4',
            'role': 'mobile',
            'name': 'Nothing Phone (2a)',
            'model': 'AIN065',
            'platform': 'android',
            'transport': 'usb',
            'connected': true,
            'connectedAt': '2026-11-22T19:20:00Z',
          },
          {
            'id': 'b2c3d4e5',
            'role': 'web_deck',
            'name': null,
            'model': null,
            'platform': 'ios',
            'transport': 'wifi',
            'connected': true,
          },
        ],
      });

      expect(state.known, isTrue);
      expect(state.phoneCount, 2);
      final phone = state.primaryPhone!;
      expect(phone.displayName, 'Nothing Phone (2a)');
      expect(phone.distinctModel, 'AIN065');
      expect(phone.metaSummary, 'Android · USB');
      expect(state.phones[1].displayName, 'Navegador conectado');
      expect(state.phones[1].metaSummary, 'iOS · Wi-Fi');
    });

    test('payload vazio marca conhecido com 0 celulares sem inventar dispositivo', () {
      final state = ConnectedClientsState.fromPayload({'clients': []});
      expect(state.known, isTrue);
      expect(state.primaryPhone, isNull);
      expect(state.phoneCount, 0);
    });

    test('payload ausente ou inválido retorna estado desconhecido', () {
      expect(ConnectedClientsState.fromPayload(null).known, isFalse);
      expect(ConnectedClientsState.fromPayload({}).known, isFalse);
    });
  });

  group('DesktopSidebar identidade do celular x PC controlado', () {
    final profile = DeckProfile(id: 'p1', name: 'Principal', rows: 2, columns: 4);

    Widget buildSidebar({
      required ConnectedClientsState clients,
      bool connected = true,
    }) {
      return MaterialApp(
        theme: buildAppTheme(const ThemeSettings(), Brightness.dark),
        home: Scaffold(
          body: SizedBox(
            width: 280,
            height: 700,
            child: DesktopSidebar(
              profiles: [profile],
              current: profile,
              rows: 2,
              columns: 4,
              pcName: 'MARK-4',
              platform: const PlatformInfo(os: 'windows'),
              connected: connected,
              clients: clients,
              version: '1.0.0',
              onSelect: (_) {},
              onRename: (_, __) {},
              onMenu: (_, __) {},
              onReorder: (_, __) {},
              onNewPage: () {},
              onLayoutTap: () {},
              tools: const [],
              onAbout: () {},
              onHelp: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('mostra celular conectado separado do PC controlado', (tester) async {
      final clients = ConnectedClientsState.fromPayload({
        'clients': [
          {
            'id': 'a1b2c3d4',
            'role': 'mobile',
            'name': 'Pixel 8',
            'model': 'Pixel 8',
            'platform': 'android',
            'transport': 'usb',
            'connected': true,
          },
        ],
      });

      await tester.pumpWidget(buildSidebar(clients: clients));
      await tester.pumpAndSettle();

      final phoneCard = find.byKey(const ValueKey('sidebar-phone-card'));
      final pcCard = find.byKey(const ValueKey('sidebar-pc-card'));
      expect(phoneCard, findsOneWidget);
      expect(pcCard, findsOneWidget);

      expect(find.descendant(of: phoneCard, matching: find.text('Pixel 8')), findsOneWidget);
      expect(find.descendant(of: phoneCard, matching: find.text('Android · USB')), findsOneWidget);
      expect(find.descendant(of: phoneCard, matching: find.text('MARK-4')), findsNothing);

      expect(find.descendant(of: pcCard, matching: find.text('MARK-4')), findsOneWidget);
      expect(
        find.descendant(of: pcCard, matching: find.text('Windows · Servidor ativo')),
        findsOneWidget,
      );
    });

    testWidgets('sem celular conectado mostra estado honesto e nunca mostra o PC como celular',
        (tester) async {
      final clients = ConnectedClientsState.fromPayload({'clients': []});
      await tester.pumpWidget(buildSidebar(clients: clients));
      await tester.pumpAndSettle();

      final phoneCard = find.byKey(const ValueKey('sidebar-phone-card'));
      expect(
        find.descendant(of: phoneCard, matching: find.text('Nenhum celular conectado')),
        findsOneWidget,
      );
      expect(find.descendant(of: phoneCard, matching: find.text('MARK-4')), findsNothing);
    });

    testWidgets('quando servidor não expõe lista de clientes mostra indisponível', (tester) async {
      await tester.pumpWidget(buildSidebar(clients: const ConnectedClientsState.unknown()));
      await tester.pumpAndSettle();

      final phoneCard = find.byKey(const ValueKey('sidebar-phone-card'));
      expect(
        find.descendant(of: phoneCard, matching: find.text('Status do celular indisponível')),
        findsOneWidget,
      );
    });
  });
}
