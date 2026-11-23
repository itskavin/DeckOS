import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/actions/action_schema.dart';
import 'package:deckos/src/stream_deck/layout/deck_history.dart';
import 'package:deckos/src/stream_deck/layout/desktop_sidebar.dart';
import 'package:deckos/src/stream_deck/layout/fuzzy.dart';
import 'package:deckos/src/stream_deck/layout/key_combo.dart';
import 'package:deckos/src/stream_deck/layout/library_items.dart';
import 'package:deckos/src/stream_deck/layout/slot_ops.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

DeckButton b(String id, int row, int col, {int colSpan = 1}) =>
    DeckButton(id: id, row: row, column: col, label: id, columnSpan: colSpan);

Map<String, Slot> where(List<DeckButton> list) => {for (final x in list) x.id: slotOf(x)};

void main() {
  group('desfazer/refazer', () {
    DeckProfile p(String name) => DeckProfile(id: 'p', name: name);

    test('desfaz e refaz em ordem, e uma edição nova apaga o refazer', () {
      final h = DeckHistory();
      expect(h.canUndo, isFalse);
      h.record(DeckEdit(p('a'), p('b'), 'um'));
      h.record(DeckEdit(p('b'), p('c'), 'dois'));
      expect(h.undoLabel, 'dois');

      final e1 = h.undo()!;
      expect(e1.before.name, 'b');
      expect(h.canRedo, isTrue);
      final e2 = h.undo()!;
      expect(e2.before.name, 'a');
      expect(h.undo(), isNull);

      expect(h.redo()!.after.name, 'b');
      expect(h.undoLabel, 'um');

      h.record(DeckEdit(p('b'), p('x'), 'três'));
      expect(h.canRedo, isFalse);
      expect(h.undo()!.after.name, 'x');
    });

    test('guarda no máximo [limit] edições e esquece as de um perfil apagado', () {
      final h = DeckHistory(limit: 3);
      for (var i = 0; i < 5; i++) {
        h.record(DeckEdit(p('$i'), p('${i + 1}'), '$i'));
      }
      var n = 0;
      while (h.undo() != null) {
        n++;
      }
      expect(n, 3);

      h.record(DeckEdit(p('a'), p('b'), 'x'));
      h.forget('p');
      expect(h.canUndo, isFalse);
      expect(h.canRedo, isFalse);
    });

    test('cada operação muda a versão (a tela redesenha os botões)', () {
      final h = DeckHistory();
      final v = h.version.value;
      h.record(DeckEdit(p('a'), p('b'), 'x'));
      h.undo();
      h.redo();
      expect(h.version.value, v + 3);
    });
  });

  group('biblioteca de apps', () {
    final apps = [
      for (final n in ['Visual Studio Code', 'Safari', 'Música', 'Calculator', 'Discord', 'Steam'])
        InstalledApp(id: n, name: n, path: '/Applications/$n.app'),
    ];
    List<String> names(String q) => filterApps(apps, q).map((a) => a.name).toList();

    test('busca vazia mostra tudo, na ordem da lista', () {
      expect(names(''), apps.map((a) => a.name).toList());
      expect(names('   '), hasLength(apps.length));
    });

    test('começo do nome vem antes de trecho no meio', () {
      // Os que começam com "s" primeiro (o nome mais curto na frente), depois os outros.
      expect(names('s').take(2), ['Steam', 'Safari']);
      expect(names('s').skip(2), containsAll(['Visual Studio Code', 'Discord']));
    });

    test('ignora acento e caixa', () {
      expect(names('MUSICA'), ['Música']);
    });

    test('iniciais e letras em ordem', () {
      expect(names('vsc').first, 'Visual Studio Code');
      expect(names('clcltr'), ['Calculator']);
      expect(names('xyz'), isEmpty);
    });

    test('app sem iconUrl usa o endereço padrão do ícone', () {
      final a = InstalledApp.fromJson({'id': 'abc', 'name': 'X', 'path': '/x'});
      expect(a.iconUrl, '/api/apps/abc/icon');
      final none = InstalledApp.fromJson({'id': 'abc', 'name': 'X', 'path': '/x', 'iconUrl': null});
      expect(none.iconUrl, isNull);
    });

    test('app vira botão que abre pelo caminho, com os argumentos', () {
      const app = InstalledApp(id: 'a', name: 'Spotify', path: 'C:/s.exe', arguments: '--min');
      final btn = LibraryItem.fromApp(app).buildAt((row: 1, column: 2));
      expect(btn.action!.type, 'launch_app');
      expect(btn.action!.parameters, {'path': 'C:/s.exe', 'arguments': '--min', 'appId': 'a'});
      expect((btn.row, btn.column), (1, 2));
      expect(btn.label, 'Spotify');
      expect(btn.id, isNotEmpty);
    });
  });

  group('plataforma', () {
    test('lê o relatório do PC', () {
      final p = PlatformInfo.fromJson({
        'os': 'macOS',
        'capabilities': ['keyboard', 'apps.list'],
        'missing': [
          {'capability': 'media.control', 'tool': 'playerctl', 'package': 'playerctl'},
        ],
      });
      expect(p.isMac, isTrue);
      expect(p.has('keyboard'), isTrue);
      expect(p.missing['media.control'], 'playerctl');
    });

    test('esconde as ações que o PC não executa; sem relatório, mostra tudo', () {
      final linux = PlatformInfo.fromJson({
        'os': 'linux',
        'capabilities': ['keyboard', 'apps.launch'],
      });
      expect(actionSupported('hotkey', linux), isTrue);
      expect(actionSupported('media', linux), isFalse);
      expect(actionSupported('obs', linux), isTrue);
      expect(actionSupported('media', null), isTrue);
      expect(actionSupported('windows', const PlatformInfo(os: 'linux', capabilities: {'power.lock'})), isTrue);
      expect(actionSupported('windows', linux), isFalse);

      final groups = groupActions(fallbackActionCatalog, linux);
      final types = [for (final (_, list) in groups) ...list.map((s) => s.type)];
      expect(types, isNot(contains('media')));
      expect(types, isNot(contains('mixer')));
      expect(types, contains('launch_app'));
      // "Sistema" primeiro.
      expect(groups.first.$1, 'Sistema');
    });
  });

  group('grade do espelho', () {
    final buttons = [b('a', 0, 0), b('b', 0, 1), b('c', 1, 0)];

    test('mover para casa vazia', () {
      final out = SlotOps.move(buttons, (row: 0, column: 0), (row: 1, column: 3));
      expect(where(out)['a'], (row: 1, column: 3));
      expect(out, hasLength(3));
    });

    test('mover para casa ocupada troca os dois', () {
      final out = SlotOps.move(buttons, (row: 0, column: 0), (row: 0, column: 1));
      expect(where(out)['a'], (row: 0, column: 1));
      expect(where(out)['b'], (row: 0, column: 0));
      expect(where(out)['c'], (row: 1, column: 0));
    });

    test('mover para o mesmo lugar ou de casa vazia não muda nada', () {
      expect(SlotOps.move(buttons, (row: 0, column: 0), (row: 0, column: 0)), same(buttons));
      expect(SlotOps.move(buttons, (row: 2, column: 2), (row: 0, column: 0)), same(buttons));
    });

    test('mover um grupo junto, dentro da grade e sem cair em outro botão', () {
      final group = {(row: 0, column: 0), (row: 0, column: 1)};
      final down = SlotOps.moveGroup(buttons, group, 1, 1, 2, 4)!;
      expect(where(down)['a'], (row: 1, column: 1));
      expect(where(down)['b'], (row: 1, column: 2));
      expect(where(down)['c'], (row: 1, column: 0));
      // Cairia em "c".
      expect(SlotOps.moveGroup(buttons, group, 1, 0, 2, 4), isNull);
      // Sairia da grade.
      expect(SlotOps.moveGroup(buttons, group, 0, 3, 2, 4), isNull);
      // Para a direita, "b" vai para onde "a" estava? Não: os dois andam juntos.
      final right = SlotOps.moveGroup(buttons, group, 0, 1, 2, 4)!;
      expect(where(right)['a'], (row: 0, column: 1));
      expect(where(right)['b'], (row: 0, column: 2));
    });

    test('pôr um item substitui o que estava na casa', () {
      final out = SlotOps.place(buttons, b('n', 9, 9), (row: 0, column: 1));
      expect(where(out).keys, containsAll(['a', 'c', 'n']));
      expect(where(out).containsKey('b'), isFalse);
      expect(where(out)['n'], (row: 0, column: 1));
    });

    test('remover várias casas', () {
      final out = SlotOps.remove(buttons, {(row: 0, column: 0), (row: 1, column: 0), (row: 3, column: 3)});
      expect(where(out).keys, ['b']);
    });

    test('primeira casa livre em ordem de leitura, pulando botões grandes', () {
      expect(SlotOps.firstEmpty(buttons, 2, 4), (row: 0, column: 2));
      final wide = [b('w', 0, 0, colSpan: 3)];
      expect(SlotOps.firstEmpty(wide, 2, 4), (row: 0, column: 3));
      final full = [for (var r = 0; r < 2; r++) for (var c = 0; c < 2; c++) b('$r$c', r, c)];
      expect(SlotOps.firstEmpty(full, 2, 2), isNull);
      expect(SlotOps.visibleCount(full, 2, 2), 4);
      // Botão fora da grade deste celular não aparece, mas a casa dele continua ocupada.
      expect(SlotOps.visibleCount([b('x', 5, 5)], 2, 2), 0);
    });
  });

  group('atalhos', () {
    test('monta no formato do PC e mostra do jeito de cada sistema', () {
      const combo = KeyCombo(LogicalKeyboardKey.keyK, meta: true, shift: true);
      expect(combo.sendKeys, '+#k');
      expect(combo.display(mac: true), '⇧⌘K');
      expect(combo.display(mac: false), 'Win+Shift+K');
      expect(const KeyCombo(LogicalKeyboardKey.f5).sendKeys, '{F5}');
      expect(const KeyCombo(LogicalKeyboardKey.f5).isValid, isTrue);
      expect(prettyKeys('^%{DEL}', mac: false), 'Ctrl+Alt+Del');
      expect(prettyKeys('^{UP}', mac: true), '⌃↑');
    });

    test('letra sozinha não é atalho; caracteres especiais vão entre chaves', () {
      expect(const KeyCombo(LogicalKeyboardKey.keyA).isValid, isFalse);
      expect(const KeyCombo(LogicalKeyboardKey.keyA, shift: true).isValid, isFalse);
      expect(const KeyCombo(LogicalKeyboardKey.keyA, ctrl: true).isValid, isTrue);
      expect(const KeyCombo(LogicalKeyboardKey.add, ctrl: true).sendKeys, '^{+}');
      expect(KeyCombo.isModifier(LogicalKeyboardKey.shiftLeft), isTrue);
    });
  });

  group('páginas', () {
    test('pastas aparecem recuadas logo abaixo da página que as abre', () {
      DeckButton folder(String target) => DeckButton(
            id: 'f$target',
            row: 0,
            column: 0,
            action: DeckAction(type: 'open_profile', parameters: {'profileId': target}),
          );
      final pages = [
        DeckProfile(id: 'pasta', name: 'Pasta'),
        DeckProfile(id: 'home', name: 'Home', buttons: [folder('pasta')]),
        DeckProfile(id: 'music', name: 'Music'),
        // Ciclo: um abre o outro. Nenhum vira pasta do outro para sempre.
        DeckProfile(id: 'x', name: 'X', buttons: [folder('y')]),
        DeckProfile(id: 'y', name: 'Y', buttons: [folder('x')]),
      ];
      final tree = pageTree(pages);
      expect([for (final e in tree) '${e.profile.id}:${e.depth}'],
          ['home:0', 'pasta:1', 'music:0', 'x:0', 'y:0']);
    });

    test('só as páginas de cima deslizam e contam nos pontinhos; pasta de pasta fica na raiz', () {
      DeckButton open(String target) => DeckButton(
            id: 'o$target',
            row: 0,
            column: 0,
            action: DeckAction(type: 'open_profile', parameters: {'profileId': target}),
          );
      final pages = [
        DeckProfile(id: 'home', name: 'Home', buttons: [open('pasta')]),
        DeckProfile(id: 'pasta', name: 'Pasta', buttons: [open('sub')]),
        DeckProfile(id: 'sub', name: 'Sub'),
        DeckProfile(id: 'music', name: 'Music'),
      ];
      expect([for (final p in topLevelPages(pages)) p.id], ['home', 'music']);
      expect([for (final e in pageTree(pages)) '${e.profile.id}:${e.depth}'],
          ['home:0', 'pasta:1', 'sub:1', 'music:0']);
      // Dentro de uma pasta, a página de cima é a que a abre.
      expect(topLevelPageOf(pages, pages[2])?.id, 'home');
      expect(topLevelPageOf(pages, pages[3])?.id, 'music');
    });
  });

  test('busca da paleta: acha por trecho e por letras em ordem', () {
    expect(fuzzyScore('obs', 'OBS Studio'), isNotNull);
    expect(fuzzyScore('stdo', 'OBS Studio'), isNotNull);
    expect(fuzzyScore('zz', 'OBS Studio'), isNull);
    expect(fuzzyScore('ob', 'OBS')! > fuzzyScore('ob', 'Global')!, isTrue);
  });

  test('categorias conhecidas têm glifo e cor próprios', () {
    expect(categoryStyle('Sistema').$3, 0);
    expect(categoryStyle('Media').$2, 'pink');
    expect(categoryStyle('Streaming').$2, 'purple');
    expect(categoryStyle('Outra coisa').$2, 'gray');
    const s = ActionSchema(type: 'hotkey', title: 'Atalho');
    expect(actionGlyph(s), isNotNull);
  });
}
