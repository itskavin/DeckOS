import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

import '../stream_deck_page.dart' show DeckGridFit;
import '../widgets/dynamic_deck_button.dart';
import 'grid_placement.dart';
import 'library_items.dart';
import 'slot_ops.dart';

/// Espelho ao vivo da página atual dentro de uma moldura de celular, com as mesmas
/// teclas que o celular desenha. Clique escolhe a casa, arrastar move/troca, soltar um
/// item da biblioteca cria o botão, e arrastar um botão para fora do celular o remove.
class DeckMirror extends StatefulWidget {
  final DeckProfile profile;

  /// Grade reportada pelo celular.
  final int rows;
  final int columns;
  final bool landscape;
  final Set<Slot> selection;

  /// Botão em edição no inspetor: aparece no lugar do salvo enquanto se edita.
  final DeckButton? draft;

  final int pageIndex;
  final int pageCount;
  final ValueChanged<int>? onPageTap;

  final void Function(Slot slot, DeckButton? button) onSlotTap;
  final void Function(DeckDrag data, Slot target) onDrop;
  final void Function(ButtonDrag data) onDragOut;

  /// Começo/fim de um arrasto de botão (a tela mostra a dica de remover).
  final ValueChanged<bool>? onDragging;

  /// Tamanho máximo da moldura.
  final double maxHeight;

  const DeckMirror({
    super.key,
    required this.profile,
    required this.rows,
    required this.columns,
    required this.landscape,
    required this.selection,
    required this.onSlotTap,
    required this.onDrop,
    required this.onDragOut,
    this.draft,
    this.pageIndex = 0,
    this.pageCount = 1,
    this.onPageTap,
    this.onDragging,
    this.maxHeight = 360,
  });

  @override
  State<DeckMirror> createState() => _DeckMirrorState();
}

class _DeckMirrorState extends State<DeckMirror> {
  final _screenKey = GlobalKey();

  bool _insideScreen(Offset global) {
    final box = _screenKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return true;
    final local = box.globalToLocal(global);
    return (Offset.zero & box.size).inflate(24).contains(local);
  }

  @override
  Widget build(BuildContext context) {
    // No espelho a tecla aparece com mais respiro em volta do ícone do app, seguindo a escala escolhida.
    final theme = Theme.of(context);
    final deck = DeckTheme.of(context);
    return Theme(
      data: theme.copyWith(
        extensions: [
          ...theme.extensions.values.where((e) => e is! DeckTheme),
          deck.copyWith(appIconFraction: (deck.appIconFraction * 0.78).clamp(0.48, 0.72)),
        ],
      ),
      child: _frame(),
    );
  }

  Widget _frame() {
    return LayoutBuilder(builder: (context, c) {
      const ratio = 19.5 / 9;
      double w, h;
      if (widget.landscape) {
        w = math.min(c.maxWidth, widget.maxHeight * ratio);
        w = math.min(w, 760);
        h = w / ratio;
      } else {
        h = widget.maxHeight;
        w = h / ratio;
        if (w > c.maxWidth) {
          w = c.maxWidth;
          h = w * ratio;
        }
      }
      return Center(
        child: SizedBox(
          width: w,
          height: h,
          child: PhoneFrame(
            landscape: widget.landscape,
            screenColor: DeckTheme.of(context).background,
            child: KeyedSubtree(key: _screenKey, child: _screen()),
          ),
        ),
      );
    });
  }

  Widget _screen() {
    return LayoutBuilder(builder: (context, c) {
      final short = math.min(c.maxWidth, c.maxHeight);
      // Respiro para a ilha da câmera (à esquerda, deitado; no topo, em pé) e os pontos.
      final pad = EdgeInsets.fromLTRB(
        widget.landscape ? short * 0.17 : short * 0.06,
        widget.landscape ? short * 0.09 : short * 0.16,
        widget.landscape ? short * 0.13 : short * 0.06,
        short * 0.13,
      );
      return Stack(
        children: [
          Positioned.fill(
            child: Padding(padding: pad, child: _grid()),
          ),
          if (widget.pageCount > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: short * 0.04,
              child: Center(
                child: PageDots(
                  // A tela do celular tem a cor do deck, não a do configurador.
                  color: DeckTheme.of(context).foreground,
                  inactiveColor: DeckTheme.of(context).foreground.withValues(alpha: 0.3),
                  count: widget.pageCount,
                  index: widget.pageIndex,
                  onTap: widget.onPageTap,
                ),
              ),
            ),
        ],
      );
    });
  }

