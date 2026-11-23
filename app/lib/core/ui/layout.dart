import 'package:flutter/material.dart';

import '../theme/apple_tokens.dart';
import '../theme/apple_typography.dart';

/// Cabeçalho de tela moderno: título forte, subtítulo discreto e ação opcional à direita.
class LargeTitleHeader extends StatelessWidget {
  const LargeTitleHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      AppleSpacing.screen,
      AppleSpacing.sm,
      AppleSpacing.screen,
      AppleSpacing.md,
    ),
    this.divider = false,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  /// Linha nítida embaixo para separar o cabeçalho do conteúdo.
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Container(
      padding: padding,
      decoration: divider
          ? BoxDecoration(
              border: Border(bottom: BorderSide(color: c.separator)),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: type.title1.copyWith(color: c.label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      subtitle!,
                      style: type.subheadline.copyWith(color: c.secondaryLabel),
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null)
            Padding(
              padding: const EdgeInsets.only(left: AppleSpacing.sm),
              child: trailing!,
            ),
        ],
      ),
    );
  }
}

/// Estado vazio moderno: ícone em badge neutro com borda, título, explicação e ação opcional.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;

  /// Normalmente um [PrimaryButton] ou [SecondaryButton].
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppleSpacing.xl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: c.tertiaryFill,
                  borderRadius: BorderRadius.circular(AppleRadii.lg),
                  border: Border.all(color: c.separator),
                ),
                child: Icon(icon, size: 26, color: c.secondaryLabel),
              ),
              const SizedBox(height: AppleSpacing.md),
              Text(
                title,
                textAlign: TextAlign.center,
                style: type.headline.copyWith(color: c.label),
              ),
              if (message != null) ...[
                const SizedBox(height: AppleSpacing.xs),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: type.subheadline.copyWith(color: c.secondaryLabel),
                ),
              ],
              if (action != null) ...[
                const SizedBox(height: AppleSpacing.lg),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Moldura neutra de smartphone (sem ilha exclusiva de iPhone) em volta de [child]:
/// usada no espelho ao vivo do configurador e nas prévias de layout.
class PhoneFrame extends StatelessWidget {
  const PhoneFrame({
    super.key,
    required this.child,
    this.landscape = true,
    this.aspectRatio = 19.5 / 9,
    this.showIsland = true,
    this.screenColor = const Color(0xFF09090B),
  });

  final Widget child;
  final bool landscape;

  /// Proporção do lado comprido sobre o curto (padrão moderno 19,5:9).
  final double aspectRatio;

  /// Desenha um ponto discreto de câmera frontal (universal Android/iOS).
  final bool showIsland;
  final Color screenColor;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: landscape ? aspectRatio : 1 / aspectRatio,
      child: LayoutBuilder(
        builder: (context, c) {
          final short = landscape ? c.maxHeight : c.maxWidth;
          final outerRadius = short * 0.12;
          final bezel = (short * 0.032).clamp(4.0, 11.0);
          final innerRadius = (outerRadius - bezel).clamp(6.0, outerRadius);
          final cameraDot = Container(
            width: (short * 0.036).clamp(5.0, 10.0),
            height: (short * 0.036).clamp(5.0, 10.0),
            decoration: BoxDecoration(
              color: const Color(0xFF18181B),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF27272A), width: 1),
            ),
          );
          return DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF111114),
              borderRadius: BorderRadius.circular(outerRadius),
              border: Border.all(color: const Color(0xFF27272A), width: 1.5),
              boxShadow: AppleShadows.floating(Theme.of(context).brightness),
            ),
            child: Padding(
              padding: EdgeInsets.all(bezel),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(innerRadius),
                child: ColoredBox(
                  color: screenColor,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      child,
                      if (showIsland)
                        Align(
                          alignment: landscape
                              ? Alignment.centerLeft
                              : Alignment.topCenter,
                          child: Padding(
                            padding: EdgeInsets.all(short * 0.025),
                            child: cameraDot,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
