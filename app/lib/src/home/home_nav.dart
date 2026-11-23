import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

/// Destino de navegação principal na tela inicial do celular.
class HomeNavDestination {
  const HomeNavDestination({
    required this.index,
    required this.icon,
    required this.labelKey,
  });

  final int index;
  final IconData icon;

  /// Chave de tradução (passa por [tr]).
  final String labelKey;
}

/// Métricas enxutas da navegação móvel em cápsula só-ícones (retrato e paisagem).
abstract final class HomeNavMetrics {
  static const double portraitBottomMargin = 6.0;
  static const double portraitHorizontalMargin = 8.0;
  static const double portraitInnerPadding = 3.0;
  static const double portraitItemMinHeight = 44.0;
  static const double portraitSlotSize = 44.0;

  static const double sideRailEdgeMargin = 6.0;
  static const double sideRailInnerPadding = 3.0;
  static const double sideRailBaseWidth = 44.0;
  static const double sideRailBaseSlotHeight = 44.0;

  static double textScaleOf(BuildContext context) =>
      (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.0);

  /// Altura enxuta da cápsula inferior só-ícones em retrato (alvo confortável >= 44 dp).
  static double portraitDockHeight([double textScale = 1.0]) =>
      portraitSlotSize;

  /// Reserva total na base em retrato (área segura + margem mínima + cápsula).
  static double portraitInset(double safeBottom, [double textScale = 1.0]) =>
      safeBottom + portraitBottomMargin + portraitDockHeight(textScale);

  /// Largura enxuta do trilho lateral só-ícones em paisagem (alvo confortável >= 44 dp).
  static double sideRailWidth([double textScale = 1.0]) => sideRailBaseWidth;

  /// Altura de cada item do trilho lateral (alvo confortável >= 44 dp).
  static double sideRailSlotHeight([double textScale = 1.0]) =>
      sideRailBaseSlotHeight;

  /// Posição horizontal do trilho lateral, respeitando o recorte da câmera só quando há um.
  static double sideRailLeft(double safeLeft) =>
      math.max(safeLeft, sideRailEdgeMargin);

  /// Reserva lateral total em paisagem (borda direita exata do trilho).
  static double landscapeInset(double safeLeft, [double textScale = 1.0]) =>
      sideRailLeft(safeLeft) + sideRailWidth(textScale);
}

List<BoxShadow> _compactPillShadows(bool dark) => dark
    ? [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.42),
          blurRadius: 14,
          spreadRadius: -2,
          offset: const Offset(0, 6),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.24),
          blurRadius: 4,
          offset: const Offset(0, 1),
        ),
      ]
    : [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.08),
          blurRadius: 12,
          spreadRadius: -2,
          offset: const Offset(0, 4),
        ),
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 3,
          offset: const Offset(0, 1),
        ),
      ];

