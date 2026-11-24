import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/layout/grid_placement.dart';
import 'package:deckos/src/stream_deck/layout/slot_ops.dart';
import 'package:deckos/src/stream_deck/widgets/dynamic_deck_button.dart';
import 'package:flutter/material.dart';

/// Escopo da alteração de grade no painel de layout.
enum DeckGridScope { allPages, thisPage }

/// Resultado confirmado pelo painel de layout da grade.
/// Cancelar ou fechar sem salvar devolve null (nada é salvo parcialmente).
@immutable
class DeckLayoutResult {
  const DeckLayoutResult({
    this.scope = DeckGridScope.allPages,
    required this.autoGrid,
    required this.rows,
    required this.columns,
    required this.spacing,
    required this.iconSize,
    required this.showLabels,
    this.resetPageGrid = false,
    this.updatedButtons,
  });

  /// Se a grade alterada vale para todas as páginas (global) ou apenas para esta página.
  final DeckGridScope scope;

  /// Quando verdadeiro (no celular, no escopo global), a grade acompanha o tamanho da tela.
  final bool autoGrid;
  final int rows;
  final int columns;
  final DeckSpacing spacing;
  final DeckIconSize iconSize;
  final bool showLabels;

  /// Quando verdadeiro em [DeckGridScope.thisPage], limpa a grade própria desta página
  /// para voltar a herdar a grade global.
  final bool resetPageGrid;

  /// Lista reorganizada de botões quando o usuário confirmou ajustar posições para caber
  /// numa grade menor desta página sem perder nenhum botão.
  final List<DeckButton>? updatedButtons;
}

/// Folha de personalização do layout do deck (grade desta página ou global + aparência local).
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
    this.initialScope = DeckGridScope.allPages,
    this.initialPageGrid,
    this.allowPageScope = true,
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

  /// Escopo inicial selecionado ao abrir o painel.
  final DeckGridScope initialScope;

  /// Grade própria atualmente salva nesta página (nula = herdando a grade global).
  final ({int rows, int columns})? initialPageGrid;

  /// Exibe o seletor "Esta página" / "Todas as páginas".
  final bool allowPageScope;

  static const _globalPresets = <({int cols, int rows})>[
    (cols: 3, rows: 2),
    (cols: 4, rows: 2),
    (cols: 4, rows: 3),
    (cols: 5, rows: 3),
    (cols: 6, rows: 3),
  ];

  static const _pagePresets = <({int cols, int rows})>[
    (cols: 2, rows: 2),
    (cols: 2, rows: 4),
    (cols: 3, rows: 2),
    (cols: 4, rows: 2),
    (cols: 4, rows: 3),
    (cols: 5, rows: 3),
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
    DeckGridScope initialScope = DeckGridScope.allPages,
    ({int rows, int columns})? initialPageGrid,
    bool allowPageScope = true,
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
        initialScope: initialScope,
        initialPageGrid: initialPageGrid,
        allowPageScope: allowPageScope,
      ),
    );
  }

  @override
  State<DeckLayoutSheet> createState() => _DeckLayoutSheetState();
}

class _DeckLayoutSheetState extends State<DeckLayoutSheet> {
  late final ({int rows, int columns}) _pageMin =
      SlotOps.minGrid(widget.profile.buttons);

  late DeckGridScope _scope =
      widget.allowPageScope ? widget.initialScope : DeckGridScope.allPages;

  // Global grid state
  late bool _autoGrid = widget.allowAutoGrid && widget.initialAutoGrid;
  late int _globalRows =
      math.max(widget.initialRows, _pageMin.rows).clamp(1, 10);
  late int _globalCols =
      math.max(widget.initialColumns, _pageMin.columns).clamp(1, 10);

  // Per-page grid override state
  late bool _pageInheritsGlobal = widget.initialPageGrid == null;
  late int _pageRows =
      (widget.initialPageGrid?.rows ?? widget.initialRows).clamp(1, 10);
  late int _pageCols =
      (widget.initialPageGrid?.columns ?? widget.initialColumns).clamp(1, 10);

