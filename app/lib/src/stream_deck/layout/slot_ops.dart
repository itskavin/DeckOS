import 'dart:math' as math;

import 'package:deckos/core/core.dart';

import 'grid_placement.dart';

/// Uma casa da grade.
typedef Slot = ({int row, int column});

Slot slotOf(DeckButton b) => (row: b.row, column: b.column);

/// Operações da grade do configurador e do celular, sem estado: recebem a lista de botões
/// do perfil e devolvem a lista nova. A tela salva o resultado (e guarda o antes para
/// desfazer).
class SlotOps {
  SlotOps._();

  static DeckButton? at(List<DeckButton> buttons, Slot s) =>
      buttons.where((b) => b.row == s.row && b.column == s.column).firstOrNull;

  static int _rowSpan(DeckButton b) => math.max(1, b.rowSpan);
  static int _colSpan(DeckButton b) => math.max(1, b.columnSpan);

  static bool _fitsBounds(int row, int col, int rs, int cs, int rows, int cols) =>
      row >= 0 && col >= 0 && row + rs <= rows && col + cs <= cols;

  static Set<Slot> _footprint(int row, int col, int rs, int cs) => {
        for (var r = row; r < row + rs; r++)
          for (var c = col; c < col + cs; c++) (row: r, column: c),
      };

  static Set<Slot> footprintOf(DeckButton b) =>
      _footprint(b.row, b.column, _rowSpan(b), _colSpan(b));

  /// Menor grade necessária para comportar todos os botões (considerando botões grandes).
  static ({int rows, int columns}) minGrid(List<DeckButton> buttons) {
    var rows = 1, cols = 1;
    for (final b in buttons) {
      rows = math.max(rows, b.row + _rowSpan(b));
      cols = math.max(cols, b.column + _colSpan(b));
    }
    return (rows: rows, columns: cols);
  }

  /// Move o botão de [from] para [to]; se [to] tem botão, os dois trocam de lugar.
  static List<DeckButton> move(List<DeckButton> buttons, Slot from, Slot to) {
    if (from == to) return buttons;
    final src = at(buttons, from);
    if (src == null) return buttons;
    final dst = at(buttons, to);
    return [
      for (final b in buttons)
        if (identical(b, src))
          b.copyWith(row: to.row, column: to.column)
        else if (identical(b, dst))
          b.copyWith(row: from.row, column: from.column)
        else
          b,
    ];
  }

