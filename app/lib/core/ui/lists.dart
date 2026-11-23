import 'package:flutter/material.dart';

import '../theme/apple_tokens.dart';
import '../theme/apple_typography.dart';

/// Grupo de linhas em cartão moderno (estilo shadcn/ui): título limpo acima, cartão com
/// borda nítida de 1 px, divisores sutis entre as linhas e rodapé explicativo abaixo.
class InsetGroupedSection extends StatelessWidget {
  const InsetGroupedSection({
    super.key,
    required this.children,
    this.header,
    this.footer,
    this.margin = const EdgeInsets.fromLTRB(
      AppleSpacing.screen,
      0,
      AppleSpacing.screen,
      AppleSpacing.lg,
    ),
  });

  /// Linhas do grupo, normalmente [ListRow]s.
  final List<Widget> children;

  /// Título acima do grupo.
  final String? header;

  /// Texto de ajuda abaixo do grupo.
  final String? footer;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Container(height: 1, color: c.separator));
      }
      rows.add(children[i]);
    }
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpacing.xxs,
                0,
                AppleSpacing.xxs,
                AppleSpacing.xs,
              ),
              child: Text(
                header!,
                style: type.footnote.copyWith(
                  color: c.secondaryLabel,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: c.secondaryGroupedBackground,
              borderRadius: BorderRadius.circular(AppleRadii.lg),
              border: Border.all(color: c.separator),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: rows),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpacing.xxs,
                AppleSpacing.xs,
                AppleSpacing.xxs,
                0,
              ),
              child: Text(
                footer!,
                style: type.caption1.copyWith(
                  color: c.secondaryLabel,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Ícone de uma linha em badge moderno sutil (fundo tingido + borda fina + glifo nítido).
class ListRowIcon extends StatelessWidget {
  const ListRowIcon(this.icon, {super.key, this.color});

  static const double size = 32;

  final IconData icon;

  /// Cor do badge; padrão a cor de destaque.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final tone = color ?? c.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: c.isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(AppleRadii.sm),
        border: Border.all(
          color: tone.withValues(alpha: c.isDark ? 0.28 : 0.20),
        ),
      ),
      child: Icon(icon, size: 17, color: tone),
    );
  }
}

/// Linha interativa moderna: ícone opcional, título, subtítulo, valor atual à direita,
/// widget ([trailing], ex. [AppleSwitch]) e/ou seta discreta.
class ListRow extends StatefulWidget {
  const ListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.value,
    this.trailing,
    this.chevron,
    this.onTap,
    this.destructive = false,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;

  /// Normalmente um [ListRowIcon].
  final Widget? leading;

  /// Valor atual em cinza, à direita (ex.: "Escuro").
  final String? value;
  final Widget? trailing;
  final bool? chevron;
  final VoidCallback? onTap;

  /// Título em vermelho (Apagar, Sair).
  final bool destructive;
  final bool enabled;

  @override
  State<ListRow> createState() => _ListRowState();
}

class _ListRowState extends State<ListRow> {
  bool _down = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final w = widget;
    final tappable = w.enabled && w.onTap != null;
    final showChevron = w.chevron ?? (w.onTap != null && w.trailing == null);

    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppleSpacing.md,
          vertical: AppleSpacing.sm - 2,
        ),
        child: Row(
          children: [
            if (w.leading != null) ...[
              w.leading!,
              const SizedBox(width: AppleSpacing.sm),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    w.title,
                    style: type.subheadline.copyWith(
                      color: w.destructive ? c.red : c.label,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (w.subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        w.subtitle!,
                        style: type.caption1.copyWith(
                          color: c.secondaryLabel,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (w.value != null)
              Flexible(
                flex: 0,
                child: Padding(
                  padding: const EdgeInsets.only(left: AppleSpacing.sm),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      w.value!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.footnote.copyWith(color: c.secondaryLabel),
                    ),
                  ),
                ),
              ),
            if (w.trailing != null)
              Padding(
                padding: const EdgeInsets.only(left: AppleSpacing.sm),
                child: w.trailing!,
              ),
            if (showChevron)
              Padding(
                padding: const EdgeInsets.only(left: AppleSpacing.xs),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: c.tertiaryLabel,
                ),
              ),
          ],
        ),
      ),
    );

    final bg = _down
        ? c.fill.withValues(alpha: 0.65)
        : (_hovered && tappable
              ? c.tertiaryFill.withValues(alpha: 0.85)
              : Colors.transparent);

    return Opacity(
      opacity: w.enabled ? 1 : 0.45,
      child: MouseRegion(
        cursor: tappable ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: tappable ? (_) => setState(() => _down = true) : null,
          onTapUp: tappable ? (_) => setState(() => _down = false) : null,
          onTapCancel: tappable ? () => setState(() => _down = false) : null,
          onTap: tappable ? w.onTap : null,
          child: AnimatedContainer(
            duration: _down
                ? Duration.zero
                : AppleMotion.of(context, AppleMotion.fast),
            color: bg,
            child: row,
          ),
        ),
      ),
    );
  }
}

/// Switch moderno multiplataforma (estilo shadcn/ui): trilho compacto na cor de destaque,
/// borda sutil desligado, bolinha nítida e acessível por toque e teclado.
class AppleSwitch extends StatelessWidget {
  const AppleSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final enabled = onChanged != null;
    final duration = AppleMotion.of(context, AppleMotion.fast);

    return Semantics(
      toggled: value,
      enabled: enabled,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? () => onChanged!(!value) : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.45,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: AnimatedContainer(
                duration: duration,
                curve: AppleMotion.easeOut,
                width: 44,
                height: 24,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: value ? c.accent : c.fill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: value ? c.accent : c.opaqueSeparator,
                    width: 1,
                  ),
                ),
                child: AnimatedAlign(
                  duration: duration,
                  curve: AppleMotion.easeOut,
                  alignment: value
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: value ? c.onAccent : Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 2,
                          offset: Offset(0, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