  Widget _grid() {
    final p = widget.profile;
    final deckSpacing = DeckTheme.of(context).spacing;
    var buttons = p.buttons;
    final draft = widget.draft;
    if (draft != null) {
      buttons = [
        for (final b in buttons)
          if (b.row != draft.row || b.column != draft.column) b,
        if (draft.id.isNotEmpty || (draft.label?.isNotEmpty ?? false)) draft,
      ];
    }
    // Nunca esconde botões se esta página ocupar mais espaço que a grade global.
    final pageMin = SlotOps.minGrid(buttons);
    final baseCols = math.max(widget.columns, pageMin.columns);
    final baseRows = math.max(widget.rows, pageMin.rows);
    // Em pé, a grade deitada do celular não cabe: os botões entram em ordem de leitura
    // numa grade mais estreita, como no celular girado. Só para ver: sem mover.
    final displayCols =
        widget.landscape ? math.max(baseCols, baseRows) : math.min(baseCols, baseRows);
    final reflow = displayCols != baseCols;
    final shown = reflow ? reflowButtons(buttons, displayCols) : buttons;
    var rows = reflow ? baseCols : baseRows;
    if (reflow) {
      for (final b in shown) {
        rows = math.max(rows, b.row + b.rowSpan);
      }
    }
    final original = {for (final b in buttons) b.id: b};

    return LayoutBuilder(builder: (context, c) {
      final cols = displayCols;
      // O vão acompanha a tecla e o espaçamento escolhido, como no celular.
      final (fit, spacing) = DeckGridFit.fitCell(
        c.biggest,
        cols,
        rows,
        4 * deckSpacing.marginScale,
        ratio: deckSpacing.gapRatio,
      );
      final cell = math.max(8.0, fit);
      final step = cell + spacing;
      double size(int span) => span * cell + (span - 1) * spacing;
      final layout = GridLayout.of(shown, rows, cols);
      return Center(
        child: SizedBox(
          width: size(cols),
          height: size(rows),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var r = 0; r < rows; r++)
                for (var col = 0; col < cols; col++)
                  if (layout.isFree(r, col))
                    Positioned(
                      left: col * step,
                      top: r * step,
                      width: cell,
                      height: cell,
                      child: _MirrorSlot(
                        key: ValueKey('e$r:$col'),
                        slot: (row: r, column: col),
                        button: null,
                        buttons: buttons,
                        gridRows: baseRows,
                        gridColumns: baseCols,
                        cell: cell,
                        tileWidth: cell,
                        tileHeight: cell,
                        movable: !reflow,
                        selected: !reflow && widget.selection.contains((row: r, column: col)),
                        selection: widget.selection,
                        onTap: () {
                          if (reflow) {
                            final free = SlotOps.firstEmpty(p.buttons, baseRows, baseCols);
                            if (free != null) widget.onSlotTap(free, null);
                          } else {
                            widget.onSlotTap((row: r, column: col), null);
                          }
                        },
                        onDrop: (d) {
                          if (!reflow) widget.onDrop(d, (row: r, column: col));
                        },
                        onDragOut: widget.onDragOut,
                        insideScreen: _insideScreen,
                        onDragging: widget.onDragging,
                      ),
                    ),
              for (final pl in layout.placements)
                Positioned(
                  left: pl.column * step,
                  top: pl.row * step,
                  width: size(pl.columnSpan),
                  height: size(pl.rowSpan),
                  child: Builder(builder: (context) {
                    final real = original[pl.button.id] ?? pl.button;
                    final slot = slotOf(real);
                    return _MirrorSlot(
                      key: ValueKey('b${pl.button.id}'),
                      slot: slot,
                      button: pl.button,
                      buttons: buttons,
                      gridRows: baseRows,
                      gridColumns: baseCols,
                      cell: cell,
                      tileWidth: size(pl.columnSpan),
                      tileHeight: size(pl.rowSpan),
                      movable: !reflow,
                      selected: widget.selection.contains(slot),
                      selection: widget.selection,
                      onTap: () => widget.onSlotTap(slot, real),
                      onDrop: (d) {
                        if (!reflow) widget.onDrop(d, slot);
                      },
                      onDragOut: widget.onDragOut,
                      insideScreen: _insideScreen,
                      onDragging: widget.onDragging,
                    );
                  }),
                ),
            ],
          ),
        ),
      );
    });
  }
}

class _MirrorSlot extends StatefulWidget {
  final Slot slot;
  final DeckButton? button;
  final List<DeckButton> buttons;
  final int gridRows;
  final int gridColumns;
  final double cell;
  final double tileWidth;
  final double tileHeight;
  final bool movable;
  final bool selected;
  final Set<Slot> selection;
  final VoidCallback onTap;
  final ValueChanged<DeckDrag> onDrop;
  final void Function(ButtonDrag) onDragOut;
  final bool Function(Offset global) insideScreen;
  final ValueChanged<bool>? onDragging;