/// Navegação inferior enxuta só-ícones em cápsula flutuante para o celular em pé.
/// Espelha exatamente a cápsula lateral da paisagem com alvos >= 44 dp e mínima reserva.
class HomeBottomPillNav extends StatelessWidget {
  const HomeBottomPillNav({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<HomeNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final dark = AppleColors.of(context).isDark;
    const slotSize = HomeNavMetrics.portraitSlotSize;
    final count = destinations.length;
    final totalWidth = slotSize * count;
    final alignX = count <= 1
        ? 0.0
        : -1.0 + 2.0 * (selectedIndex.clamp(0, count - 1) / (count - 1));

    return SizedBox(
      width: totalWidth,
      height: slotSize,
      child: FloatingPillSurface(
        radius: slotSize / 2,
        padding: EdgeInsets.zero,
        shadows: _compactPillShadows(dark),
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedAlign(
                alignment: Alignment(alignX, 0),
                duration: AppleMotion.of(context, AppleMotion.normal),
                curve: AppleMotion.smooth,
                child: FractionallySizedBox(
                  widthFactor: 1 / math.max(1, count),
                  heightFactor: 1,
                  child: const Padding(
                    padding: EdgeInsets.all(HomeNavMetrics.portraitInnerPadding),
                    child: _ActiveNavPill(radius: 999, compactGlow: true),
                  ),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final item in destinations)
                  SizedBox(
                    width: slotSize,
                    height: slotSize,
                    child: _CompactIconNavTab(
                      icon: item.icon,
                      label: tr(item.labelKey),
                      selected: selectedIndex == item.index,
                      onTap: () => onSelected(item.index),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Trilho lateral enxuto só-ícones em cápsula flutuante para o celular deitado.
/// Mantém alvos de toque >= 44 dp centrados verticalmente com mínima reserva lateral.
class HomeSidePillNav extends StatelessWidget {
  const HomeSidePillNav({
    super.key,
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<HomeNavDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final dark = AppleColors.of(context).isDark;
    final width = HomeNavMetrics.sideRailWidth();
    final slotHeight = HomeNavMetrics.sideRailSlotHeight();
    final count = destinations.length;
    final totalHeight = slotHeight * count;
    final outerRadius = width / 2;
    final alignY = count <= 1
        ? 0.0
        : -1.0 + 2.0 * (selectedIndex.clamp(0, count - 1) / (count - 1));

    return SizedBox(
      width: width,
      child: FloatingPillSurface(
        radius: outerRadius,
        padding: EdgeInsets.zero,
        shadows: _compactPillShadows(dark),
        child: SizedBox(
          width: width,
          height: totalHeight,
          child: Stack(
            children: [
              Positioned.fill(
                child: AnimatedAlign(
                  alignment: Alignment(0, alignY),
                  duration: AppleMotion.of(context, AppleMotion.normal),
                  curve: AppleMotion.smooth,
                  child: FractionallySizedBox(
                    widthFactor: 1,
                    heightFactor: 1 / math.max(1, count),
                    child: const Padding(
                      padding: EdgeInsets.all(HomeNavMetrics.sideRailInnerPadding),
                      child: _ActiveNavPill(radius: 999, compactGlow: true),
                    ),
                  ),
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final item in destinations)
                    SizedBox(
                      width: width,
                      height: slotHeight,
                      child: _CompactIconNavTab(
                        icon: item.icon,
                        label: tr(item.labelKey),
                        selected: selectedIndex == item.index,
                        onTap: () => onSelected(item.index),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cápsula ativa deslizante com gradiente sutil e brilho suave na cor de destaque.
class _ActiveNavPill extends StatelessWidget {
  const _ActiveNavPill({required this.radius, this.compactGlow = false});

  final double radius;
  final bool compactGlow;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final dark = c.isDark;
    final top = Color.lerp(c.accent, Colors.white, dark ? 0.14 : 0.10)!;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [top, c.accent],
        ),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: Colors.white.withValues(alpha: dark ? 0.18 : 0.24),
          width: 0.75,
        ),
        boxShadow: [
          BoxShadow(
            color: c.accent.withValues(alpha: dark ? 0.32 : 0.22),
            blurRadius: compactGlow ? 8 : 12,
            offset: Offset(0, compactGlow ? 2 : 3),
          ),
        ],
      ),
    );
  }
}

class _CompactIconNavTab extends StatelessWidget {
  const _CompactIconNavTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final targetColor = selected
        ? c.onAccent
        : (c.isDark ? const Color(0xFFB8B8C2) : const Color(0xFF52525B));
    final duration = AppleMotion.of(context, AppleMotion.fast);

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: ApplePressable(
          onTap: onTap,
          pressedScale: 0.92,
          haptic: true,
          child: ExcludeSemantics(
            child: Center(
              child: TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: targetColor),
                duration: duration,
                builder: (context, fg, _) => Icon(
                  icon,
                  size: 20,
                  color: fg ?? targetColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