  /// Move o botão de [from] para [to] respeitando os limites de [rows]×[columns] e o
  /// tamanho de botões grandes (spans). Troca com um ou mais botões deslocados quando
  /// todos cabem sem sobreposição nas casas liberadas; devolve null se não couber
  /// (nenhum botão se perde ou fica escondido).
  static List<DeckButton>? moveSafely(
    List<DeckButton> buttons,
    Slot from,
    Slot to, {
    required int rows,
    required int columns,
  }) {
    if (from == to) return null;
    final src = at(buttons, from);
    if (src == null) return null;

    final rs = _rowSpan(src), cs = _colSpan(src);
    if (!_fitsBounds(to.row, to.column, rs, cs, rows, columns)) return null;

    final srcOld = footprintOf(src);
    final srcNew = _footprint(to.row, to.column, rs, cs);

    // Botões cuja área encosta no destino de [src].
    final displaced = <DeckButton>[];
    final stayingCells = <Slot>{};
    for (final b in buttons) {
      if (identical(b, src)) continue;
      final fp = footprintOf(b);
      if (fp.any(srcNew.contains)) {
        displaced.add(b);
      } else {
        stayingCells.addAll(fp);
      }
    }

    // Destino livre (mesmo sobrepondo parte da posição anterior do próprio botão).
    if (displaced.isEmpty) {
      return [
        for (final b in buttons)
          identical(b, src) ? b.copyWith(row: to.row, column: to.column) : b,
      ];
    }

    final occupied = <Slot>{...stayingCells, ...srcNew};
    final relocated = <DeckButton, Slot>{};

    // Caso 1: troca direta com um único botão (tenta o canto de origem primeiro).
    if (displaced.length == 1) {
      final dst = displaced.first;
      final drs = _rowSpan(dst), dcs = _colSpan(dst);
      if (_fitsBounds(from.row, from.column, drs, dcs, rows, columns)) {
        final candidate = _footprint(from.row, from.column, drs, dcs);
        if (!candidate.any(occupied.contains)) {
          relocated[dst] = from;
        }
      }
    }

    // Caso 2: realoca os botões deslocados nas casas liberadas por [src] (ex.: botão 2×1
    // trocando com dois botões 1×1, ou um 1×1 trocando com um 2×1 adjacente).
    if (relocated.length != displaced.length) {
      relocated.clear();
      final vacated = srcOld.difference(srcNew);
      final used = <Slot>{...occupied};
      // Ordena maiores primeiro para maximizar o encaixe nas casas liberadas.
      final ordered = [...displaced]
        ..sort((a, b) {
          final areaDiff = (_rowSpan(b) * _colSpan(b)) - (_rowSpan(a) * _colSpan(a));
          if (areaDiff != 0) return areaDiff;
          return a.row != b.row ? a.row.compareTo(b.row) : a.column.compareTo(b.column);
        });
      // Casas candidatas: todas as casas liberadas em ordem de leitura (e a origem).
      final candidates = vacated.toList()
        ..sort((a, b) => a.row != b.row ? a.row.compareTo(b.row) : a.column.compareTo(b.column));
      for (final d in ordered) {
        final drs = _rowSpan(d), dcs = _colSpan(d);
        Slot? placed;
        // Primeiro tenta preservar o deslocamento relativo dentro do bloco.
        final relRow = from.row + (d.row - to.row);
        final relCol = from.column + (d.column - to.column);
        if (_fitsBounds(relRow, relCol, drs, dcs, rows, columns)) {
          final fp = _footprint(relRow, relCol, drs, dcs);
          if (fp.every(vacated.contains) && !fp.any(used.contains)) {
            placed = (row: relRow, column: relCol);
          }
        }
        // Senão procura a primeira posição dentro das casas liberadas.
        if (placed == null) {
          for (final slot in candidates) {
            if (!_fitsBounds(slot.row, slot.column, drs, dcs, rows, columns)) continue;
            final fp = _footprint(slot.row, slot.column, drs, dcs);
            if (fp.every(vacated.contains) && !fp.any(used.contains)) {
              placed = slot;
              break;
            }
          }
        }
        if (placed == null) return null;
        relocated[d] = placed;
        used.addAll(_footprint(placed.row, placed.column, drs, dcs));
      }
    }

    return [
      for (final b in buttons)
        if (identical(b, src))
          b.copyWith(row: to.row, column: to.column)
        else if (relocated.containsKey(b))
          b.copyWith(row: relocated[b]!.row, column: relocated[b]!.column)
        else
          b,
    ];
  }

  /// Indica se soltar [from] em [to] é seguro nesta grade (para destaque visual ao arrastar).
  static bool canDrop(
    List<DeckButton> buttons,
    Slot from,
    Slot to, {
    required int rows,
    required int columns,
  }) =>
      moveSafely(buttons, from, to, rows: rows, columns: columns) != null;

  /// Move vários botões juntos, deslocados de ([dRow], [dCol]). Null se algum sairia da
  /// grade de [rows]×[columns] ou cairia em cima de um botão que não está no grupo.
  static List<DeckButton>? moveGroup(
      List<DeckButton> buttons, Set<Slot> group, int dRow, int dCol, int rows, int columns) {
    if (dRow == 0 && dCol == 0) return buttons;
    final moving = buttons.where((b) => group.contains(slotOf(b))).toSet();
    if (moving.isEmpty) return null;
    final stayingCells = <Slot>{
      for (final b in buttons)
        if (!moving.contains(b)) ...footprintOf(b),
    };
    final movedCells = <Slot>{};
    for (final b in moving) {
      final r = b.row + dRow, c = b.column + dCol;
      final rs = _rowSpan(b), cs = _colSpan(b);
      if (!_fitsBounds(r, c, rs, cs, rows, columns)) return null;
      final fp = _footprint(r, c, rs, cs);
      if (fp.any(stayingCells.contains) || fp.any(movedCells.contains)) return null;
      movedCells.addAll(fp);
    }
    return [
      for (final b in buttons)
        moving.contains(b) ? b.copyWith(row: b.row + dRow, column: b.column + dCol) : b,
    ];
  }

