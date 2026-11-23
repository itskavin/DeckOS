import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Peças das telas de configuração (Ajustes, Integrações, Automações): tela com título
/// grande, linhas de formulário, passo a passo numerado e cabeçalho de integração.

/// Tela de configurações moderna: título grande no topo que passa para a barra ao rolar.
/// Em tela larga o conteúdo fica centralizado em [maxWidth].
class SettingsScaffold extends StatefulWidget {
  const SettingsScaffold({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.actions,
    this.maxWidth = 680,
    this.bottom,
    this.backgroundColor,
    this.largeTitle = true,
  });

  final String title;

  /// Sem título grande: o nome fica sempre na barra (telas de detalhe, com cabeçalho próprio).
  final bool largeTitle;
  final String? subtitle;
  final List<Widget> children;
  final List<Widget>? actions;
  final double maxWidth;

  /// Fica preso embaixo da tela (ex.: botão "Nova automação").
  final Widget? bottom;
  final Color? backgroundColor;

  @override
  State<SettingsScaffold> createState() => _SettingsScaffoldState();
}

class _SettingsScaffoldState extends State<SettingsScaffold> {
  final _scroll = ScrollController();
  bool _collapsed = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      final collapsed =
          _scroll.hasClients && _scroll.offset > (widget.largeTitle ? 36 : 4);
      if (collapsed != _collapsed) setState(() => _collapsed = collapsed);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final bg = widget.backgroundColor ?? c.groupedBackground;
    final fade = AppleMotion.of(context, AppleMotion.fast);
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: _collapsed
            ? Color.alphaBlend(c.barBackground, bg)
            : bg,
        shape: Border(
          bottom: BorderSide(
            color: _collapsed ? c.separator : Colors.transparent,
            width: 1,
          ),
        ),
        title: AnimatedOpacity(
          opacity: _collapsed || !widget.largeTitle ? 1 : 0,
          duration: fade,
          child: Text(widget.title),
        ),
        leading: Navigator.of(context).canPop()
            ? IconButton(
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                icon: const Icon(Icons.arrow_back_rounded, size: 22),
                onPressed: () => Navigator.of(context).maybePop(),
              )
            : null,
        actions: widget.actions,
      ),
      body: LayoutBuilder(
        builder: (context, box) {
          final side = math.max(0.0, (box.maxWidth - widget.maxWidth) / 2);
          final safe = MediaQuery.paddingOf(context).bottom;
          return ListView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              side,
              0,
              side,
              AppleSpacing.xxl + safe + (widget.bottom != null ? 72 : 0),
            ),
            children: [
              if (!widget.largeTitle) const SizedBox(height: AppleSpacing.xs),
              if (widget.largeTitle)
                LargeTitleHeader(
                  title: widget.title,
                  subtitle: widget.subtitle,
                  padding: const EdgeInsets.fromLTRB(
                    AppleSpacing.screen + AppleSpacing.xxs,
                    0,
                    AppleSpacing.screen,
                    AppleSpacing.md,
                  ),
                ),
              ...widget.children,
            ],
          );
        },
      ),
      bottomNavigationBar: widget.bottom == null
          ? null
          : GlassBar(
              padding: const EdgeInsets.fromLTRB(
                AppleSpacing.screen,
                AppleSpacing.sm,
                AppleSpacing.screen,
                AppleSpacing.sm,
              ),
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: widget.maxWidth - 32),
                  child: widget.bottom!,
                ),
              ),
            ),
    );
  }
}

/// Ícone de marca em quadradinho arredondado com contraste limpo.
class BrandChip extends StatelessWidget {
  const BrandChip(this.icon, {super.key, required this.color, this.size = 29});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final radius = (size * 0.24).clamp(6.0, 18.0);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.14),
          width: 1,
        ),
      ),
      child: Icon(icon, size: size * 0.56, color: AppleColors.onColor(color)),
    );
  }
}

/// Linha de formulário do iOS: rótulo à esquerda e o campo logo depois, sem moldura.
/// [secure] mascara o texto e mostra o olho para revelar.
class FormTextRow extends StatefulWidget {
  const FormTextRow({
    super.key,
    required this.label,
    this.controller,
    this.initialValue,
    this.hint,
    this.secure = false,
    this.keyboardType,
    this.onChanged,
    this.labelWidth = 116,
    this.monospace = false,
  });

  final String label;
  final TextEditingController? controller;

