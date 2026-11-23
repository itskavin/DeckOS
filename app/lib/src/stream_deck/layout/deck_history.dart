import 'package:deckos/core/core.dart';

/// Uma mudança num perfil: como estava e como ficou.
class DeckEdit {
  final DeckProfile before;
  final DeckProfile after;

  /// O que foi feito ("Mover botão"), para o menu Desfazer.
  final String label;

  const DeckEdit(this.before, this.after, this.label);

  String get profileId => after.id;
}

/// Pilhas de desfazer/refazer das edições feitas nesta sessão do configurador. Guarda o
/// perfil inteiro antes e depois (um perfil é pequeno), então desfazer é só regravar o
/// "antes". Uma edição nova apaga o que dava para refazer.
class DeckHistory {
  DeckHistory({this.limit = 100});

  final int limit;
  final _undo = <DeckEdit>[];
  final _redo = <DeckEdit>[];

  /// Muda a cada operação: a tela observa para habilitar os botões.
  final version = signal(0);

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;
  String? get undoLabel => _undo.isEmpty ? null : _undo.last.label;
  String? get redoLabel => _redo.isEmpty ? null : _redo.last.label;

  void record(DeckEdit edit) {
    _undo.add(edit);
    if (_undo.length > limit) _undo.removeAt(0);
    _redo.clear();
    version.value++;
  }

  /// Tira a última edição da pilha; quem chama regrava [DeckEdit.before].
  DeckEdit? undo() {
    if (_undo.isEmpty) return null;
    final e = _undo.removeLast();
    _redo.add(e);
    version.value++;
    return e;
  }

  /// Refaz a última desfeita; quem chama regrava [DeckEdit.after].
  DeckEdit? redo() {
    if (_redo.isEmpty) return null;
    final e = _redo.removeLast();
    _undo.add(e);
    version.value++;
    return e;
  }

  /// Esquece as edições de um perfil (ele foi apagado) ou todas.
  void forget([String? profileId]) {
    if (profileId == null) {
      _undo.clear();
      _redo.clear();
    } else {
      _undo.removeWhere((e) => e.profileId == profileId);
      _redo.removeWhere((e) => e.profileId == profileId);
    }
    version.value++;
  }
}
