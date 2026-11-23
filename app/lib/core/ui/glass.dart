import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/apple_tokens.dart';

/// Painel de superfície moderno (estilo shadcn/ui): fundo neutro elevado com borda
/// nítida de 1 px e desfoque discreto opcional. Usado na barra lateral do configurador,
/// popovers e avisos flutuantes.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = AppleRadii.lg,
    this.padding = EdgeInsets.zero,
    this.blur = 14,
    this.color,
    this.border = true,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// Força do desfoque (sigma).
  final double blur;

  /// Cor de fundo; padrão a superfície elevada do tema.
  final Color? color;

  /// Borda nítida de 1 px em volta.
  final bool border;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final fill = color ?? c.secondaryGroupedBackground.withValues(alpha: 0.96);
    final box = DecoratedBox(
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(radius),
        border: border ? Border.all(color: c.separator) : null,
      ),
      child: Padding(padding: padding, child: child),
    );
    if (blur <= 0 || fill.a >= 0.99) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: box,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: box,
      ),
    );
  }
}

/// Em que borda da tela fica a [GlassBar].
enum GlassBarEdge { top, bottom }

/// Barra de navegação ou ação de ponta a ponta: fundo neutro limpo, divisor de 1 px
/// no lado interno e respeito à área segura.
class GlassBar extends StatelessWidget {
  const GlassBar({
    super.key,
    required this.child,
    this.edge = GlassBarEdge.bottom,
    this.padding = const EdgeInsets.symmetric(horizontal: AppleSpacing.md),
    this.blur = 14,
    this.color,
  });

  final Widget child;
  final GlassBarEdge edge;
  final EdgeInsetsGeometry padding;
  final double blur;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final line = BorderSide(color: c.separator, width: 1);
    final top = edge == GlassBarEdge.top;
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color ?? c.barBackground,
            border: top ? Border(bottom: line) : Border(top: line),
          ),
          child: SafeArea(
            top: top,
            bottom: !top,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Superfície flutuante em cápsula/pílula com vidro fosco discreto, borda luminosa de 1 px
/// e sombra suave. Usada na barra de abas em pílula, no trilho lateral compacto e na barra
/// superior flutuante do deck.
class FloatingPillSurface extends StatelessWidget {
  const FloatingPillSurface({
    super.key,
    required this.child,
    this.radius = 999,
    this.padding = EdgeInsets.zero,
    this.blur = 18,
    this.color,
    this.borderColor,
    this.shadows,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry padding;
  final double blur;
  final Color? color;
  final Color? borderColor;
  final List<BoxShadow>? shadows;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final highContrast = MediaQuery.maybeHighContrastOf(context) ?? false;
    final dark = c.isDark;
    final fill = color ??
        (dark
            ? Color(highContrast ? 0xEE141418 : 0xCC121216)
            : Color(highContrast ? 0xFAFFFFFF : 0xE8FFFFFF));
    final topTint = Color.alphaBlend(
      Colors.white.withValues(alpha: dark ? 0.07 : 0.40),
      fill,
    );
    final bottomTint = dark
        ? fill
        : Color.alphaBlend(const Color(0x0A000000), fill);
    final rim = borderColor ??
        (dark
            ? Colors.white.withValues(alpha: highContrast ? 0.30 : 0.14)
            : Colors.black.withValues(alpha: highContrast ? 0.22 : 0.08));
    final dropShadows = shadows ??
        (dark
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.48),
                  blurRadius: 22,
                  spreadRadius: -2,
                  offset: const Offset(0, 10),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 5,
                  offset: const Offset(0, 2),
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.09),
                  blurRadius: 18,
                  spreadRadius: -2,
                  offset: const Offset(0, 6),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.04),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ]);
    final borderRadius = BorderRadius.circular(radius);

    final surface = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [topTint, bottomTint],
        ),
        borderRadius: borderRadius,
        border: Border.all(color: rim, width: highContrast ? 1.25 : 1),
      ),
      child: Padding(padding: padding, child: child),
    );

    final clipped = blur > 0 && fill.a < 0.99
        ? ClipRRect(
            borderRadius: borderRadius,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: surface,
            ),
          )
        : ClipRRect(borderRadius: borderRadius, child: surface);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: dropShadows,
      ),
      child: clipped,
    );
  }
}