  /// Só sem [controller].
  final String? initialValue;
  final String? hint;
  final bool secure;
  final TextInputType? keyboardType;
  final ValueChanged<String>? onChanged;
  final double labelWidth;
  final bool monospace;

  @override
  State<FormTextRow> createState() => _FormTextRowState();
}

class _FormTextRowState extends State<FormTextRow> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final style = type.body.copyWith(
      color: c.label,
      fontFamily: widget.monospace ? 'monospace' : null,
    );
    // Rótulo comprido ou texto grande: empilha o rótulo em cima do campo para não espremer.
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final stacked = widget.label.length > 18 || textScale > 1.25;
    final field = TextFormField(
      controller: widget.controller,
      initialValue: widget.controller == null ? widget.initialValue : null,
      obscureText: widget.secure && _obscure,
      keyboardType: widget.keyboardType,
      autocorrect: false,
      enableSuggestions: !widget.secure,
      onChanged: widget.onChanged,
      style: style,
      cursorColor: c.accent,
      decoration: InputDecoration(
        isDense: true,
        filled: false,
        hintText: widget.hint,
        hintMaxLines: 1,
        hintStyle: type.body.copyWith(color: c.tertiaryLabel),
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        contentPadding: EdgeInsets.symmetric(vertical: stacked ? 6 : 12),
      ),
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 44),
      child: Padding(
        padding: EdgeInsets.only(
          left: AppleSpacing.md,
          right: AppleSpacing.xs,
          top: stacked ? AppleSpacing.xs : 0,
          bottom: stacked ? AppleSpacing.xxs : 0,
        ),
        child: Row(
          crossAxisAlignment:
              stacked ? CrossAxisAlignment.end : CrossAxisAlignment.center,
          children: [
            if (stacked)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: type.footnote.copyWith(color: c.secondaryLabel),
                    ),
                    field,
                  ],
                ),
              )
            else ...[
              SizedBox(
                width: widget.labelWidth,
                child: Text(
                  widget.label,
                  style: type.body.copyWith(color: c.label),
                ),
              ),
              const SizedBox(width: AppleSpacing.xs),
              Expanded(child: field),
            ],
            if (widget.secure)
              IconButton(
                tooltip: _obscure ? tr('Mostrar') : tr('Ocultar'),
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: Icon(
                  _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                  color: c.secondaryLabel,
                ),
              )
            else
              const SizedBox(width: AppleSpacing.xs),
          ],
        ),
      ),
    );
  }
}

/// Um passo numerado: bolinha com o número na cor de destaque e o texto.
class NumberedStepRow extends StatelessWidget {
  const NumberedStepRow({
    super.key,
    required this.number,
    required this.text,
    this.child,
  });

  final int number;
  final String text;

