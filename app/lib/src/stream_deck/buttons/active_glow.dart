import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

/// Brilho em volta da tecla ligada (gravando, mudo, cena no ar), na cor do estado. Só
/// no visual squircle: os estilos antigos têm a moldura deles. Acende e apaga suave.
class ActiveGlow extends StatelessWidget {
  const ActiveGlow({
    super.key,
    required this.active,
    required this.child,
    this.color,
  });

  final bool active;

  /// Cor do brilho; nula usa a cor de "ligado" do tema.
  final Color? color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final deck = DeckTheme.of(context);
    if (deck.tileStyle != DeckTileStyle.squircle) return child;
    final glow = color ?? deck.activeColor;
    // No fundo claro um halo forte vira mancha: fica mais contido.
    final dark = deck.background.computeLuminance() < 0.3;
    return LayoutBuilder(
      builder: (context, c) {
        final side = c.maxWidth.isFinite && c.maxHeight.isFinite
            ? math.min(c.maxWidth, c.maxHeight)
            : 80.0;
        return AnimatedContainer(
          duration: AppleMotion.of(context, DeckTileMotion.normal),
          curve: AppleMotion.easeOut,
          decoration: ShapeDecoration(
            shape: AppleShapes.squircle(AppleShapes.tileRadius(side)),
            shadows: [
              BoxShadow(
                color: glow.withValues(alpha: active ? (dark ? 0.55 : 0.35) : 0),
                blurRadius: side * 0.22,
                spreadRadius: -side * 0.02,
              ),
            ],
          ),
          child: child,
        );
      },
    );
  }
}