  // Device-local appearance state
  late DeckSpacing _spacing = widget.initialSettings.spacing;
  late DeckIconSize _iconSize = widget.initialSettings.iconSize;
  late bool _showLabels = widget.initialSettings.effectiveShowLabels;

  int get _effectiveGlobalRows =>
      math.max(_autoGrid ? widget.autoRows : _globalRows, _pageMin.rows)
          .clamp(1, 10);

  int get _effectiveGlobalCols =>
      math.max(_autoGrid ? widget.autoColumns : _globalCols, _pageMin.columns)
          .clamp(1, 10);

  int get _previewRows => _scope == DeckGridScope.thisPage
      ? (_pageInheritsGlobal ? _effectiveGlobalRows : _pageRows)
      : _effectiveGlobalRows;

  int get _previewCols => _scope == DeckGridScope.thisPage
      ? (_pageInheritsGlobal ? _effectiveGlobalCols : _pageCols)
      : _effectiveGlobalCols;

  GridFitPlan get _pageFitPlan => SlotOps.planGridFit(
        widget.profile.buttons,
        rows: _pageRows,
        columns: _pageCols,
      );

  /// Alguma outra página tem botões além da grade global escolhida? (Ela expande sozinha sem perder nada.)
  bool get _otherPagesLarger {
    for (final p in widget.allProfiles) {
      if (p.id == widget.profile.id) continue;
      if (p.hasCustomGrid) continue;
      final min = SlotOps.minGrid(p.buttons);
      if (min.columns > _effectiveGlobalCols || min.rows > _effectiveGlobalRows) {
        return true;
      }
    }
    return false;
  }

  void _selectGlobalPreset(int cols, int rows) {
    if (cols < _pageMin.columns || rows < _pageMin.rows) return;
    setState(() {
      _autoGrid = false;
      _globalCols = cols;
      _globalRows = rows;
    });
  }

  void _selectAuto() {
    setState(() {
      _autoGrid = true;
      _globalCols = math.max(widget.autoColumns, _pageMin.columns).clamp(1, 10);
      _globalRows = math.max(widget.autoRows, _pageMin.rows).clamp(1, 10);
    });
  }

  void _selectPagePreset(int cols, int rows) {
    setState(() {
      _pageInheritsGlobal = false;
      _pageCols = cols.clamp(1, 10);
      _pageRows = rows.clamp(1, 10);
    });
  }

  void _resetPageToGlobal() {
    setState(() {
      _pageInheritsGlobal = true;
      _pageCols = widget.initialColumns.clamp(1, 10);
      _pageRows = widget.initialRows.clamp(1, 10);
    });
  }

  void _resetDefaults() {
    setState(() {
      if (_scope == DeckGridScope.thisPage) {
        _pageInheritsGlobal = true;
        _pageCols = widget.initialColumns.clamp(1, 10);
        _pageRows = widget.initialRows.clamp(1, 10);
      } else {
        _autoGrid = widget.allowAutoGrid;
        _globalCols =
            math.max(widget.autoColumns, _pageMin.columns).clamp(1, 10);
        _globalRows = math.max(widget.autoRows, _pageMin.rows).clamp(1, 10);
      }
      _spacing = DeckSpacing.balanced;
      _iconSize = DeckIconSize.medium;
      _showLabels =
          widget.initialSettings.effectiveTileStyle != DeckTileStyle.squircle;
    });
  }