  /// Algo embaixo do texto (ex.: o endereço para copiar).
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpacing.md,
        AppleSpacing.sm - 2,
        AppleSpacing.md,
        AppleSpacing.sm - 2,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: c.isDark ? 0.22 : 0.14),
              shape: BoxShape.circle,
            ),
            child: Text(
              '$number',
              style: type.footnote.copyWith(
                color: c.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: AppleSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    text,
                    style: type.subheadline.copyWith(color: c.label),
                  ),
                ),
                if (child != null) ...[
                  const SizedBox(height: AppleSpacing.xs),
                  child!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Como configurar": grupo com o passo a passo numerado, que abre e fecha.
/// Fechado por padrão quando a integração já está configurada.
class SetupStepsSection extends StatefulWidget {
  const SetupStepsSection({
    super.key,
    required this.steps,
    this.title,
    this.initiallyExpanded = true,
    this.footer,
    this.stepChildren = const {},
  });

  /// Textos já traduzidos.
  final List<String> steps;
  final String? title;
  final bool initiallyExpanded;
  final String? footer;

  /// Conteúdo extra embaixo de um passo, pelo índice (0 = primeiro).
  final Map<int, Widget> stepChildren;

  @override
  State<SetupStepsSection> createState() => _SetupStepsSectionState();
}

class _SetupStepsSectionState extends State<SetupStepsSection> {
  late bool _open = widget.initiallyExpanded;

  @override
  void didUpdateWidget(SetupStepsSection old) {
    super.didUpdateWidget(old);
    if (old.initiallyExpanded != widget.initiallyExpanded) {
      _open = widget.initiallyExpanded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    return AnimatedSize(
      duration: AppleMotion.of(context, AppleMotion.normal),
      curve: AppleMotion.smooth,
      alignment: Alignment.topCenter,
      child: InsetGroupedSection(
        footer: _open ? widget.footer : null,
        children: [
          ListRow(
            leading: ListRowIcon(Icons.format_list_numbered_rounded, color: c.indigo),
            title: widget.title ?? tr('Como configurar'),
            trailing: AnimatedRotation(
              turns: _open ? 0.25 : 0,
              duration: AppleMotion.of(context, AppleMotion.normal),
              child: Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: c.tertiaryLabel,
              ),
            ),
            onTap: () => setState(() => _open = !_open),
          ),
          if (_open)
            for (var i = 0; i < widget.steps.length; i++)
              NumberedStepRow(
                number: i + 1,
                text: widget.steps[i],
                child: widget.stepChildren[i],
              ),
        ],
      ),
    );
  }
}

/// Valor para copiar (endereço de retorno, redirect): texto em fonte fixa num campo cinza,
/// com o botão de copiar.
class CopyField extends StatelessWidget {
  const CopyField({super.key, required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        customBorder: AppleShapes.squircle(AppleRadii.sm),
        onTap: () {
          Clipboard.setData(ClipboardData(text: value));
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text(tr('Copiado.'))));
        },
        child: Ink(
          padding: const EdgeInsets.fromLTRB(
            AppleSpacing.sm,
            AppleSpacing.xs,
            AppleSpacing.xs,
            AppleSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: c.tertiaryFill,
            borderRadius: BorderRadius.circular(AppleRadii.sm),
            border: Border.all(color: c.separator, width: 1),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  value,
                  style: type.footnote.copyWith(
                    color: c.label,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Tooltip(
                message: tr('Copiar'),
                child: Padding(
                  padding: const EdgeInsets.all(AppleSpacing.xxs),
                  child: Icon(
                    Icons.content_copy_rounded,
                    size: 18,
                    color: c.accent,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Estado de uma integração no cabeçalho dela.
enum LinkState { connected, pending, configured, off, warning }

/// Topo da tela de uma integração: ícone grande da marca, nome e o estado ao vivo.
class IntegrationHero extends StatelessWidget {
  const IntegrationHero({
    super.key,
    required this.brand,
    required this.title,
    required this.state,
    required this.status,
    this.detail,
  });

  final IntegrationBrand brand;
  final String title;
  final LinkState state;

  /// Frase curta do estado ("Conectado", "Aguardando o login…").
  final String status;

  /// Linha de baixo (conta, cena atual, música tocando).
  final String? detail;

  static Color colorOf(AppleColors c, LinkState s) => switch (s) {
    LinkState.connected => c.green,
    LinkState.pending => c.orange,
    LinkState.configured => c.blue,
    LinkState.warning => c.orange,
    LinkState.off => c.gray,
  };

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final color = colorOf(c, state);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpacing.screen,
        0,
        AppleSpacing.screen,
        AppleSpacing.xl,
      ),
      child: Semantics(
        liveRegion: true,
        label: '$title. $status${detail != null ? '. $detail' : ''}',
        excludeSemantics: true,
        child: Column(
          children: [
            BrandChip(brand.icon, color: brand.color, size: 72),
            const SizedBox(height: AppleSpacing.sm),
            Text(
              title,
              style: type.title2.copyWith(color: c.label),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppleSpacing.xs),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppleSpacing.sm,
                vertical: AppleSpacing.xxs + 1,
              ),
              decoration: ShapeDecoration(
                color: color.withValues(alpha: c.isDark ? 0.18 : 0.12),
                shape: const StadiumBorder(),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StatusDot(color: color, glow: state == LinkState.connected),
                  const SizedBox(width: AppleSpacing.xs - 2),
                  Flexible(
                    child: Text(
                      status,
                      style: type.footnote.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (detail != null && detail!.isNotEmpty) ...[
              const SizedBox(height: AppleSpacing.xs),
              Text(
                detail!,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: type.footnote.copyWith(color: c.secondaryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Botões no fim de um formulário: o principal cheio e o secundário embaixo, com um
/// rodapé explicativo.
class FormActions extends StatelessWidget {
  const FormActions({super.key, required this.children, this.footer});

  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpacing.screen,
        0,
        AppleSpacing.screen,
        AppleSpacing.xl,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: AppleSpacing.sm - 2),
            children[i],
          ],
          if (footer != null) ...[
            const SizedBox(height: AppleSpacing.sm - 2),
            Text(
              footer!,
              textAlign: TextAlign.center,
              style: type.footnote.copyWith(color: c.secondaryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// Uma opção de [showChoiceSheet].
class Choice<T> {
  const Choice(this.value, this.label, {this.subtitle, this.leading});
  final T value;
  final String label;
  final String? subtitle;
  final Widget? leading;
}

/// Lista de escolha numa folha, com o visto na opção atual (como "Vibração" no Ajustes).
/// Devolve a escolhida, ou nulo se fechou.
/// Dentro de uma folha o fundo já é a cor dos grupos: aqui os grupos sobem um degrau
/// (cinza do iOS) para não sumirem.
class SheetGroups extends StatelessWidget {
  const SheetGroups({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = AppleColors.of(context);
    return Theme(
      data: theme.copyWith(
        extensions: [
          ...theme.extensions.values.where((e) => e is! AppleColors),
          c.copyWith(secondaryGroupedBackground: c.tertiaryGroupedBackground),
        ],
      ),
      child: child,
    );
  }
}

/// [showAppleSheet] com os grupos destacados do fundo ([SheetGroups]).
Future<T?> showSettingsSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
}) {
  return showAppleSheet<T>(
    context: context,
    title: title,
    builder: (context) => SheetGroups(child: Builder(builder: builder)),
  );
}

Future<T?> showChoiceSheet<T>({
  required BuildContext context,
  required String title,
  required List<Choice<T>> choices,
  T? selected,
  String? footer,
}) {
  return showSettingsSheet<T>(
    context: context,
    title: title,
    builder: (context) {
      final c = AppleColors.of(context);
      return ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: AppleSpacing.xs),
        children: [
          InsetGroupedSection(
            footer: footer,
            children: [
              for (final ch in choices)
                ListRow(
                  leading: ch.leading,
                  title: ch.label,
                  subtitle: ch.subtitle,
                  trailing: ch.value == selected
                      ? Icon(
                          Icons.check_rounded,
                          size: 20,
                          color: c.accent,
                        )
                      : const SizedBox(width: 20),
                  onTap: () => Navigator.of(context).pop(ch.value),
                ),
            ],
          ),
        ],
      );
    },
  );
}

/// Ícone e cor de marca de cada integração (chave do schema).
class IntegrationBrand {
  const IntegrationBrand(this.icon, this.color);
  final IconData icon;
  final Color color;

  static const fallback = IntegrationBrand(
    Icons.extension_rounded,
    Color(0xFF71717A),
  );

  static IntegrationBrand of(String key) => all[key] ?? fallback;

  static const all = <String, IntegrationBrand>{
    'discord': IntegrationBrand(
      Icons.sports_esports_rounded,
      Color(0xFF5865F2),
    ),
    'obs': IntegrationBrand(Icons.videocam_rounded, Color(0xFF3F3F46)),
    'twitch': IntegrationBrand(
      Icons.sensors_rounded,
      Color(0xFF9146FF),
    ),
    'youtube': IntegrationBrand(
      Icons.play_arrow_rounded,
      Color(0xFFFF0033),
    ),
    'spotify': IntegrationBrand(Icons.music_note_rounded, Color(0xFF1DB954)),
    'soundboard': IntegrationBrand(
      Icons.volume_up_rounded,
      Color(0xFFF59E0B),
    ),
    'homeassistant': IntegrationBrand(
      Icons.home_rounded,
      Color(0xFF18BCF2),
    ),
    'tuya': IntegrationBrand(Icons.lightbulb_rounded, Color(0xFFFF5A00)),
    'hue': IntegrationBrand(Icons.wb_sunny_rounded, Color(0xFF6E56CF)),
    'mqtt': IntegrationBrand(
      Icons.hub_rounded,
      Color(0xFF660066),
    ),
    'streamerbot': IntegrationBrand(
      Icons.smart_toy_rounded,
      Color(0xFF7E57C2),
    ),
    'vtubestudio': IntegrationBrand(
      Icons.face_rounded,
      Color(0xFFF06292),
    ),
    'tally': IntegrationBrand(
      Icons.radio_button_checked_rounded,
      Color(0xFFE53935),
    ),
    'vmix': IntegrationBrand(Icons.live_tv_rounded, Color(0xFF00897B)),
    'companion': IntegrationBrand(
      Icons.grid_view_rounded,
      Color(0xFFD50215),
    ),
    'mairlist': IntegrationBrand(
      Icons.podcasts_rounded,
      Color(0xFF1565C0),
    ),
    'radiodj': IntegrationBrand(Icons.radio_rounded, Color(0xFFEF6C00)),
  };
}
