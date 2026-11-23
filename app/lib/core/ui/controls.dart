import 'package:flutter/material.dart';

import '../theme/apple_tokens.dart';
import '../theme/apple_typography.dart';
import 'deck_squircle_tile.dart';

/// Campo de busca moderno (estilo shadcn/ui): borda de 1 px, ícone de lupa, foco nítido
/// e altura flexível para suportar texto grande de acessibilidade sem cortar.
class AppleSearchField extends StatelessWidget {
  const AppleSearchField({
    super.key,
    required this.placeholder,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.focusNode,
    this.autofocus = false,
    this.trailing,
  });

  /// Texto de dica, já traduzido.
  final String placeholder;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final FocusNode? focusNode;
  final bool autofocus;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppleRadii.sm),
          borderSide: BorderSide(color: color, width: width),
        );

    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 40),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: TextInputAction.search,
        style: type.subheadline.copyWith(color: c.label),
        cursorColor: c.accent,
        decoration: InputDecoration(
          isDense: true,
          hintText: placeholder,
          hintStyle: type.subheadline.copyWith(color: c.tertiaryLabel),
          filled: true,
          fillColor: c.isDark ? c.tertiaryGroupedBackground : Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 10,
            horizontal: AppleSpacing.sm,
          ),
          prefixIcon: Icon(
            Icons.search_rounded,
            size: 18,
            color: c.tertiaryLabel,
          ),
          prefixIconConstraints: const BoxConstraints(minWidth: 38),
          suffixIcon: trailing == null
              ? null
              : Padding(
                  padding: const EdgeInsets.only(right: AppleSpacing.sm),
                  child: DefaultTextStyle.merge(
                    style: type.caption1.copyWith(color: c.tertiaryLabel),
                    child: trailing!,
                  ),
                ),
          suffixIconConstraints: const BoxConstraints(minWidth: 0),
          border: border(c.separator),
          enabledBorder: border(c.separator),
          focusedBorder: border(c.accent, 1.5),
        ),
      ),
    );
  }
}

/// Controle segmentado moderno (estilo Tabs do shadcn/ui), neutro e multiplataforma.
/// [segments] mantém a ordem de inserção e suporta texto grande sem estourar.
class SegmentedControl<T extends Object> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });

  /// Valor -> conteúdo do segmento (um `Text` curto ou um `Icon`).
  final Map<T, Widget> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final duration = AppleMotion.of(context, AppleMotion.fast);

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.tertiaryFill,
        borderRadius: BorderRadius.circular(AppleRadii.md),
        border: Border.all(color: c.separator),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final expand = constraints.hasBoundedWidth;
          final items = <Widget>[
            for (final entry in segments.entries)
              _SegmentItem<T>(
                selected: entry.key == value,
                duration: duration,
                expand: expand,
                onTap: () {
                  if (entry.key != value) onChanged(entry.key);
                },
                child: DefaultTextStyle.merge(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: type.footnote.copyWith(
                    color: entry.key == value ? c.label : c.secondaryLabel,
                    fontWeight: entry.key == value
                        ? FontWeight.w600
                        : FontWeight.w500,
                  ),
                  child: IconTheme.merge(
                    data: IconThemeData(
                      color: entry.key == value ? c.label : c.secondaryLabel,
                      size: 16,
                    ),
                    child: entry.value,
                  ),
                ),
              ),
          ];
          return Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: items,
          );
        },
      ),
    );
  }
}

class _SegmentItem<T> extends StatelessWidget {
  const _SegmentItem({
    required this.selected,
    required this.duration,
    required this.expand,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final Duration duration;
  final bool expand;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final pill = Semantics(
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: AnimatedContainer(
            duration: duration,
            curve: AppleMotion.easeOut,
            constraints: const BoxConstraints(minHeight: 32),
            padding: const EdgeInsets.symmetric(
              horizontal: AppleSpacing.sm,
              vertical: 4,
            ),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected
                  ? (c.isDark ? c.fill : Colors.white)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(AppleRadii.sm - 1),
              border: selected
                  ? Border.all(
                      color: c.isDark ? c.opaqueSeparator : c.separator,
                      width: 0.75,
                    )
                  : Border.all(color: Colors.transparent, width: 0.75),
              boxShadow: selected && !c.isDark
                  ? const [
                      BoxShadow(
                        color: Color(0x0D000000),
                        blurRadius: 3,
                        offset: Offset(0, 1),
                      ),
                    ]
                  : null,
            ),
            child: child,
          ),
        ),
      ),
    );
    return expand ? Expanded(child: pill) : pill;
  }
}

