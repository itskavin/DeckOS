import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:flutter/cupertino.dart';

import '../actions/action_schema.dart';
import 'slot_ops.dart';

/// O que se arrasta para uma casa do espelho.
sealed class DeckDrag {
  const DeckDrag();
}

/// Botão(ões) já no deck: [from] é o que está sob o ponteiro; [group] inclui os outros
/// selecionados que vão junto.
class ButtonDrag extends DeckDrag {
  final Slot from;
  final Set<Slot> group;
  const ButtonDrag(this.from, this.group);
}

/// Item da biblioteca (app, ação, atalho): vira um botão novo na casa.
class LibraryDrag extends DeckDrag {
  final LibraryItem item;
  const LibraryDrag(this.item);
}

/// Item da biblioteca: o botão que ele cria, e se precisa de ajustes no inspetor depois
/// de solto (ação com campos obrigatórios sem valor, editores próprios).
class LibraryItem {
  final String title;
  final String? subtitle;
  final DeckButton template;
  final bool needsSetup;

  /// App da biblioteca: ao soltar, a tela busca o ícone dele para gravar no botão.
  final InstalledApp? app;

  const LibraryItem({
    required this.title,
    required this.template,
    this.subtitle,
    this.needsSetup = false,
    this.app,
  });

  /// O botão na casa [s], com id novo.
  DeckButton buildAt(Slot s) => template.copyWith(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        row: s.row,
        column: s.column,
      );

  /// App instalado: abre com "launch_app"; o ícone do app vai no botão (PNG).
  static LibraryItem fromApp(InstalledApp app, {List<int>? pngIcon}) => LibraryItem(
        title: app.name,
        app: app,
        template: DeckButton(
          id: '',
          row: 0,
          column: 0,
          label: app.name,
          iconBase64: pngIcon == null ? null : base64Encode(pngIcon),
          iconName: pngIcon == null ? 'launch' : null,
          // appId: o PC acha o app pela lista na hora de abrir (caminho e argumentos atuais);
          // path/arguments ficam para servidor antigo e para o editor mostrar.
          action: DeckAction(type: 'launch_app', parameters: {
            'path': app.path,
            if (app.arguments != null) 'arguments': app.arguments!,
            if (app.id.isNotEmpty) 'appId': app.id,
          }),
        ),
      );

  /// Tipo de ação do catálogo, com os valores padrão dos campos.
  static LibraryItem fromAction(ActionSchema s) {
    final defaults = s.defaults();
    final missing = s.fields.any((f) => f.required && !defaults.containsKey(f.key) && f.isVisible(defaults));
    return LibraryItem(
      title: s.title,
      subtitle: s.description,
      needsSetup: s.editor != null || missing,
      template: DeckButton(
        id: '',
        row: 0,
        column: 0,
        label: s.title,
        iconName: s.icon,
        action: DeckAction(type: s.type, parameters: defaults),
      ),
    );
  }

  /// Atalho de teclado gravado ([keys] no formato do SendKeys).
  static LibraryItem lockComputer(String label) => LibraryItem(
        title: label,
        template: DeckButton(id: '', row: 0, column: 0, label: label, iconName: 'lock',
            action: DeckAction(type: 'windows', parameters: {'operation': 'lock'})),
      );

  static LibraryItem fromShortcut(String keys, String display, {String? label}) => LibraryItem(
        title: label ?? display,
        subtitle: label == null ? null : display,
        template: DeckButton(
          id: '',
          row: 0,
          column: 0,
          label: label ?? display,
          iconName: 'keyboard',
          action: DeckAction(type: 'hotkey', parameters: {'keys': keys}),
        ),
      );
}

/// Recurso do PC (GET /api/platform) que cada tipo de ação precisa. Tipo fora da lista
/// não depende do sistema.
const actionCapability = <String, String>{
  'hotkey': 'keyboard',
  'key': 'keyboard',
  'launch_app': 'apps.launch',
  'activatewindow': 'window.activate',
  'media': 'media.control',
  'mixer': 'audio.volume',
  'soundboard': 'soundboard',
  'voicemeeter': 'voicemeeter',
};

