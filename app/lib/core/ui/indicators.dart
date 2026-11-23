import 'package:flutter/material.dart';

import '../theme/apple_tokens.dart';
import '../theme/apple_typography.dart';

/// Pontinhos de página: a página atual vira uma cápsula branca mais larga, com
/// transição de mola. Toque num ponto chama [onTap] com o índice.
class PageDots extends StatelessWidget {
  const PageDots({
    super.key,
    required this.count,
    required this.index,
    this.onTap,
    this.color,
    this.inactiveColor,
    this.dotSize = 6,
    this.activeWidth = 18,
    this.spacing = 6,
  });

  final int count;

  /// Página atual (0-based).
  final int index;
  final ValueChanged<int>? onTap;

  /// Cor da cápsula ativa; padrão o texto principal (branco no escuro).
  final Color? color;

  /// Cor dos pontos inativos; padrão o texto terciário.
  final Color? inactiveColor;
  final double dotSize;
  final double activeWidth;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    if (count <= 1) return const SizedBox.shrink();
    final c = AppleColors.of(context);
    final on = color ?? c.label;
    final off = inactiveColor ?? c.tertiaryLabel;
    final duration = AppleMotion.of(context, AppleMotion.normal);
    return Semantics(
      value: '${index + 1}/$count',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < count; i++)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap == null ? null : () => onTap!(i),
              child: Padding(
                // Área de toque maior que o ponto.
                padding: EdgeInsets.symmetric(
                  horizontal: spacing / 2,
                  vertical: dotSize,
                ),
                child: AnimatedContainer(
                  key: ValueKey('page-dot-$i'),
                  duration: duration,
                  curve: AppleMotion.smooth,
                  width: i == index ? activeWidth : dotSize,
                  height: dotSize,
                  decoration: ShapeDecoration(
                    color: i == index ? on : off,
                    shape: const StadiumBorder(),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Bolinha de estado (conectado/desconectado). Com [glow], ganha um halo da
/// própria cor, como o LED dos prints.
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, this.color, this.size = 8, this.glow = true});

  /// Padrão: verde do sistema.
  final Color? color;
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppleColors.of(context).green;
    return AnimatedContainer(
      duration: AppleMotion.of(context, AppleMotion.normal),
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        boxShadow: glow
            ? [BoxShadow(color: c.withValues(alpha: 0.55), blurRadius: size)]
            : null,
      ),
    );
  }
}

/// Selo de status moderno (estilo Badge do shadcn/ui): fundo tingido sutil, borda de 1 px
/// e bolinha de estado. Use [label] traduzido; [color] troca a cor do estado.
class LivePill extends StatelessWidget {
  const LivePill({super.key, this.label = 'LIVE', this.color});

  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppleColors.of(context).green;
    final type = AppleTextStyles.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppleRadii.sm),
        border: Border.all(color: c.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          StatusDot(color: c, size: 6, glow: false),
          const SizedBox(width: 6),
          Text(
            label,
            style: type.caption2.copyWith(
              color: c,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}
