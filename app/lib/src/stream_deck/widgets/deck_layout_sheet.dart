import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/layout/grid_placement.dart';
import 'package:deckos/src/stream_deck/layout/slot_ops.dart';
import 'package:deckos/src/stream_deck/widgets/dynamic_deck_button.dart';
import 'package:flutter/material.dart';

/// Resultado confirmado pelo painel de layout da grade.
/// Cancelar ou fechar sem salvar devolve null (nada é salvo parcialmente).
@immutable
class DeckLayoutResult {
  const DeckLayoutResult({
    required this.autoGrid,
    required this.rows,
    required this.columns,
    required this.spacing,
    required this.iconSize,
    required this.showLabels,
  });

  /// Quando verdadeiro (no celular), a grade acompanha o tamanho da tela.
  final bool autoGrid;
  final int rows;
  final int columns;
  final DeckSpacing spacing;
  final DeckIconSize iconSize;
  final bool showLabels;
}

/// Folha de personalização do layout do deck (grade compartilhada + aparência local).
/// Usada tanto no celular quanto no configurador do PC, com prévia ao vivo dos botões
/// reais da página atual e confirmação explícita (Salvar / Cancelar).
class DeckLayoutSheet extends StatefulWidget {
  const DeckLayoutSheet({
    super.key,
    required this.profile,
    required this.allProfiles,
    required this.initialRows,
    required this.initialColumns,
    required this.initialAutoGrid,
    required this.autoRows,
    required this.autoColumns,
    required this.allowAutoGrid,
    required this.initialSettings,
  });

  final DeckProfile profile;
  final List<DeckProfile> allProfiles;
  final int initialRows;
  final int initialColumns;
  final bool initialAutoGrid;

  /// Dimensões calculadas automaticamente para a tela atual (quando [allowAutoGrid]).
  final int autoRows;
  final int autoColumns;

  /// Celular oferece modo Automático; configurador escolhe a grade compartilhada.
  final bool allowAutoGrid;
  final ThemeSettings initialSettings;

  static const _presets = <({int cols, int rows})>[
    (cols: 3, rows: 2),
    (cols: 4, rows: 2),
    (cols: 4, rows: 3),
    (cols: 5, rows: 3),
    (cols: 6, rows: 3),
  ];

  static Future<DeckLayoutResult?> show(
    BuildContext context, {
    required DeckProfile profile,
    required List<DeckProfile> allProfiles,
    required int initialRows,
    required int initialColumns,
    required bool initialAutoGrid,
    required int autoRows,
    required int autoColumns,
    required bool allowAutoGrid,
    required ThemeSettings initialSettings,
  }) {
    return showAppleSheet<DeckLayoutResult>(
      context: context,
      builder: (_) => DeckLayoutSheet(
        profile: profile,
        allProfiles: allProfiles,
        initialRows: initialRows,
        initialColumns: initialColumns,
        initialAutoGrid: initialAutoGrid,
        autoRows: autoRows,
        autoColumns: autoColumns,
        allowAutoGrid: allowAutoGrid,
        initialSettings: initialSettings,
      ),
    );
  }

  @override
  State<DeckLayoutSheet> createState() => _DeckLayoutSheetState();
}

class _DeckLayoutSheetState extends State<DeckLayoutSheet> {
  late final ({int rows, int columns}) _pageMin =
      SlotOps.minGrid(widget.profile.buttons);

  late bool _autoGrid = widget.allowAutoGrid && widget.initialAutoGrid;
  late int _rows = math.max(widget.initialRows, _pageMin.rows).clamp(1, 10);
  late int _cols =
      math.max(widget.initialColumns, _pageMin.columns).clamp(1, 10);
  late DeckSpacing _spacing = widget.initialSettings.spacing;
  late DeckIconSize _iconSize = widget.initialSettings.iconSize;
  late bool _showLabels = widget.initialSettings.effectiveShowLabels;

  int get _effectiveRows =>
      math.max(_autoGrid ? widget.autoRows : _rows, _pageMin.rows).clamp(1, 10);

  int get _effectiveCols =>
      math.max(_autoGrid ? widget.autoColumns : _cols, _pageMin.columns)
          .clamp(1, 10);

