import 'dart:convert';
import 'dart:io';

import 'package:deckos/src/stream_deck/buttons/button_icons.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('todo ícone das categorias existe no mapa', () {
    for (final (title, names) in iconCategories) {
      for (final name in names) {
        expect(buttonIcons.containsKey(name), isTrue, reason: '$title: $name');
      }
    }
  });

  test('título de categoria tem tradução (o tr recebe variável e escapa do i18n_test)', () {
    for (final lang in ['en', 'es']) {
      final strings = jsonDecode(File('assets/i18n/$lang.json').readAsStringSync()) as Map;
      for (final (title, _) in iconCategories) {
        expect(strings.containsKey(title), isTrue, reason: '$lang: $title');
      }
    }
  });

  test('todo ícone do mapa aparece no seletor', () {
    final listed = {for (final (_, names) in iconCategories) ...names};
    expect(buttonIcons.keys.where((k) => !listed.contains(k)), isEmpty);
  });

  test('controles do sistema viram os SF Symbols (CupertinoIcons) dos prints', () {
    expect(buttonIconData('camera'), CupertinoIcons.camera_viewfinder);
    expect(buttonIconData('volume_off'), CupertinoIcons.speaker_slash_fill);
    expect(buttonIconData('volume_down'), CupertinoIcons.speaker_1_fill);
    expect(buttonIconData('volume_up'), CupertinoIcons.speaker_3_fill);
    expect(buttonIconData('mic'), CupertinoIcons.mic_fill);
    expect(buttonIconData('fast_rewind'), CupertinoIcons.backward_fill);
    expect(buttonIconData('fast_forward'), CupertinoIcons.forward_fill);
    // Nome desconhecido (perfil de uma versão mais nova) cai num genérico.
    expect(buttonIconData('nao-existe'), CupertinoIcons.cube_fill);
  });

  test('a maior parte dos ícones vem do Cupertino', () {
    final cupertino = buttonIcons.values.where((i) => i.fontFamily == 'CupertinoIcons').length;
    expect(cupertino / buttonIcons.length, greaterThan(0.8));
  });
}
