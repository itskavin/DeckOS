import 'package:deckos/core/core.dart';
import 'package:deckos/src/services/signalr_service.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../actions/action_catalog.dart';
import 'active_glow.dart';
import 'button_icons.dart';
import 'colors.dart';

/// Como um tipo de ação desenha o botão no deck. Cada tipo com visual próprio (OBS,
/// Discord, Spotify...) tem o seu; os demais usam o [DefaultButtonRenderer].
///
/// Para um tipo novo: escreva um renderer e registre em `renderers.dart`.
abstract class ButtonRenderer {
  const ButtonRenderer();

  /// Desenha o botão. Roda dentro de um Watch: ler um signal aqui já redesenha quando
  /// ele muda.
  Widget build(ButtonLook look);

  /// Busca o estado inicial, se o tipo precisar (chamado uma vez por botão).
  void init(ButtonLook look) {}

  /// Atualiza o estado local na hora do toque, antes da confirmação do PC, para o
  /// botão não parecer travado. O PC corrige pelo broadcast depois.
  void optimisticTap(ButtonLook look, SignalRService signalR) {}
}

/// Tudo que um renderer precisa de um botão: dados, cores e o [tile] que monta o visual
/// com o estado ativo (inclusive o dos botões de dois estados).
class ButtonLook {
  final DeckButton button;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  ButtonLook({
    required this.button,
    required this.onTap,
    required this.onLongPress,
  });

  DeckAction? get action => button.action;
  String? get type => action?.type;
  Map<String, String> get params => action?.parameters ?? const {};

  /// Operação da ação, em minúsculas.
  String op(String fallback) => (params['operation'] ?? fallback).toLowerCase();

  Color? get color => parseHexColor(button.backgroundColor);
  Color? get activeColor => parseHexColor(button.activeColor);

  /// Rótulo escolhido pelo usuário (null se vazio).
  String? get ownLabel =>
      (button.label?.isNotEmpty ?? false) ? button.label : null;

  bool get hasOwnIcon =>
      (button.iconName?.isNotEmpty ?? false) ||
      (button.iconBase64?.isNotEmpty ?? false);

