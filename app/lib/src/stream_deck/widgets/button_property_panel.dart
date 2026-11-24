import 'dart:convert';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/actions/action_catalog.dart';
import 'package:deckos/src/stream_deck/actions/action_picker.dart';
import 'package:flutter/material.dart';

import '../../ai_limits/ai_provider_style.dart';
import '../buttons/colors.dart';
import 'dynamic_deck_button.dart';
import 'editor/info_section.dart';
import 'editor/look_pickers.dart';
import 'editor/two_state_section.dart';

/// Editor de um botão: rótulo, ações (toque, toque longo, toque duplo), dois estados,
/// informação no botão, ícone e cores. A escolha de cada ação fica no [ActionPicker];
/// as seções maiores ficam em `editor/`.
class ButtonPropertyPanel extends StatefulWidget {
  final DeckButton button;
  final Function(DeckButton) onSave;
  final VoidCallback? onCancel;
  final List<DeckProfile> profiles;

  /// "Copiar ou mover…": leva o botão salvo para outro perfil. Nulo esconde a opção.
  final VoidCallback? onCopyOrMove;

  /// O botão como está no formulário, a cada mudança (o configurador mostra no espelho).
  final ValueChanged<DeckButton>? onDraftChanged;

  const ButtonPropertyPanel({
    super.key,
    required this.button,
    required this.onSave,
    this.onCancel,
    this.profiles = const [],
    this.onCopyOrMove,
    this.onDraftChanged,
  });

  @override
  State<ButtonPropertyPanel> createState() => ButtonPropertyPanelState();
}

class ButtonPropertyPanelState extends State<ButtonPropertyPanel> {
  final _catalog = ActionCatalog.instance;
  late final _labelController = TextEditingController(text: widget.button.label);

  /// Ação de cada gesto. Null = nenhuma.
  late DeckAction? _tap = widget.button.action?.type == 'none' ? null : widget.button.action;
  late DeckAction? _longPress = widget.button.longPressAction;
  late DeckAction? _doubleTap = widget.button.doubleTapAction;

  late Color _color = parseHexColor(widget.button.backgroundColor) ?? ColorRow.palette.first;
  late Color _activeColor = parseHexColor(widget.button.activeColor) ?? Colors.red[900]!;
  late String? _icon = widget.button.iconName;
  late String? _iconBase64 = widget.button.iconBase64;

  late String? _infoType = widget.button.dynamicType;
  late Map<String, String> _infoParams = Map.of(widget.button.dynamicParameters ?? const {});
  late TwoStateValue _twoState = TwoStateValue.of(widget.button);
  late int _columnSpan = widget.button.columnSpan;
  late int _rowSpan = widget.button.rowSpan;
  late String _tileShape = const {'squircle', 'rounded', 'square'}.contains(widget.button.tileShape) ? widget.button.tileShape! : '';

  /// Ações que refletem um estado ligado/desligado (e portanto têm "cor de ativo").
  bool get _isStatefulAction => _catalog.find(_tap?.type)?.stateful ?? false;

  bool get _showsActive => _isStatefulAction || _twoState.toggle;

  /// No navegador o painel roda no configurador (localhost); fora dele, no celular.
  bool get _remote => !WebMode.configurator;