  /// Alguma outra página tem botões além da grade escolhida? (Ela expande sozinha sem perder nada.)
  bool get _otherPagesLarger {
    for (final p in widget.allProfiles) {
      if (p.id == widget.profile.id) continue;
      final min = SlotOps.minGrid(p.buttons);
      if (min.columns > _effectiveCols || min.rows > _effectiveRows) {
        return true;
      }
    }
    return false;
  }

  void _selectPreset(int cols, int rows) {
    if (cols < _pageMin.columns || rows < _pageMin.rows) return;
    setState(() {
      _autoGrid = false;
      _cols = cols;
      _rows = rows;
    });
  }

  void _selectAuto() {
    setState(() {
      _autoGrid = true;
      _cols = math.max(widget.autoColumns, _pageMin.columns).clamp(1, 10);
      _rows = math.max(widget.autoRows, _pageMin.rows).clamp(1, 10);
    });
  }

  void _resetDefaults() {
    setState(() {
      _autoGrid = widget.allowAutoGrid;
      _cols = math.max(widget.autoColumns, _pageMin.columns).clamp(1, 10);
      _rows = math.max(widget.autoRows, _pageMin.rows).clamp(1, 10);
      _spacing = DeckSpacing.balanced;
      _iconSize = DeckIconSize.medium;
      _showLabels =
          widget.initialSettings.effectiveTileStyle != DeckTileStyle.squircle;
    });
  }