  const _MirrorSlot({
    super.key,
    required this.slot,
    required this.button,
    required this.buttons,
    required this.gridRows,
    required this.gridColumns,
    required this.cell,
    required this.tileWidth,
    required this.tileHeight,
    required this.movable,
    required this.selected,
    required this.selection,
    required this.onTap,
    required this.onDrop,
    required this.onDragOut,
    required this.insideScreen,
    this.onDragging,
  });

  @override
  State<_MirrorSlot> createState() => _MirrorSlotState();
}

class _MirrorSlotState extends State<_MirrorSlot> {
  bool _hover = false;

  bool _canAcceptDrag(DeckDrag drag) {
    return switch (drag) {
      ButtonDrag(:final from, :final group) => widget.movable &&
          from != widget.slot &&
          (group.length > 1
              ? SlotOps.moveGroup(
                    widget.buttons,
                    group,
                    widget.slot.row - from.row,
                    widget.slot.column - from.column,
                    widget.gridRows,
                    widget.gridColumns,
                  ) !=
                  null
              : SlotOps.canDrop(
                  widget.buttons,
                  from,
                  widget.slot,
                  rows: widget.gridRows,
                  columns: widget.gridColumns,
                )),
      LibraryDrag() => true,
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final button = widget.button;
    return DragTarget<DeckDrag>(
      onWillAcceptWithDetails: (d) => switch (d.data) {
        ButtonDrag(:final from) => widget.movable && from != widget.slot,
        LibraryDrag() => true,
      },
      onAcceptWithDetails: (d) => widget.onDrop(d.data),
      builder: (context, candidate, _) {
        final dropping = candidate.isNotEmpty;
        final dropValid = dropping && candidate.first != null && _canAcceptDrag(candidate.first!);
        final Widget tile = button == null
            ? _EmptySlot(hover: _hover || dropping, onTap: widget.onTap)
            : DynamicDeckButton(button: button, onTap: widget.onTap, onLongPress: widget.onTap);

        final ringColor = dropping
            ? (dropValid ? c.green : c.red)
            : widget.selected
                ? c.accent
                : (_hover && button != null ? c.label.withValues(alpha: 0.25) : null);
        final radius = AppleShapes.tileRadius(widget.cell);
        Widget content = Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: [
            AnimatedScale(
              scale: dropping ? (dropValid ? 1.06 : 0.97) : 1,
              duration: AppleMotion.of(context, AppleMotion.fast),
              curve: AppleMotion.snappy,
              child: tile,
            ),
            if (ringColor != null)
              Positioned(
                left: -4,
                top: -4,
                right: -4,
                bottom: -4,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: ShapeDecoration(
                      shape: AppleShapes.squircle(
                        radius + 4,
                        side: BorderSide(color: ringColor, width: 2.5),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
        content = MouseRegion(
          cursor: button == null ? SystemMouseCursors.click : SystemMouseCursors.grab,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: content,
        );
        if (button == null || !widget.movable) return content;

        final group = widget.selected && widget.selection.length > 1
            ? widget.selection
            : {widget.slot};
        final data = ButtonDrag(widget.slot, group);
        return Draggable<DeckDrag>(
          data: data,
          onDragStarted: () => widget.onDragging?.call(true),
          onDragEnd: (_) => widget.onDragging?.call(false),
          onDraggableCanceled: (_, offset) {
            final center = offset + Offset(widget.tileWidth / 2, widget.tileHeight / 2);
            if (!widget.insideScreen(center)) widget.onDragOut(data);
          },
          feedback: _DragFeedback(
            width: widget.tileWidth,
            height: widget.tileHeight,
            radius: radius,
            count: group.length,
            child: DynamicDeckButton(button: button, onTap: () {}, onLongPress: () {}),
          ),
          childWhenDragging: Opacity(opacity: 0.25, child: tile),
          child: content,
        );
      },
    );
  }
}

class _EmptySlot extends StatelessWidget {
  final bool hover;
  final VoidCallback onTap;

  const _EmptySlot({required this.hover, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: hover ? 1 : 0.75,
      duration: AppleMotion.of(context, AppleMotion.fast),
      child: DeckSquircleEmptyTile(onTap: onTap),
    );
  }
}

/// O que segue o ponteiro ao arrastar: a tecla levantada, com a contagem se forem várias.
class _DragFeedback extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  final int count;
  final Widget child;

  const _DragFeedback({
    required this.width,
    required this.height,
    required this.radius,
    required this.count,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return Transform.scale(
      scale: 1.08,
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: AppleShapes.squircle(radius),
                    shadows: AppleShadows.floating(Theme.of(context).brightness),
                  ),
                  child: child,
                ),
              ),
              if (count > 1)
                Positioned(
                  right: -8,
                  top: -8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: ShapeDecoration(color: c.red, shape: const StadiumBorder()),
                    child: Text('$count',
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