  @override
  void initState() {
    super.initState();
    // A prévia no topo acompanha o rótulo enquanto se digita.
    _labelController.addListener(() {
      if (mounted) setState(() {});
    });
    _catalog.load();
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _initialJson = jsonEncode(_compose().toJson());
    });
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  /// Id de um botão novo (fixo: o retrato de "não salvo" compara o botão inteiro).
  late final String _newId = DateTime.now().millisecondsSinceEpoch.toString();

  /// O botão como está no formulário agora.
  DeckButton _compose() {
    final hasInfo = _infoType != null && _infoType!.isNotEmpty;
    final activeLabel = _twoState.activeLabel.trim();
    return DeckButton(
      id: widget.button.id.isEmpty ? _newId : widget.button.id,
      row: widget.button.row,
      column: widget.button.column,
      label: _labelController.text,
      backgroundColor: colorToHex(_color),
      tileShape: _tileShape.isEmpty ? null : _tileShape,
      activeColor: _showsActive ? colorToHex(_activeColor) : null,
      iconName: _icon,
      iconBase64: _iconBase64,
      dynamicType: _infoType,
      dynamicParameters: hasInfo && _infoParams.isNotEmpty ? Map.of(_infoParams) : null,
      action: _tap,
      longPressAction: _longPress,
      doubleTapAction: _doubleTap,
      toggle: _twoState.toggle,
      activeAction: _twoState.toggle ? _twoState.activeAction : null,
      activeLabel: _showsActive && activeLabel.isNotEmpty ? activeLabel : null,
      activeIconName: _showsActive ? _twoState.activeIcon : null,
      activeIconBase64: _showsActive ? _twoState.activeIconBase64 : null,
      columnSpan: _columnSpan,
      rowSpan: _rowSpan,
    );
  }

  void _save() {
    final b = _compose();
    // O painel continua aberto depois de salvar: o retrato passa a ser o salvo, senão
    // fechar ou trocar de botão perguntava "Descartar as alterações?" do que já foi salvo.
    _initialJson = jsonEncode(b.toJson());
    widget.onSave(b);
  }

  /// Retrato do formulário logo depois de abrir (os editores de ação ajustam os próprios
  /// parâmetros no primeiro frame; por isso a espera curta).
  String? _initialJson;

  /// Há mudanças não salvas?
  bool get isDirty =>
      _initialJson != null && jsonEncode(_compose().toJson()) != _initialJson;

  void _delete() {
    widget.onSave(DeckButton(
      id: '',
      row: widget.button.row,
      column: widget.button.column,
      label: '',
      backgroundColor: '',
    ));
  }

  /// Preenche o rótulo com a sugestão da ação, se ele estiver vazio ou no padrão.
  void _suggestLabel(String label) {
    final current = _labelController.text.trim();
    if (current.isEmpty ||
        current == tr('Novo botão') ||
        current == 'Novo botão' ||
        current == 'New Button') {
      _labelController.text = label;
    }
  }

  void _suggestIcon(String base64) => setState(() {
        _iconBase64 = base64;
        _icon = null;
      });

  Future<void> _pickImage() async {
    final String? image;
    try {
      image = await pickButtonImage();
    } on FormatException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
      }
      return;
    }
    if (image != null) _suggestIcon(image);
  }

  ActionPicker _picker(String label, DeckAction? initial, ValueChanged<DeckAction?> onChanged) =>
      ActionPicker(
        label: label,
        initial: initial,
        onChanged: onChanged,
        remote: _remote,
        profiles: widget.profiles,
        suggestLabel: _suggestLabel,
        suggestIcon: _suggestIcon,
      );

  String? _lastDraft;

  /// Avisa quem está de fora (o espelho) quando o formulário muda.
  void _emitDraft(DeckButton b) {
    final cb = widget.onDraftChanged;
    if (cb == null) return;
    final json = jsonEncode(b.toJson());
    if (json == _lastDraft) return;
    final first = _lastDraft == null;
    _lastDraft = json;
    if (first) return; // ao abrir, o espelho já mostra o salvo
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) cb(b);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Watch: o catálogo do PC chega depois do primeiro build e pode mudar os campos.
    return Watch((context) {
      _catalog.schemas.value;
      final c = AppleColors.of(context);
      final draft = _compose();
      _emitDraft(draft);
      Widget pad(Widget child) => Padding(
            padding: const EdgeInsets.fromLTRB(AppleSpacing.md, 0, AppleSpacing.md, AppleSpacing.md),
            child: child,
          );
      const margin = EdgeInsets.fromLTRB(AppleSpacing.md, 0, AppleSpacing.md, AppleSpacing.lg);
      return Column(
        children: [
          _buildHeader(draft),
          Container(height: 0.5, color: c.separator),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(top: AppleSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  InsetGroupedSection(
                    header: tr('Rótulo'),
                    margin: margin,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.md, vertical: 2),
                        child: TextField(
                          controller: _labelController,
                          style: AppleTextStyles.of(context).body.copyWith(color: c.label),
                          decoration: InputDecoration(
                            hintText: tr('Sem rótulo'),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            filled: false,
                          ),
                        ),
                      ),
                    ],
                  ),
                  InsetGroupedSection(
                    header: tr('Ação'),
                    margin: margin,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(AppleSpacing.sm),
                        child: _picker(tr('Ação'), _tap, (a) => setState(() => _tap = a)),
                      ),
                    ],
                  ),
                  pad(_buildGestures()),
                  pad(TwoStateSection(
                    value: _twoState,
                    statefulAction: _isStatefulAction,
                    actionPicker: _picker,
                    onChanged: (v) => setState(() => _twoState = v),
                  )),
                  pad(InfoSection(
                    type: _infoType,
                    params: _infoParams,
                    savedType: widget.button.dynamicType,
                    remote: _remote,
                    onChanged: (type, params) => setState(() {
                      // New AI Limits tiles default to a readable 2×1 span; existing
                      // tiles always keep their saved span untouched.
                      if (widget.button.id.isEmpty &&
                          type == aiLimitsDynamicType &&
                          _infoType != aiLimitsDynamicType &&
                          _columnSpan == 1) {
                        _columnSpan = 2;
                      }
                      _infoType = type;
                      _infoParams = params;
                    }),
                  )),
                  const SizedBox(height: AppleSpacing.xs),
                  ..._buildLook(margin),
                ],
              ),
            ),
          ),
          _buildActionBar(),
        ],
      );
    });
  }

  /// Prévia da tecla (como o celular desenha) com o título e a ação.
  Widget _buildHeader(DeckButton draft) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final action = _catalog.find(_tap?.type)?.title;
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppleSpacing.md, AppleSpacing.md, AppleSpacing.xs, AppleSpacing.md),
      child: Row(
        children: [
          Container(
            width: 84,
            height: 84,
            padding: const EdgeInsets.all(AppleSpacing.xs),
            decoration: ShapeDecoration(
              color: DeckTheme.of(context).background,
              shape: AppleShapes.squircle(AppleRadii.lg),
            ),
            child: IgnorePointer(
              child: DynamicDeckButton(button: draft, onTap: () {}, onLongPress: () {}),
            ),
          ),
          const SizedBox(width: AppleSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.button.id.isEmpty ? tr('Novo botão') : tr('Editar botão'),
                  style: type.title3.copyWith(color: c.label),
                ),
                const SizedBox(height: 2),
                Text(
                  action ?? tr('Sem ação'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.subheadline.copyWith(color: c.secondaryLabel),
                ),
                Text(
                  tr('Linha {row}, coluna {col}', {'row': widget.button.row + 1, 'col': widget.button.column + 1}),
                  style: type.caption1.copyWith(color: c.tertiaryLabel),
                ),
              ],
            ),
          ),
          if (widget.onCancel != null)
            IconButton(
              tooltip: tr('Fechar'),
              visualDensity: VisualDensity.compact,
              onPressed: widget.onCancel,
              icon: Icon(Icons.close_rounded, size: 20, color: c.secondaryLabel),
            ),
        ],
      ),
    );
  }

  /// Toque longo e toque duplo, recolhidos quando não usados.
  Widget _buildGestures() {
    final used = _longPress != null || _doubleTap != null;
    String title(DeckAction a) => _catalog.find(a.type)?.title ?? a.type;
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        initiallyExpanded: used,
        shape: const Border(),
        leading: ListRowIcon(Icons.touch_app_rounded, color: AppleColors.of(context).orange),
        title: Text(tr('Toque longo e toque duplo')),
        subtitle: Text(
          used
              ? [
                  if (_longPress != null) tr('Longo: {action}', {'action': title(_longPress!)}),
                  if (_doubleTap != null) tr('Duplo: {action}', {'action': title(_doubleTap!)}),
                ].join(' · ')
              : tr('Opcional'),
          style: const TextStyle(fontSize: 12),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        children: [
          Text(
            _remote
                ? tr('Com um toque longo definido, segure o botão para executá-lo. Para '
                    'editar o botão depois, use o lápis (modo de edição) na barra do deck.')
                : tr('Com um toque longo definido, segurar o botão no celular executa a '
                    'ação; o celular edita pelo modo de edição (lápis na barra do deck).'),
            style: TextStyle(fontSize: 12, color: AppleColors.of(context).secondaryLabel),
          ),
          const SizedBox(height: 12),
          _picker(tr('Toque longo'), _longPress, (a) => setState(() => _longPress = a)),
          const SizedBox(height: 20),
          _picker(tr('Toque duplo'), _doubleTap, (a) => setState(() => _doubleTap = a)),
        ],
      ),
    );
  }

  /// Tamanho, ícone e cores.
  List<Widget> _buildLook(EdgeInsets margin) {
    final c = AppleColors.of(context);
    Widget stepper(int value, ValueChanged<int> onChanged) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              visualDensity: VisualDensity.compact,
              onPressed: value > 1 ? () => setState(() => onChanged(value - 1)) : null,
              icon: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: value > 1 ? c.tertiaryFill : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppleRadii.xs),
                  border: Border.all(
                    color: value > 1 ? c.separator : c.separator.withValues(alpha: 0.4),
                    width: 1,
                  ),
                ),
                child: Icon(
                  Icons.remove_rounded,
                  size: 16,
                  color: value > 1 ? c.label : c.quaternaryLabel,
                ),
              ),
            ),
            SizedBox(
              width: 28,
              child: Text('$value',
                  textAlign: TextAlign.center,
                  style: AppleTextStyles.of(context).body.copyWith(color: c.label)),
            ),
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              visualDensity: VisualDensity.compact,
              onPressed: value < 4 ? () => setState(() => onChanged(value + 1)) : null,
              icon: Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: value < 4 ? c.tertiaryFill : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppleRadii.xs),
                  border: Border.all(
                    color: value < 4 ? c.separator : c.separator.withValues(alpha: 0.4),
                    width: 1,
                  ),
                ),
                child: Icon(
                  Icons.add_rounded,
                  size: 16,
                  color: value < 4 ? c.label : c.quaternaryLabel,
                ),
              ),
            ),
          ],
        );
    return [
      InsetGroupedSection(
        header: tr('Forma do cartão'),
        footer: tr('Altera somente este cartão. O tamanho e os gestos continuam iguais.'),
        margin: margin,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: DropdownButtonFormField<String>(
              key: ValueKey('tile-shape-$_tileShape'),
              initialValue: _tileShape,
              decoration: InputDecoration(labelText: tr('Forma')),
              items: [
                for (final entry in {'': 'Usar tema global', 'squircle': 'Squircle', 'rounded': 'Arredondado', 'square': 'Quadrado'}.entries)
                  DropdownMenuItem(value: entry.key, child: Text(tr(entry.value))),
              ],
              onChanged: (value) => setState(() => _tileShape = value ?? ''),
            ),
          ),
        ],
      ),
      InsetGroupedSection(
        header: tr('Tamanho'),
        footer: tr('Um botão grande não cobre outros botões: ele para onde houver um.'),
        margin: margin,
        children: [
          ListRow(
            leading: ListRowIcon(Icons.swap_horiz_rounded, color: c.blue),
            title: tr('Largura (casas)'),
            trailing: stepper(_columnSpan, (v) => _columnSpan = v),
          ),
          ListRow(
            leading: ListRowIcon(Icons.swap_vert_rounded, color: c.blue),
            title: tr('Altura (casas)'),
            trailing: stepper(_rowSpan, (v) => _rowSpan = v),
          ),
        ],
      ),
      InsetGroupedSection(
        header: tr('Ícone'),
        margin: margin,
        children: [
          ListRow(
            leading: ListRowIcon(Icons.image_outlined, color: c.purple),
            title: tr('Imagem própria'),
            onTap: _pickImage,
          ),
          if (_iconBase64 != null)
            Padding(
              padding: const EdgeInsets.only(top: AppleSpacing.sm),
              child: ImagePreview(base64: _iconBase64!, onRemove: () => setState(() => _iconBase64 = null)),
            ),
          SizedBox(
            height: 220,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppleSpacing.sm),
              child: IconGrid(
                selected: _icon,
                spacing: 8,
                onSelect: (name) => setState(() {
                  _icon = name;
                  if (name != null) _iconBase64 = null;
                }),
              ),
            ),
          ),
        ],
      ),
      InsetGroupedSection(
        header: tr('Cor de fundo'),
        margin: margin,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppleSpacing.md),
            child: ColorRow(selected: _color, onSelect: (c) => setState(() => _color = c)),
          ),
        ],
      ),
      // Cor de "ativo": ações que refletem estado e botões de dois estados.
      if (_showsActive)
        InsetGroupedSection(
          header: switch (_tap?.type) {
            'discord' => tr('Cor quando ativo (mutado/ensurdecido)'),
            'timer' => tr('Cor quando a contagem termina'),
            'windows' => tr('Cor quando o dispositivo é o padrão'),
            _ => tr('Cor quando ativo'),
          },
          margin: margin,
          children: [
            Padding(
              padding: const EdgeInsets.all(AppleSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ColorRow(selected: _activeColor, onSelect: (c) => setState(() => _activeColor = c)),
                  const SizedBox(height: 12),
                  ActivePreview(
                    color: _color,
                    activeColor: _activeColor,
                    icons: ActivePreview.iconsFor(_tap),
                  ),
                ],
              ),
            ),
          ],
        ),
    ];
  }

  Widget _buildActionBar() {
    final c = AppleColors.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(AppleSpacing.md, AppleSpacing.sm, AppleSpacing.md, AppleSpacing.sm),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: c.separator, width: 1))),
      child: Row(
        children: [
          if (widget.button.id.isNotEmpty)
            IconButton(
              tooltip: tr('Limpar botão'),
              visualDensity: VisualDensity.compact,
              onPressed: _delete,
              icon: Icon(Icons.delete_outline_rounded, color: c.red, size: 20),
            ),
          // Copia o que está salvo: com mudanças pendentes, salve antes.
          if (widget.onCopyOrMove != null && widget.button.id.isNotEmpty)
            IconButton(
              tooltip: tr('Copiar ou mover…'),
              visualDensity: VisualDensity.compact,
              onPressed: widget.onCopyOrMove,
              icon: Icon(Icons.drive_file_move_outlined, color: c.accent, size: 20),
            ),
          const Spacer(),
          if (widget.onCancel != null)
            SecondaryButton(label: tr('Cancelar'), compact: true, onPressed: widget.onCancel),
          const SizedBox(width: AppleSpacing.xs),
          PrimaryButton(label: tr('Salvar'), compact: true, onPressed: _save),
        ],
      ),
    );
  }
}
