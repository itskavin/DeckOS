import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/apple_tokens.dart';
import '../theme/deck_theme.dart';
import '../theme/theme_controller.dart';
import 'liquid_glass_icon.dart';

/// Qualquer coisa que afunda ao toque: encolhe rápido ao encostar o dedo e volta com
/// uma mola ao soltar, vibrando de leve (conforme a preferência de vibração).
/// Sem vibração, o afundar é a única confirmação de que o toque pegou.
class ApplePressable extends StatefulWidget {
  const ApplePressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.94,
    this.haptic = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Escala com o dedo em cima (1 = não encolhe).
  final double pressedScale;

  /// Vibra ao encostar (respeita a vibração escolhida nos ajustes).
  final bool haptic;

  /// O dedo está em cima do [ApplePressable] mais próximo? O [LiquidGlassIcon] usa
  /// para afundar a placa e acender o aro.
  static bool isDown(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PressedScope>()?.down ?? false;

  @override
  State<ApplePressable> createState() => _ApplePressableState();
}

class _ApplePressableState extends State<ApplePressable> {
  bool _down = false;

  void _set(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    if (!enabled) return widget.child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Vibra ao encostar, não ao soltar: é o que dá a sensação de botão físico.
      onTapDown: (_) {
        _set(true);
        if (widget.haptic && widget.onTap != null) {
          ThemeController.instance.tapFeedback();
        }
      },
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onLongPressEnd: (_) => _set(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1,
        // Desce rápido e sem mola; sobe com a mola (um quique curto).
        duration: AppleMotion.of(
          context,
          _down ? AppleMotion.fast : const Duration(milliseconds: 420),
        ),
        curve: _down ? AppleMotion.easeOut : DeckTileMotion.snappy,
        child: _PressedScope(down: _down, child: widget.child),
      ),
    );
  }
}

class _PressedScope extends InheritedWidget {
  const _PressedScope({required this.down, required super.child});

  final bool down;

  @override
  bool updateShouldNotify(_PressedScope old) => old.down != down;
}

/// A tecla do deck no visual da Apple: quadrado grafite de canto contínuo, igual para
/// todo botão, com um brilho quase imperceptível no topo e borda fina. A cor do botão
/// não pinta a tecla: vai só no glifo e, ligada, no brilho em volta. Mostra [child] ou
/// monta o conteúdo com [image] / [icon] e [label].
///
/// Cores vêm do [DeckTheme]; a cor do conteúdo é repassada via IconTheme e
/// DefaultTextStyle (leia com `IconTheme.of(context).color`).
class DeckSquircleTile extends StatelessWidget {
  const DeckSquircleTile({
    super.key,
    this.child,
    this.icon,
    this.image,
    this.label,
    this.color,
    this.active = false,
    this.activeColor,
    this.onTap,
    this.onLongPress,
  });

  /// Conteúdo livre; quando dado, [icon], [image] e [label] são ignorados.
  final Widget? child;

  /// Glifo no meio da tecla (os controles do sistema dos prints).
  final IconData? icon;

  /// Ícone de app, colorido e com os cantos dele, centrado na tecla.
  final ImageProvider? image;

  /// Rótulo; abaixo do ícone/imagem, ou sozinho no centro.
  final String? label;

  /// Cor do botão: tinge só o glifo. Cinza ou nula = glifo branco.
  final Color? color;

  /// Toggle ligado (mute, gravando, luz acesa...).
  final bool active;

  /// Cor de "ligado"; nula usa a do tema.
  final Color? activeColor;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Tamanho do glifo em fração da tecla. O desenho do Cupertino ocupa ~80% da caixa:
  /// com 0,46 ele fica do tamanho dos SF Symbols dos prints (~37% da tecla).
  static const glyphFraction = 0.46;

  /// Cor do glifo para a cor do botão [color] (nula ou cinza = a do tema).
  static Color glyphColor(DeckTheme deck, Color? color) {
    final darkBg = deck.background.computeLuminance() < 0.3;
    final tint = color != null && HSLColor.fromColor(color).saturation >= 0.15
        ? color
        : null;
    return tint == null ? deck.foreground : _legible(tint, darkBg);
  }