/// O PC executa este tipo? Sem o relatório da plataforma (PC antigo), tudo vale.
bool actionSupported(String type, PlatformInfo? platform) {
  if (platform == null || platform.capabilities.isEmpty) return true;
  if (type == 'windows') {
    return ['audio.defaultDevice', 'power.lock', 'power.sleep', 'power.displayOff']
        .any(platform.has);
  }
  final need = actionCapability[type];
  if (need != null) return platform.has(need);
  if (type == 'script') {
    return platform.capabilities.any((c) => c.startsWith('script.'));
  }
  return true;
}

/// Agrupa o catálogo por categoria, sem os tipos que o PC não executa. Categorias na
/// ordem em que aparecem; "Sistema" e "Mídia" primeiro.
List<(String, List<ActionSchema>)> groupActions(List<ActionSchema> schemas, PlatformInfo? platform) {
  final groups = <String, List<ActionSchema>>{};
  for (final s in schemas) {
    if (!actionSupported(s.type, platform)) continue;
    groups.putIfAbsent(s.category, () => []).add(s);
  }
  int rank(String c) => switch (categoryStyle(c).$3) { 0 => 0, 1 => 1, _ => 2 };
  final keys = groups.keys.toList();
  final order = {for (var i = 0; i < keys.length; i++) keys[i]: i};
  keys.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : order[a]!.compareTo(order[b]!);
  });
  return [for (final k in keys) (k, groups[k]!)];
}

/// Glifo, cor e posição de uma categoria (o PC manda o nome já traduzido). A cor é um
/// nome das cores de sistema; [AppleColors] a resolve no tema.
(IconData, String, int) categoryStyle(String category) {
  final c = category.toLowerCase();
  bool any(List<String> words) => words.any(c.contains);
  if (any(['sistem', 'system', 'सिस्टम'])) return (CupertinoIcons.desktopcomputer, 'blue', 0);
  if (any(['mídia', 'midia', 'media', 'medio', 'मीडिया'])) return (CupertinoIcons.music_note_2, 'pink', 1);
  if (any(['stream'])) return (CupertinoIcons.dot_radiowaves_left_right, 'purple', 2);
  if (any(['casa', 'home', 'hogar', 'घर'])) return (CupertinoIcons.house_fill, 'orange', 2);
  if (any(['estúdio', 'estudio', 'studio'])) return (CupertinoIcons.slider_horizontal_3, 'indigo', 2);
  if (any(['naveg', 'navig'])) return (CupertinoIcons.folder_fill, 'teal', 2);
  if (any(['util'])) return (CupertinoIcons.wrench_fill, 'gray', 2);
  return (CupertinoIcons.square_grid_2x2_fill, 'gray', 2);
}

/// Glifo no estilo SF de um tipo de ação; os desconhecidos usam o ícone do catálogo.
IconData actionGlyph(ActionSchema s) => switch (s.type) {
      'hotkey' || 'key' => CupertinoIcons.keyboard,
      'launch_app' => CupertinoIcons.app_badge,
      'activatewindow' => CupertinoIcons.macwindow,
      'media' => CupertinoIcons.playpause_fill,
      'mixer' => CupertinoIcons.speaker_2_fill,
      'multi' => CupertinoIcons.list_bullet,
      'discord' => CupertinoIcons.headphones,
      'obs' => CupertinoIcons.videocam_fill,
      'soundboard' => CupertinoIcons.speaker_3_fill,
      'tuya' || 'homeassistant' || 'hue' => CupertinoIcons.lightbulb_fill,
      'open_profile' => CupertinoIcons.folder_fill,
      'back' => CupertinoIcons.arrow_left,
      'timer' => CupertinoIcons.timer,
      'http' => CupertinoIcons.globe,
      'script' => CupertinoIcons.chevron_left_slash_chevron_right,
      'steam' => CupertinoIcons.gamecontroller_fill,
      'windows' => CupertinoIcons.desktopcomputer,
      'network' => CupertinoIcons.wifi,
      'spotify' => CupertinoIcons.music_note,
      _ => s.iconData,
    };

Color systemColor(AppleColors c, String name) => switch (name) {
      'blue' => c.blue,
      'pink' => c.pink,
      'purple' => c.purple,
      'orange' => c.orange,
      'indigo' => c.indigo,
      'teal' => c.teal,
      'green' => c.green,
      'red' => c.red,
      _ => c.gray,
    };