  Future<void> _save() async {
    if (_scope == DeckGridScope.allPages) {
      Navigator.of(context).pop(DeckLayoutResult(
        scope: DeckGridScope.allPages,
        autoGrid: _autoGrid,
        rows: _effectiveGlobalRows,
        columns: _effectiveGlobalCols,
        spacing: _spacing,
        iconSize: _iconSize,
        showLabels: _showLabels,
      ));
      return;
    }

    // Per-page scope: either reset/inherit global or save an explicit override.
    if (_pageInheritsGlobal) {
      Navigator.of(context).pop(DeckLayoutResult(
        scope: DeckGridScope.thisPage,
        autoGrid: false,
        rows: _effectiveGlobalRows,
        columns: _effectiveGlobalCols,
        spacing: _spacing,
        iconSize: _iconSize,
        showLabels: _showLabels,
        resetPageGrid: true,
      ));
      return;
    }

    final plan = _pageFitPlan;
    if (plan.fitsAsIs) {
      Navigator.of(context).pop(DeckLayoutResult(
        scope: DeckGridScope.thisPage,
        autoGrid: false,
        rows: _pageRows,
        columns: _pageCols,
        spacing: _spacing,
        iconSize: _iconSize,
        showLabels: _showLabels,
      ));
      return;
    }

    // Non-destructive actionable choice whenever existing buttons sit outside the requested grid.
    final minSafeCols = math.max(_pageCols, _pageMin.columns).clamp(1, 10);
    final minSafeRows = math.max(_pageRows, _pageMin.rows).clamp(1, 10);
    final choice = await showAppleDialog<String>(
      context: context,
      title: plan.needsExpand
          ? tr('Os botões não cabem em {cols}×{rows}', {
              'cols': _pageCols,
              'rows': _pageRows,
            })
          : tr('Reorganizar botões para {cols}×{rows}?', {
              'cols': _pageCols,
              'rows': _pageRows,
            }),
      message: plan.needsExpand
          ? tr(
              'Esta página tem {n} botões. Nenhum botão, rótulo ou conta será apagado. Escolha como ajustar:',
              {'n': widget.profile.buttons.length},
            )
          : tr(
              'Alguns botões estão fora de {cols}×{rows}. Reorganizar mantém todos os botões, ações e contas vinculadas.',
              {'cols': _pageCols, 'rows': _pageRows},
            ),
      actions: [
        AppleDialogAction(
          label: plan.needsExpand
              ? tr('Reorganizar e expandir ({cols}×{rows})', {
                  'cols': plan.requiredColumns,
                  'rows': plan.requiredRows,
                })
              : tr('Reorganizar e salvar'),
          value: 'reflow',
          isDefault: true,
        ),
        AppleDialogAction(
          label: tr('Manter tamanho mínimo ({cols}×{rows})', {
            'cols': minSafeCols,
            'rows': minSafeRows,
          }),
          value: 'keep_min',
        ),
        AppleDialogAction(label: tr('Cancelar'), value: 'cancel'),
      ],
    );
    if (!mounted || choice == null || choice == 'cancel') return;

    if (choice == 'reflow') {
      Navigator.of(context).pop(DeckLayoutResult(
        scope: DeckGridScope.thisPage,
        autoGrid: false,
        rows: plan.requiredRows.clamp(1, 20),
        columns: plan.requiredColumns.clamp(1, 20),
        spacing: _spacing,
        iconSize: _iconSize,
        showLabels: _showLabels,
        updatedButtons: plan.buttons,
      ));
      return;
    }

    if (choice == 'keep_min') {
      Navigator.of(context).pop(DeckLayoutResult(
        scope: DeckGridScope.thisPage,
        autoGrid: false,
        rows: minSafeRows,
        columns: minSafeCols,
        spacing: _spacing,
        iconSize: _iconSize,
        showLabels: _showLabels,
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final isThisPage = _scope == DeckGridScope.thisPage;
    final constrainedByPage = !isThisPage &&
        widget.profile.buttons.isNotEmpty &&
        (_pageMin.columns > 1 || _pageMin.rows > 1);
    final plan = isThisPage && !_pageInheritsGlobal ? _pageFitPlan : null;

    final previewProfile = (plan != null && plan.needsRearrange)
        ? widget.profile.copyWith(buttons: plan.buttons)
        : widget.profile;
    final previewRows = (plan != null && plan.needsExpand)
        ? plan.requiredRows
        : _previewRows;
    final previewCols = (plan != null && plan.needsExpand)
        ? plan.requiredColumns
        : _previewCols;

    final scopeCaption = isThisPage
        ? (_pageInheritsGlobal
            ? tr('Global ({cols}×{rows})', {
                'cols': _effectiveGlobalCols,
                'rows': _effectiveGlobalRows,
              })
            : tr('Só esta página ({cols}×{rows})', {
                'cols': previewCols,
                'rows': previewRows,
              }))
        : (_autoGrid
            ? '${tr('Automático')} ($previewCols×$previewRows)'
            : '$previewCols×$previewRows');

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.88,
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
                    isThisPage
                        ? tr('Grade desta página')
                        : tr('Layout da grade'),
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
                      AppleSpacing.md,
                    ),
                    child: _LiveLayoutPreview(
                      profile: previewProfile,
                      rows: previewRows,
                      columns: previewCols,
                      spacing: _spacing,
                      iconSize: _iconSize,
                      showLabels: _showLabels,
                      caption:
                          '${widget.profile.name} · $scopeCaption · ${_spacing.label}',
                    ),
                  ),

                  if (widget.allowPageScope)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppleSpacing.screen,
                        0,
                        AppleSpacing.screen,
                        AppleSpacing.md,
                      ),
                      child: SegmentedControl<DeckGridScope>(
                        key: const ValueKey('deck-grid-scope-toggle'),
                        segments: {
                          DeckGridScope.thisPage: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Text(
                              tr('Esta página'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          DeckGridScope.allPages: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Text(
                              tr('Todas as páginas'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        },
                        value: _scope,
                        onChanged: (v) => setState(() => _scope = v),
                      ),
                    ),

                  // ---- Grade desta página OU Grade global ----
                  if (isThisPage)
                    InsetGroupedSection(
                      header: tr('Grade de "{name}"', {'name': widget.profile.name}),
                      footer: _pageInheritsGlobal
                          ? tr(
                              'Esta página usa a grade global ({cols}×{rows}). Ajustar aqui altera apenas esta página e não muda as outras.',
                              {
                                'cols': _effectiveGlobalCols,
                                'rows': _effectiveGlobalRows,
                              },
                            )
                          : tr(
                              'Salvo apenas para "{name}". Outras páginas continuam usando a grade global.',
                              {'name': widget.profile.name},
                            ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(AppleSpacing.md),
                          child: Wrap(
                            spacing: AppleSpacing.xs,
                            runSpacing: AppleSpacing.xs,
                            children: [
                              _PresetChip(
                                key: const ValueKey('page-grid-inherit-chip'),
                                label: tr('Global ({cols}×{rows})', {
                                  'cols': _effectiveGlobalCols,
                                  'rows': _effectiveGlobalRows,
                                }),
                                selected: _pageInheritsGlobal,
                                enabled: true,
                                onTap: _resetPageToGlobal,
                              ),
                              for (final p in DeckLayoutSheet._pagePresets)
                                _PresetChip(
                                  label: '${p.cols}×${p.rows}',
                                  selected: !_pageInheritsGlobal &&
                                      _pageCols == p.cols &&
                                      _pageRows == p.rows,
                                  enabled: true,
                                  onTap: () => _selectPagePreset(p.cols, p.rows),
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
                            key: const ValueKey('page-grid-cols-stepper'),
                            value: _pageInheritsGlobal
                                ? _effectiveGlobalCols
                                : _pageCols,
                            min: 1,
                            max: 10,
                            onChanged: (v) => setState(() {
                              if (_pageInheritsGlobal) {
                                _pageRows = _effectiveGlobalRows;
                              }
                              _pageInheritsGlobal = false;
                              _pageCols = v;
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
                            key: const ValueKey('page-grid-rows-stepper'),
                            value: _pageInheritsGlobal
                                ? _effectiveGlobalRows
                                : _pageRows,
                            min: 1,
                            max: 10,
                            onChanged: (v) => setState(() {
                              if (_pageInheritsGlobal) {
                                _pageCols = _effectiveGlobalCols;
                              }
                              _pageInheritsGlobal = false;
                              _pageRows = v;
                            }),
                          ),
                        ),
                        if (plan != null && plan.needsRearrange)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(
                              AppleSpacing.md,
                              AppleSpacing.xs,
                              AppleSpacing.md,
                              AppleSpacing.md,
                            ),
                            child: Container(
                              key: const ValueKey('page-grid-fit-notice'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: c.orange
                                    .withValues(alpha: c.isDark ? 0.16 : 0.10),
                                borderRadius:
                                    BorderRadius.circular(AppleRadii.sm),
                                border: Border.all(
                                  color: c.orange
                                      .withValues(alpha: c.isDark ? 0.34 : 0.24),
                                ),
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    Icons.info_outline_rounded,
                                    size: 16,
                                    color: c.orange,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      plan.needsExpand
                                          ? tr(
                                              'Todos os {n} botões precisam de pelo menos {cols}×{rows}. Ao salvar você escolhe reorganizar e expandir sem perder nenhum.',
                                              {
                                                'n': widget.profile.buttons.length,
                                                'cols': plan.requiredColumns,
                                                'rows': plan.requiredRows,
                                              },
                                            )
                                          : tr(
                                              'Os botões serão reorganizados para caber em {cols}×{rows} sem apagar nenhum.',
                                              {
                                                'cols': _pageCols,
                                                'rows': _pageRows,
                                              },
                                            ),
                                      style: type.caption1
                                          .copyWith(color: c.label),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (!_pageInheritsGlobal ||
                            widget.initialPageGrid != null)
                          ListRow(
                            key: const ValueKey('page-grid-reset-row'),
                            leading: ListRowIcon(
                              Icons.settings_backup_restore_rounded,
                              color: c.orange,
                            ),
                            title: tr('Usar grade global'),
                            subtitle: tr('Remove o ajuste próprio e volta para {cols}×{rows}', {
                              'cols': _effectiveGlobalCols,
                              'rows': _effectiveGlobalRows,
                            }),
                            trailing: _pageInheritsGlobal
                                ? Icon(Icons.check_rounded,
                                    size: 18, color: c.accent)
                                : null,
                            onTap: _resetPageToGlobal,
                          ),
                      ],
                    )
                  else
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
                          child: Wrap(
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
                              for (final p in DeckLayoutSheet._globalPresets)
                                _PresetChip(
                                  label: '${p.cols}×${p.rows}',
                                  selected: !_autoGrid &&
                                      _effectiveGlobalCols == p.cols &&
                                      _effectiveGlobalRows == p.rows,
                                  enabled: p.cols >= _pageMin.columns &&
                                      p.rows >= _pageMin.rows,
                                  onTap: () =>
                                      _selectGlobalPreset(p.cols, p.rows),
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
                            value: _effectiveGlobalCols,
                            min: _pageMin.columns,
                            max: 10,
                            onChanged: (v) => setState(() {
                              _autoGrid = false;
                              _globalCols = v;
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
                            value: _effectiveGlobalRows,
                            min: _pageMin.rows,
                            max: 10,
                            onChanged: (v) => setState(() {
                              _autoGrid = false;
                              _globalRows = v;
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
    super.key,
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
    super.key,
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
    Widget stepBtn(IconData icon, VoidCallback? onTap, Key btnKey) => IconButton(
          key: btnKey,
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
                color: onTap != null
                    ? c.separator
                    : c.separator.withValues(alpha: 0.4),
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
        stepBtn(
          Icons.remove_rounded,
          value > min ? () => onChanged(value - 1) : null,
          const ValueKey('stepper-dec'),
        ),
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
        stepBtn(
          Icons.add_rounded,
          value < max ? () => onChanged(value + 1) : null,
          const ValueKey('stepper-inc'),
        ),
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
    required this.caption,
  });

  final DeckProfile profile;
  final int rows;
  final int columns;
  final DeckSpacing spacing;
  final DeckIconSize iconSize;
  final bool showLabels;
  final String caption;

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
    final isLandscapePreview = columns >= rows;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: isLandscapePreview ? 360 : 190,
              maxHeight: isLandscapePreview ? 190 : 210,
            ),
            child: Theme(
              data: baseTheme.copyWith(
                extensions: [
                  ...baseTheme.extensions.values.where((e) => e is! DeckTheme),
                  deck,
                ],
              ),
              child: PhoneFrame(
                landscape: isLandscapePreview,
                screenColor: deck.background,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    (isLandscapePreview ? 26 : 10) * spacing.marginScale,
                    (isLandscapePreview ? 10 : 18) * spacing.marginScale,
                    (isLandscapePreview ? 14 : 10) * spacing.marginScale,
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
          caption,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: type.caption1.copyWith(color: c.secondaryLabel),
        ),
      ],
    );
  }
}