  /// Liga/desliga do botão de dois estados (guardado no PC).
  bool get toggledOn {
    if (!button.toggle) return false;
    try {
      return Injector.get<SignalRService>().stateOf(
            'ReceiveButtonToggles',
          )[button.id] ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// O ícone escolhido pelo usuário; sem ele, [fallback] ou o ícone do tipo de ação.
  /// Sem nenhum desses, um [NoArt]: o botão de texto mostra só o texto.
  Widget icon({IconData? fallback, double? size}) {
    if (button.iconBase64?.isNotEmpty ?? false) {
      return base64Icon(button.iconBase64!);
    }
    if (button.iconName?.isNotEmpty ?? false) {
      return Icon(buttonIconData(button.iconName!), size: size);
    }
    if (fallback != null) return Icon(fallback, size: size);
    final schema = ActionCatalog.instance.find(type);
    if (schema != null && type != 'hotkey') {
      return Icon(schema.iconData, size: size);
    }
    return NoArt(size: size);
  }

  /// Monta o botão no estado certo: ativo pelo estado da ação ou pelo liga/desliga do
  /// botão. Ativo, o rótulo e o ícone do estado ativo (se definidos) substituem os normais.
  ///
  /// Com ícone (imagem ou glifo), o rótulo só aparece com "Mostrar nomes nos botões"
  /// ligado, ou com [keepLabel]: o texto que é informação (nome da cena, música
  /// tocando), não só o nome do botão.
  Widget tile({
    required bool active,
    required Widget icon,
    String? label,
    Color? activeColor,
    bool keepLabel = false,
  }) {
    final on = active || toggledOn;
    if (on && (button.activeIconBase64?.isNotEmpty ?? false)) {
      icon = base64Icon(button.activeIconBase64!);
    } else if (on && (button.activeIconName?.isNotEmpty ?? false)) {
      icon = Icon(buttonIconData(button.activeIconName!));
    }
    final text = on && (button.activeLabel?.isNotEmpty ?? false)
        ? button.activeLabel
        : label;
    final hasArt = !isEmptyArt(icon);
    return Builder(
      builder: (context) {
        final deck = DeckTheme.of(context);
        final hasText =
            text != null &&
            text.isNotEmpty &&
            (!hasArt || keepLabel || deck.showLabels);
        // Leitor de tela: botão de dois estados diz "ligado/desligado"; os outros dizem
        // só quando o estado está ativo (ex.: microfone mudo), sem inventar um
        // "desligado". O rótulo escondido continua sendo o nome do botão.
        return Semantics(
          toggled: button.toggle ? on : (on ? true : null),
          label: !hasText && text != null && text.isNotEmpty ? text : null,
          child: ActiveGlow(
            active: on,
            color: activeColor ?? this.activeColor,
            child: DeckTile(
              color: color,
              active: on,
              activeColor: activeColor ?? this.activeColor,
              onTap: onTap,
              onLongPress: onLongPress,
              // Rótulo e ícone crescem com o botão: num tablet ou no configurador o texto
              // não fica miúdo; num celular pequeno não estoura.
              child: LayoutBuilder(
                builder: (context, c) {
                  // A tecla squircle já tira 8% de respiro de cada lado: o lado da tecla
                  // inteira é o daqui dividido por 0,84.
                  final inner = c.maxWidth.isFinite && c.maxHeight.isFinite
                      ? (c.maxWidth < c.maxHeight ? c.maxWidth : c.maxHeight)
                      : 80.0;
                  final side = inner / 0.84;
                  final wide = c.maxWidth.isFinite &&
                      c.maxHeight.isFinite &&
                      hasArt &&
                      hasText &&
                      c.maxWidth > c.maxHeight * 1.45;
                  final scaler = MediaQuery.textScalerOf(context);
                  // Fator de escala de acessibilidade para evitar estouro vertical.
                  final textScale = (scaler.scale(14) / 14).clamp(1.0, 2.2);
                  // Regra do Relance: palavra nunca quebra no meio. Se a mais comprida
                  // não cabe na largura da tecla, a fonte encolhe (até 9) antes de ser
                  // cortada. Botão só de texto usa letra maior.
                  final preferred = (side * (hasArt ? 0.118 : 0.155)).clamp(
                    10.0,
                    20.0,
                  );
                  final labelWidth = wide
                      ? (c.maxWidth - inner * 0.85 - side * 0.12)
                          .clamp(24.0, c.maxWidth)
                      : c.maxWidth - 4;
                  var fontSize = !hasText || !c.maxWidth.isFinite
                      ? preferred
                      : fitWordsFontSize(
                          text,
                          preferred,
                          labelWidth,
                          scaler,
                        );
                  // Com texto grande de acessibilidade, limita a altura para caber com o ícone.
                  if (hasText && hasArt && !wide && c.maxHeight.isFinite) {
                    final maxLabelFont =
                        (c.maxHeight * 0.28 / (1.15 * textScale)).clamp(8.5, 20.0);
                    if (fontSize > maxLabelFont) fontSize = maxLabelFont;
                  }
                  // Glifo segue a proporção escolhida pelo usuário; menor quando divide com o nome.
                  final glyphBase = hasText && !wide
                      ? (textScale > 1.2 ? 0.30 : 0.35)
                      : DeckSquircleTile.glyphFraction;
                  final glyph = (side * glyphBase * deck.glyphScale).clamp(
                    16.0,
                    inner * (hasText && !wide ? 0.52 : 0.72),
                  );
                  // Ícone de app: bem maior que o glifo, encolhe suavemente se divide com o nome.
                  final artFactor = !hasText
                      ? 1.0
                      : wide
                          ? 0.80
                          : (textScale > 1.2 ? 0.56 : 0.65);
                  final art = (side * deck.appIconFraction * artFactor).clamp(
                    18.0,
                    inner * (hasText && !wide ? 0.70 : 0.94),
                  );
                  // Glifos de sistema ganham relevo sutil no estilo squircle, sem placa.
                  final Widget artChild =
                      deck.tileStyle == DeckTileStyle.squircle && icon is Icon
                          ? LiquidGlassGlyph(child: icon)
                          : icon;
                  final artWidget = DeckArtSize(
                    size: art,
                    child: IconTheme.merge(
                      data: IconThemeData(size: glyph),
                      child: artChild,
                    ),
                  );
                  final labelWidget = hasText
                      ? Text(
                          text,
                          textAlign: wide ? TextAlign.start : TextAlign.center,
                          style: TextStyle(
                            fontSize: fontSize,
                            fontWeight: FontWeight.w600,
                            height: 1.15,
                            letterSpacing: -0.1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          maxLines: hasArt
                              ? (textScale > 1.35 && !wide ? 1 : 2)
                              : 3,
                        )
                      : null;
                  if (wide && labelWidget != null) {
                    return Padding(
                      padding: EdgeInsets.symmetric(horizontal: side * 0.06),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          artWidget,
                          SizedBox(width: side * 0.09),
                          Expanded(child: labelWidget),
                        ],
                      ),
                    );
                  }
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (hasArt || !hasText)
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: artWidget,
                          ),
                        ),
                      if (labelWidget != null) ...[
                        if (hasArt) SizedBox(height: side * 0.05),
                        Flexible(
                          flex: hasArt ? 0 : 1,
                          child: labelWidget,
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  /// Sem desenho: o [NoArt] e o espaço vazio (tecla do teclado sem ícone).
  static bool isEmptyArt(Widget icon) =>
      icon is NoArt ||
      (icon is SizedBox && icon.child == null && icon.width == 0.0);

  /// Imagem quadrada que ocupa boa parte do botão (capa de jogo, de álbum).
  static Widget cover(
    String base64, {
    double fraction = 0.78,
    IconData fallback = Icons.image,
  }) {
    final bytes = LiquidGlassCache.decodeBase64(base64);
    if (bytes == null) return Icon(fallback);
    return LayoutBuilder(
      builder: (context, c) {
        // Botão grande (2×1) não é quadrado: a imagem não passa da altura disponível.
        final w = c.maxWidth.isFinite ? c.maxWidth * fraction : 64.0;
        final side = c.maxHeight.isFinite && c.maxHeight < w ? c.maxHeight : w;
        if (DeckTheme.of(context).tileStyle == DeckTileStyle.squircle) {
          return LiquidGlassIcon.memory(
            bytes,
            size: side,
            errorBuilder: (_) => Icon(fallback),
          );
        }
        return ClipRSuperellipse(
          borderRadius: BorderRadius.circular(
            AppleShapes.tileRadius(side) * 0.8,
          ),
          child: SizedBox(
            width: side,
            height: side,
            child: Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) => Icon(fallback),
            ),
          ),
        );
      },
    );
  }

  /// Imagem do usuário (ícone de app, logo): no estilo arredondado usa [LiquidGlassIcon]
  /// (placa de vidro para logos soltos, aro e brilho sem placa dobrada para ícones cheios);
  /// nos estilos antigos (sólido, contorno, moldura) mantém o recorte simples.
  static Widget base64Icon(String data) {
    final bytes = LiquidGlassCache.decodeBase64(data);
    if (bytes == null) return const Icon(Icons.broken_image);
    return Builder(
      builder: (context) {
        final deck = DeckTheme.of(context);
        final s =
            DeckArtSize.maybeOf(context) ??
            (IconTheme.of(context).size ?? 24) * 1.6;
        if (deck.tileStyle == DeckTileStyle.squircle) {
          return LiquidGlassIcon.memory(
            bytes,
            size: s,
            errorBuilder: (_) => const Icon(Icons.error, color: Colors.red),
          );
        }
        return ClipRSuperellipse(
          borderRadius: BorderRadius.circular(s * LiquidGlassIcon.radiusFactor),
          child: Image.memory(
            bytes,
            width: s,
            height: s,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
            gaplessPlayback: true,
            errorBuilder: (_, __, ___) =>
                const Icon(Icons.error, color: Colors.red),
          ),
        );
      },
    );
  }

  /// Tira o "data:image/...;base64," da frente, quando vem.
  static String stripDataUri(String data) =>
      data.startsWith('data:') ? data.substring(data.indexOf(',') + 1) : data;
}

/// Maior tamanho (até [preferred], no mínimo 9) em que a palavra mais longa de [text]
/// cabe em [maxWidth] numa linha só, em negrito médio (w600).
double fitWordsFontSize(
  String text,
  double preferred,
  double maxWidth,
  TextScaler scaler,
) {
  if (maxWidth <= 0) return preferred;
  final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
  double widest = 0;
  for (final w in words) {
    final tp = TextPainter(
      text: TextSpan(
        text: w,
        style: TextStyle(fontSize: preferred, fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    if (tp.width > widest) widest = tp.width;
  }
  if (widest <= maxWidth) return preferred;
  return (preferred * maxWidth / widest).clamp(9.0, preferred);
}

/// Botão sem ícone nenhum. Sem texto, aparece como a mão (o "toque aqui"); com
/// texto, o botão mostra só o texto.
class NoArt extends StatelessWidget {
  const NoArt({super.key, this.size});

  final double? size;

  @override
  Widget build(BuildContext context) => Icon(
    CupertinoIcons.hand_point_right_fill,
    size: size,
    color: DeckTile.foregroundOf(context).withValues(alpha: 0.54),
  );
}

/// Lado do ícone de app (imagem) dentro da tecla, para o [ButtonLook.base64Icon].
class DeckArtSize extends InheritedWidget {
  const DeckArtSize({super.key, required this.size, required super.child});

  final double size;

  static double? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DeckArtSize>()?.size;

  @override
  bool updateShouldNotify(DeckArtSize old) => old.size != size;
}
