import 'package:flutter/services.dart';

/// Um atalho gravado: modificadores e a tecla. O PC recebe no formato do SendKeys
/// (^ Ctrl, + Shift, % Alt, # Win/Command, {F5}...), o mesmo da ação "hotkey".
class KeyCombo {
  final bool ctrl;
  final bool shift;
  final bool alt;

  /// Win no Windows, Command no Mac (o PC traduz).
  final bool meta;
  final LogicalKeyboardKey key;

  const KeyCombo(this.key, {this.ctrl = false, this.shift = false, this.alt = false, this.meta = false});

  static final _modifiers = <LogicalKeyboardKey>{
    LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlRight, LogicalKeyboardKey.control,
    LogicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftRight, LogicalKeyboardKey.shift,
    LogicalKeyboardKey.altLeft, LogicalKeyboardKey.altRight, LogicalKeyboardKey.alt,
    LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaRight, LogicalKeyboardKey.meta,
  };

  static bool isModifier(LogicalKeyboardKey k) => _modifiers.contains(k);

  /// Teclas especiais e o nome delas no SendKeys.
  static final _special = <LogicalKeyboardKey, String>{
    LogicalKeyboardKey.enter: '{ENTER}',
    LogicalKeyboardKey.numpadEnter: '{ENTER}',
    LogicalKeyboardKey.tab: '{TAB}',
    LogicalKeyboardKey.escape: '{ESC}',
    LogicalKeyboardKey.backspace: '{BACKSPACE}',
    LogicalKeyboardKey.delete: '{DEL}',
    LogicalKeyboardKey.insert: '{INSERT}',
    LogicalKeyboardKey.home: '{HOME}',
    LogicalKeyboardKey.end: '{END}',
    LogicalKeyboardKey.pageUp: '{PGUP}',
    LogicalKeyboardKey.pageDown: '{PGDN}',
    LogicalKeyboardKey.arrowUp: '{UP}',
    LogicalKeyboardKey.arrowDown: '{DOWN}',
    LogicalKeyboardKey.arrowLeft: '{LEFT}',
    LogicalKeyboardKey.arrowRight: '{RIGHT}',
    LogicalKeyboardKey.space: ' ',
    LogicalKeyboardKey.printScreen: '{PRTSC}',
    LogicalKeyboardKey.capsLock: '{CAPSLOCK}',
    for (var i = 1; i <= 24; i++) _fKey(i): '{F$i}',
  };

  static LogicalKeyboardKey _fKey(int n) => LogicalKeyboardKey(LogicalKeyboardKey.f1.keyId + n - 1);

  /// Caracteres que o SendKeys lê como comando: vão entre chaves.
  static const _escaped = '+^%~(){}[]#';

  /// Texto da tecla no SendKeys, ou null se a tecla não serve para atalho.
  static String? keyText(LogicalKeyboardKey k) {
    final special = _special[k];
    if (special != null) return special;
    final label = k.keyLabel;
    if (label.length != 1) return null;
    final ch = label.toLowerCase();
    return _escaped.contains(ch) ? '{$ch}' : ch;
  }

  /// Atalho válido: tem tecla, e letra/número sozinho exige um modificador (senão é só
  /// digitar). Teclas de função e especiais valem sozinhas.
  bool get isValid {
    final t = keyText(key);
    if (t == null) return false;
    final plain = t.length == 1 && t != ' ';
    return !plain || ctrl || alt || meta;
  }

  String get sendKeys {
    final b = StringBuffer();
    if (ctrl) b.write('^');
    if (shift) b.write('+');
    if (alt) b.write('%');
    if (meta) b.write('#');
    b.write(keyText(key) ?? '');
    return b.toString();
  }

  /// Como aparece na tela: "⌘⇧K" no Mac, "Ctrl+Shift+K" no resto.
  String display({required bool mac}) =>
      prettyKeys(sendKeys, mac: mac);
}

/// Mostra um atalho no formato do SendKeys de um jeito legível.
String prettyKeys(String keys, {required bool mac}) {
  final mods = <String>[];
  var i = 0;
  while (i < keys.length && '^+%#'.contains(keys[i])) {
    // "^{+}" é Ctrl + a tecla "+": para no primeiro que não é modificador.
    mods.add(keys[i]);
    i++;
  }
  var rest = keys.substring(i);
  if (rest.startsWith('{') && rest.endsWith('}') && rest.length > 2) {
    rest = rest.substring(1, rest.length - 1);
  }
  final keyName = switch (rest) {
    ' ' => mac ? '␣' : 'Space',
    'ENTER' => mac ? '↩' : 'Enter',
    'TAB' => mac ? '⇥' : 'Tab',
    'ESC' => mac ? '⎋' : 'Esc',
    'BACKSPACE' => mac ? '⌫' : 'Backspace',
    'DEL' => mac ? '⌦' : 'Del',
    'UP' => '↑',
    'DOWN' => '↓',
    'LEFT' => '←',
    'RIGHT' => '→',
    'PGUP' => mac ? '⇞' : 'PgUp',
    'PGDN' => mac ? '⇟' : 'PgDn',
    _ => rest.toUpperCase(),
  };
  // Ordem da Apple: ⌃ ⌥ ⇧ ⌘.
  if (mac) {
    final order = ['^', '%', '+', '#'];
    const sym = {'^': '⌃', '%': '⌥', '+': '⇧', '#': '⌘'};
    return [for (final m in order) if (mods.contains(m)) sym[m]!].join() + keyName;
  }
  const names = {'^': 'Ctrl', '+': 'Shift', '%': 'Alt', '#': 'Win'};
  final order = ['^', '#', '%', '+'];
  return [for (final m in order) if (mods.contains(m)) names[m]!, keyName].join('+');
}