/// Botão moderno retangular arredondado (shadcn/ui). Base de [PrimaryButton] e [SecondaryButton].
class _ActionButton extends StatefulWidget {
  const _ActionButton({
    required this.label,
    required this.background,
    required this.foreground,
    this.borderColor,
    this.icon,
    this.onPressed,
    this.expand = false,
    this.compact = false,
    this.loading = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color background;
  final Color foreground;
  final Color? borderColor;
  final bool expand;
  final bool compact;
  final bool loading;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final type = AppleTextStyles.of(context);
    final enabled = widget.onPressed != null && !widget.loading;
    final text = (widget.compact ? type.footnote : type.subheadline).copyWith(
      color: widget.foreground,
      fontWeight: FontWeight.w600,
    );
    final hoverOverlay = _hovered && enabled
        ? (widget.foreground.computeLuminance() > 0.5
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.05))
        : Colors.transparent;
    final bg = Color.alphaBlend(hoverOverlay, widget.background);

    final content = Row(
      mainAxisSize: widget.expand ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.loading)
          SizedBox.square(
            dimension: widget.compact ? 14 : 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: widget.foreground,
            ),
          )
        else if (widget.icon != null)
          Icon(
            widget.icon,
            size: widget.compact ? 16 : 18,
            color: widget.foreground,
          ),
        if (widget.loading || widget.icon != null)
          const SizedBox(width: AppleSpacing.xs),
        Flexible(
          child: Text(
            widget.label,
            style: text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );

    return Semantics(
      button: true,
      enabled: enabled,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Opacity(
          opacity: enabled || widget.loading ? 1 : 0.45,
          child: ApplePressable(
            onTap: enabled ? widget.onPressed : null,
            pressedScale: 0.98,
            haptic: false,
            child: AnimatedContainer(
              duration: AppleMotion.of(context, AppleMotion.fast),
              constraints: BoxConstraints(
                minHeight: widget.compact ? 36 : 44,
              ),
              padding: EdgeInsets.symmetric(
                horizontal: widget.compact ? 14 : AppleSpacing.lg,
                vertical: widget.compact ? 6 : 10,
              ),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(
                  widget.compact ? AppleRadii.sm : AppleRadii.md,
                ),
                border: widget.borderColor != null
                    ? Border.all(color: widget.borderColor!)
                    : null,
              ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// Ação principal: botão sólido na cor de destaque (ou [color]) com texto de alto contraste.
/// [expand] ocupa a largura toda; [compact] usa altura de 36 (barras e cartões).
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.color,
    this.expand = false,
    this.compact = false,
    this.loading = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;

  /// Troca a cor de fundo (ex.: vermelho para ação destrutiva).
  final Color? color;
  final bool expand;
  final bool compact;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final bg = color ?? c.accent;
    return _ActionButton(
      label: label,
      icon: icon,
      onPressed: onPressed,
      background: bg,
      foreground: AppleColors.onColor(bg),
      expand: expand,
      compact: compact,
      loading: loading,
    );
  }
}

/// Ação secundária (estilo outline/secondary do shadcn/ui): fundo neutro com borda de 1 px.
/// Quando [color] é informada (ex.: vermelho para desconectar), tinge o texto e a borda.
class SecondaryButton extends StatelessWidget {
  const SecondaryButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.color,
    this.expand = false,
    this.compact = false,
    this.loading = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color? color;
  final bool expand;
  final bool compact;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final tinted = color != null && color != c.accent;
    final fg = tinted ? color! : c.label;
    final bg = tinted
        ? color!.withValues(alpha: c.isDark ? 0.14 : 0.08)
        : (c.isDark ? c.tertiaryGroupedBackground : Colors.white);
    final border = tinted
        ? color!.withValues(alpha: c.isDark ? 0.35 : 0.28)
        : c.opaqueSeparator;
    return _ActionButton(
      label: label,
      icon: icon,
      onPressed: onPressed,
      background: bg,
      foreground: fg,
      borderColor: border,
      expand: expand,
      compact: compact,
      loading: loading,
    );
  }
}