  /// Põe [button] em [s], substituindo o que estiver lá.
  static List<DeckButton> place(List<DeckButton> buttons, DeckButton button, Slot s) => [
        for (final b in buttons)
          if (b.row != s.row || b.column != s.column) b,
        button.copyWith(row: s.row, column: s.column),
      ];

  /// Tira os botões das casas de [slots].
  static List<DeckButton> remove(List<DeckButton> buttons, Set<Slot> slots) =>
      [for (final b in buttons) if (!slots.contains(slotOf(b))) b];

  /// Primeira casa livre em ordem de leitura, ou null com a grade cheia. Casa com botão
  /// escondido (fora da grade de outro aparelho, coberta por um botão grande) conta como
  /// ocupada.
  static Slot? firstEmpty(List<DeckButton> buttons, int rows, int columns) {
    final layout = GridLayout.of(buttons, rows, columns);
    final anchors = {for (final b in buttons) GridLayout.key(b.row, b.column)};
    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < columns; c++) {
        if (layout.isFree(r, c) && !anchors.contains(GridLayout.key(r, c))) {
          return (row: r, column: c);
        }
      }
    }
    return null;
  }

  /// Quantos botões aparecem numa grade de [rows]×[columns].
  static int visibleCount(List<DeckButton> buttons, int rows, int columns) =>
      GridLayout.of(buttons, rows, columns).placements.length;

  /// Non-destructive plan to fit [buttons] into a target [rows]×[columns] grid.
  /// Never drops buttons, labels, actions, or dynamic bindings:
  /// - [GridFitStatus.fitsAsIs]: every button already sits within [rows]×[columns].
  /// - [GridFitStatus.needsReflow]: all buttons fit inside [rows]×[columns] once rearranged.
  /// - [GridFitStatus.needsExpandAndReflow]: even after rearranging, at least [requiredRows]
  ///   rows are needed so zero buttons are lost or overlapped.
  static GridFitPlan planGridFit(
    List<DeckButton> buttons, {
    required int rows,
    required int columns,
  }) {
    final targetRows = rows.clamp(1, 20);
    final targetCols = columns.clamp(1, 20);
    if (buttons.isEmpty) {
      return GridFitPlan(
        status: GridFitStatus.fitsAsIs,
        buttons: buttons,
        requiredRows: targetRows,
        requiredColumns: targetCols,
        narrowedSpanCount: 0,
      );
    }
    final min = minGrid(buttons);
    if (min.rows <= targetRows && min.columns <= targetCols) {
      return GridFitPlan(
        status: GridFitStatus.fitsAsIs,
        buttons: buttons,
        requiredRows: targetRows,
        requiredColumns: targetCols,
        narrowedSpanCount: 0,
      );
    }
    final reflowed = reflowButtons(buttons, targetCols);
    final needed = minGrid(reflowed);
    var narrowed = 0;
    for (final b in buttons) {
      if (b.columnSpan > targetCols) narrowed++;
    }
    final fitsRequested = needed.rows <= targetRows;
    return GridFitPlan(
      status: fitsRequested
          ? GridFitStatus.needsReflow
          : GridFitStatus.needsExpandAndReflow,
      buttons: reflowed,
      requiredRows: math.max(targetRows, needed.rows),
      requiredColumns: math.max(targetCols, needed.columns),
      narrowedSpanCount: narrowed,
    );
  }
}

enum GridFitStatus { fitsAsIs, needsReflow, needsExpandAndReflow }

class GridFitPlan {
  final GridFitStatus status;
  final List<DeckButton> buttons;
  final int requiredRows;
  final int requiredColumns;
  final int narrowedSpanCount;

  const GridFitPlan({
    required this.status,
    required this.buttons,
    required this.requiredRows,
    required this.requiredColumns,
    required this.narrowedSpanCount,
  });

  bool get fitsAsIs => status == GridFitStatus.fitsAsIs;
  bool get needsRearrange => status != GridFitStatus.fitsAsIs;
  bool get needsExpand => status == GridFitStatus.needsExpandAndReflow;
}