  void _save() {
    Navigator.of(context).pop(DeckLayoutResult(
      autoGrid: _autoGrid,
      rows: _effectiveRows,
      columns: _effectiveCols,
      spacing: _spacing,
      iconSize: _iconSize,
      showLabels: _showLabels,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final constrainedByPage =
        widget.profile.buttons.isNotEmpty &&
        (_pageMin.columns > 1 || _pageMin.rows > 1);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.86,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Cabeçalho com Cancelar e Salvar bem visíveis.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpacing.sm,
              0,
              AppleSpacing.sm,
              AppleSpacing.xs,
            ),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(tr('Cancelar')),
                ),
                Expanded(
                  child: Text(
                    tr('Layout da grade'),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.headline.copyWith(color: c.label),
                  ),
                ),
                PrimaryButton(
                  label: tr('Salvar'),
                  compact: true,
                  onPressed: _save,
                ),
              ],
            ),
          ),
          Container(height: 1, color: c.separator),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(
                top: AppleSpacing.md,
                bottom: AppleSpacing.lg,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Prévia ao vivo da página atual com ícones e botões reais.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppleSpacing.screen,
                      0,
                      AppleSpacing.screen,
                      AppleSpacing.lg,
                    ),
                    child: _LiveLayoutPreview(
                      profile: widget.profile,
                      rows: _effectiveRows,
                      columns: _effectiveCols,
                      spacing: _spacing,
                      iconSize: _iconSize,
                      showLabels: _showLabels,
                      autoGrid: _autoGrid,
                    ),
                  ),

                  // ---- Grade compartilhada (PC + todos os aparelhos) ----
                  InsetGroupedSection(
                    header: tr('Grade do deck'),
                    footer: [
                      tr('Sincronizado com o PC e outros aparelhos.'),
                      if (constrainedByPage)
                        tr(
                          'Mínimo {cols}×{rows} para manter todos os botões desta página.',
                          {'cols': _pageMin.columns, 'rows': _pageMin.rows},
                        ),
                      if (_otherPagesLarger)
                        tr(
                          'Outras páginas com mais botões continuam mostrando todos sem perder nenhum.',
                        ),
                    ].join(' '),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(AppleSpacing.md),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: AppleSpacing.xs,
                              runSpacing: AppleSpacing.xs,
                              children: [
                                if (widget.allowAutoGrid)
                                  _PresetChip(
                                    label: tr('Automático'),
                                    selected: _autoGrid,
                                    enabled: true,
                                    onTap: _selectAuto,
                                  ),
                                for (final p in DeckLayoutSheet._presets)
                                  _PresetChip(
                                    label: '${p.cols}×${p.rows}',
                                    selected: !_autoGrid &&
                                        _effectiveCols == p.cols &&
                                        _effectiveRows == p.rows,
                                    enabled: p.cols >= _pageMin.columns &&
                                        p.rows >= _pageMin.rows,
                                    onTap: () => _selectPreset(p.cols, p.rows),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      ListRow(
                        leading: ListRowIcon(
                          Icons.view_column_rounded,
                          color: c.blue,
                        ),
                        title: tr('Colunas'),
                        trailing: _GridStepper(
                          value: _effectiveCols,
                          min: _pageMin.columns,
                          max: 10,
                          onChanged: (v) => setState(() {
                            _autoGrid = false;
                            _cols = v;
                          }),
                        ),
                      ),
                      ListRow(
                        leading: ListRowIcon(
                          Icons.view_stream_rounded,
                          color: c.indigo,
                        ),
                        title: tr('Linhas'),
                        trailing: _GridStepper(
                          value: _effectiveRows,
                          min: _pageMin.rows,
                          max: 10,
                          onChanged: (v) => setState(() {
                            _autoGrid = false;
                            _rows = v;
                          }),
                        ),
                      ),
                    ],
                  ),

                  // ---- Aparência local da grade (somente este aparelho) ----
                  InsetGroupedSection(
                    header: tr('Neste aparelho'),
                    footer: tr(
                      'Espaçamento, tamanho dos ícones e nomes ficam salvos apenas neste aparelho.',
                    ),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppleSpacing.md,
                          AppleSpacing.sm,
                          AppleSpacing.md,
                          AppleSpacing.sm,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              tr('Espaçamento'),
                              style: type.subheadline.copyWith(
                                color: c.label,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: AppleSpacing.xs),
                            SegmentedControl<DeckSpacing>(
                              segments: {
                                for (final sp in DeckSpacing.values)
                                  sp: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 5,
                                    ),
                                    child: Text(sp.label),
                                  ),
                              },
                              value: _spacing,
                              onChanged: (v) => setState(() => _spacing = v),
                            ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          AppleSpacing.md,
                          AppleSpacing.sm,
                          AppleSpacing.md,
                          AppleSpacing.sm,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              tr('Tamanho dos ícones'),
                              style: type.subheadline.copyWith(
                                color: c.label,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: AppleSpacing.xs),
                            SegmentedControl<DeckIconSize>(
                              segments: {
                                for (final sz in DeckIconSize.values)
                                  sz: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 5,
                                    ),
                                    child: Text(sz.label),
                                  ),
                              },
                              value: _iconSize,
                              onChanged: (v) => setState(() => _iconSize = v),
                            ),
                          ],
                        ),
                      ),
                      ListRow(
                        leading: ListRowIcon(
                          Icons.text_fields_rounded,
                          color: c.gray,
                        ),
                        title: tr('Mostrar nomes nos botões'),
                        trailing: AppleSwitch(
                          value: _showLabels,
                          onChanged: (v) => setState(() => _showLabels = v),
                        ),
                      ),
                    ],
                  ),

                  Center(
                    child: TextButton.icon(
                      onPressed: _resetDefaults,
                      icon: const Icon(
                        Icons.restart_alt_rounded,
                        size: 18,
                      ),
                      label: Text(tr('Restaurar layout padrão')),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      child: Opacity(
        opacity: enabled ? 1 : 0.35,
        child: ApplePressable(
          onTap: enabled ? onTap : null,
          pressedScale: 0.95,
          haptic: false,
          child: AnimatedContainer(
            duration: AppleMotion.of(context, AppleMotion.fast),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? c.accent : c.tertiaryFill,
              borderRadius: BorderRadius.circular(AppleRadii.sm),
              border: Border.all(
                color: selected ? c.accent : c.separator,
                width: 1,
              ),
            ),
            child: Text(
              label,
              style: type.subheadline.copyWith(
                color: selected ? c.onAccent : c.label,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GridStepper extends StatelessWidget {
  const _GridStepper({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    Widget stepBtn(IconData icon, VoidCallback? onTap) => IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 34, height: 34),
          visualDensity: VisualDensity.compact,
          onPressed: onTap,
          icon: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: onTap != null ? c.tertiaryFill : Colors.transparent,
              borderRadius: BorderRadius.circular(AppleRadii.xs),
              border: Border.all(
                color: onTap != null ? c.separator : c.separator.withValues(alpha: 0.4),
                width: 1,
              ),
            ),
            child: Icon(
              icon,
              size: 16,
              color: onTap != null ? c.label : c.quaternaryLabel,
            ),
          ),
        );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        stepBtn(Icons.remove_rounded, value > min ? () => onChanged(value - 1) : null),
        SizedBox(
          width: 32,
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            style: type.headline.copyWith(
              color: c.label,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        stepBtn(Icons.add_rounded, value < max ? () => onChanged(value + 1) : null),
      ],
    );
  }
}

/// Prévia ao vivo da grade com os botões reais da página atual dentro da moldura.
class _LiveLayoutPreview extends StatelessWidget {
  const _LiveLayoutPreview({
    required this.profile,
    required this.rows,
    required this.columns,
    required this.spacing,
    required this.iconSize,
    required this.showLabels,
    required this.autoGrid,
  });

  final DeckProfile profile;
  final int rows;
  final int columns;
  final DeckSpacing spacing;
  final DeckIconSize iconSize;
  final bool showLabels;
  final bool autoGrid;

  @override
  Widget build(BuildContext context) {
    final baseTheme = Theme.of(context);
    final deck = DeckTheme.of(context).copyWith(
      spacing: spacing,
      appIconFraction: iconSize.appIconFraction,
      glyphScale: iconSize.glyphScale,
      showLabels: showLabels,
    );
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final layout = GridLayout.of(profile.buttons, rows, columns);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Theme(
              data: baseTheme.copyWith(
                extensions: [
                  ...baseTheme.extensions.values.where((e) => e is! DeckTheme),
                  deck,
                ],
              ),
              child: PhoneFrame(
                landscape: true,
                screenColor: deck.background,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    26 * spacing.marginScale,
                    10 * spacing.marginScale,
                    14 * spacing.marginScale,
                    10 * spacing.marginScale,
                  ),
                  child: LayoutBuilder(
                    builder: (context, box) {
                      final ratio = spacing.gapRatio;
                      final minGap = 3.5 * spacing.marginScale;
                      var cell = math.min(
                        box.maxWidth / (columns + ratio * (columns - 1)),
                        box.maxHeight / (rows + ratio * (rows - 1)),
                      );
                      double gap;
                      if (cell * ratio >= minGap) {
                        gap = cell * ratio;
                      } else {
                        gap = minGap;
                        cell = math.min(
                          (box.maxWidth - gap * (columns - 1)) / columns,
                          (box.maxHeight - gap * (rows - 1)) / rows,
                        );
                      }
                      cell = math.max(6.0, cell);
                      final step = cell + gap;
                      double spanSize(int span) =>
                          span * cell + (span - 1) * gap;
                      return Center(
                        child: SizedBox(
                          width: spanSize(columns),
                          height: spanSize(rows),
                          child: IgnorePointer(
                            child: Stack(
                              children: [
                                for (var r = 0; r < rows; r++)
                                  for (var col = 0; col < columns; col++)
                                    if (layout.isFree(r, col))
                                      Positioned(
                                        left: col * step,
                                        top: r * step,
                                        width: cell,
                                        height: cell,
                                        child: DecoratedBox(
                                          decoration: ShapeDecoration(
                                            color: deck.emptyTileColor,
                                            shape: AppleShapes.squircle(
                                              AppleShapes.tileRadius(cell),
                                              side: AppleShapes.hairline(
                                                deck.outline
                                                    .withValues(alpha: 0.10),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                for (final pl in layout.placements)
                                  Positioned(
                                    left: pl.column * step,
                                    top: pl.row * step,
                                    width: spanSize(pl.columnSpan),
                                    height: spanSize(pl.rowSpan),
                                    child: DynamicDeckButton(
                                      button: pl.button,
                                      liveKeys: false,
                                      onTap: () {},
                                      onLongPress: () {},
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppleSpacing.xs),
        Text(
          '${profile.name} · '
          '${autoGrid ? '${tr('Automático')} ($columns×$rows)' : '$columns×$rows'}'
          ' · ${spacing.label}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: type.caption1.copyWith(color: c.secondaryLabel),
        ),
      ],
    );
  }
}