  @override
  Widget build(BuildContext context) {
    final deck = DeckTheme.of(context);
    final darkBg = deck.background.computeLuminance() < 0.3;

    // A tecla é sempre a mesma; ligada, ganha um véu da cor de "ligado" e o glifo
    // assume essa cor (o brilho em volta vem do ActiveGlow).
    final on = activeColor ?? deck.activeColor;
    final fill = active
        ? Color.alphaBlend(
            on.withValues(alpha: darkBg ? 0.22 : 0.14),
            deck.tileColor,
          )
        : deck.tileColor;
    final fg = active ? _legible(on, darkBg) : glyphColor(deck, color);

    final tile = LayoutBuilder(
      builder: (context, c) {
        final side = c.maxWidth.isFinite && c.maxHeight.isFinite
            ? math.min(c.maxWidth, c.maxHeight)
            : 80.0;
        final radius = AppleShapes.tileRadius(side);
        // Brilho sutil no topo e borda fina de vidro: define a silhueta da tecla tanto
        // no preto OLED quanto no fundo claro, mantendo o destaque no ícone.
        final top = Color.lerp(
          fill,
          const Color(0xFFFFFFFF),
          darkBg ? 0.045 : 0.45,
        )!;
        final rimColor = active
            ? on.withValues(alpha: darkBg ? 0.36 : 0.28)
            : (darkBg ? const Color(0x1AFFFFFF) : const Color(0x16000000));
        return AnimatedContainer(
          duration: AppleMotion.of(context, DeckTileMotion.normal),
          curve: AppleMotion.easeOut,
          decoration: ShapeDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [top, fill],
            ),
            shape: AppleShapes.squircle(
              radius,
              side: BorderSide(color: rimColor, width: darkBg ? 0.75 : 0.5),
            ),
            shadows: darkBg
                ? const [
                    BoxShadow(
                      color: Color(0x52000000),
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ]
                : AppleShadows.card(Brightness.light),
          ),
          child: IconTheme.merge(
            data: IconThemeData(
              color: fg,
              size: side * glyphFraction * deck.glyphScale,
            ),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: fg, fontFamily: deckTileFontFamily()),
              child: Padding(
                padding: EdgeInsets.all(side * 0.08),
                child: Center(
                  child: child ??
                      _content(side, deck.appIconFraction, deck.glyphScale),
                ),
              ),
            ),
          ),
        );
      },
    );

    return ApplePressable(onTap: onTap, onLongPress: onLongPress, child: tile);
  }

  Widget _content(double side, double imageFraction, double glyphScale) {
    Widget? art;
    if (image != null) {
      final s = (side * imageFraction * (label == null ? 1 : 0.70)).clamp(
        16.0,
        side * 0.88,
      );
      art = LiquidGlassIcon(image: image!, size: s);
    } else if (icon != null) {
      art = LiquidGlassGlyph(
        child: Icon(
          icon,
          size: (side * (label == null ? glyphFraction : 0.35) * glyphScale)
              .clamp(16.0, side * 0.65),
        ),
      );
    }
    final text = label == null || label!.isEmpty
        ? null
        : Text(
            label!,
            maxLines: art == null ? 3 : 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: (side * (art == null ? 0.15 : 0.12)).clamp(9.0, 16.0),
              fontWeight: FontWeight.w600,
              height: 1.15,
              letterSpacing: -0.1,
            ),
          );
    if (art == null) return text ?? const SizedBox.shrink();
    if (text == null) return art;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: art),
        SizedBox(height: side * 0.05),
        text,
      ],
    );
  }

  /// Clareia (fundo escuro) ou escurece (fundo claro) a cor até ficar legível.
  static Color _legible(Color c, bool darkBg) {
    final hsl = HSLColor.fromColor(c);
    if (darkBg) {
      return hsl.lightness < 0.62 ? hsl.withLightness(0.62).toColor() : c;
    }
    return hsl.lightness > 0.42 ? hsl.withLightness(0.42).toColor() : c;
  }
}

/// Slot vazio no visual squircle: fundo apagado, borda fina e um "+" discreto.
class DeckSquircleEmptyTile extends StatelessWidget {
  const DeckSquircleEmptyTile({super.key, this.onTap, this.onLongPress});

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final deck = DeckTheme.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: LayoutBuilder(
        builder: (context, c) {
          final side = c.maxWidth.isFinite && c.maxHeight.isFinite
              ? math.min(c.maxWidth, c.maxHeight)
              : 80.0;
          return DecoratedBox(
            decoration: ShapeDecoration(
              color: deck.emptyTileColor,
              shape: AppleShapes.squircle(
                AppleShapes.tileRadius(side),
                side: AppleShapes.hairline(
                  deck.outline.withValues(alpha: 0.10),
                ),
              ),
            ),
            child: Center(
              child: Icon(
                Icons.add,
                size: math.min(24, side * 0.3),
                color: deck.outline.withValues(alpha: 0.25),
              ),
            ),
          );
        },
      ),
    );
  }
}
