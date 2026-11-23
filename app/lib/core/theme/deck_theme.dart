import 'package:deckos/core/i18n/i18n.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'apple_tokens.dart';

/// Como os botões do deck são desenhados.
enum DeckTileStyle {
  /// Tecla escura de canto contínuo (squircle), com brilho no topo: o visual padrão,
  /// no jeito dos ícones de app da Apple.
  squircle('Arredondado'),

  /// Bloco preenchido com a cor do botão (o visual original).
  solid('Sólido'),

  /// Fundo escuro com borda na cor do botão.
  outline('Contorno'),

  /// Moldura dupla com canto chanfrado e triângulo na cor do botão.
  frame('Moldura');

  const DeckTileStyle(this.ptLabel);

  /// Rótulo em português (chave de tradução); a tela usa [label].
  final String ptLabel;
  String get label => tr(ptLabel);
}

/// Cores de status desenhadas dentro das teclas (medidores, uso de IA, timer) e a
/// paleta de cores de tecla. Ficam fixas nos tons originais: o tema moderno das
/// telas muda as cores de sistema, mas as teclas do deck não podem mudar junto.
abstract final class DeckTileColors {
  static const blue = Color(0xFF0A84FF);
  static const green = Color(0xFF30D158);
  static const red = Color(0xFFFF453A);
  static const orange = Color(0xFFFF9F0A);
  static const yellow = Color(0xFFFFD60A);
  static const pink = Color(0xFFFF375F);
  static const purple = Color(0xFFBF5AF2);
  static const indigo = Color(0xFF5E5CE6);
  static const teal = Color(0xFF40C8E0);
}

/// Tempos e molas originais das teclas do deck. As telas ganharam animações mais
/// curtas no tema moderno; as teclas mantêm as de antes para não mudar o toque.
abstract final class DeckTileMotion {
  /// Troca de estado da tecla (cor, brilho de ligada, slider).
  static const normal = Duration(milliseconds: 250);

  /// Barras de uso e medidores dentro da tecla.
  static const slow = Duration(milliseconds: 400);

  /// Mola da tecla voltando ao soltar (um quique curto).
  static final Curve snappy = SpringCurve(bounce: 0.15);
}

/// Fonte original dos rótulos das teclas: a do sistema (SF) no iPhone e no Mac nativos
/// e a Inter no resto. As telas usam a Inter em todo lugar; as teclas não mudam.
String deckTileFontFamily([TargetPlatform? platform]) {
  final p = platform ?? defaultTargetPlatform;
  if (!kIsWeb && (p == TargetPlatform.iOS || p == TargetPlatform.macOS)) {
    return Typography.material2021(platform: p).white.bodyMedium?.fontFamily ??
        'Inter';
  }
  return 'Inter';
}

/// Espaçamento entre as teclas da grade neste aparelho.
enum DeckSpacing {
  /// Teclas mais próximas e maiores, como um deck físico compacto.
  compact(
    'Compacto',
    gapRatio: 0.09,
    phoneMinGap: 8,
    tabletMinGap: 10,
    marginScale: 0.8,
  ),

  /// Respiro equilibrado entre as teclas (padrão).
  balanced(
    'Equilibrado',
    gapRatio: 0.145,
    phoneMinGap: 12,
    tabletMinGap: 16,
    marginScale: 1.0,
  ),

  /// Mais espaço em volta de cada tecla.
  spacious(
    'Amplo',
    gapRatio: 0.20,
    phoneMinGap: 16,
    tabletMinGap: 20,
    marginScale: 1.25,
  );

  const DeckSpacing(
    this.ptLabel, {
    required this.gapRatio,
    required this.phoneMinGap,
    required this.tabletMinGap,
    required this.marginScale,
  });

  /// Rótulo em português (chave de tradução); a tela usa [label].
  final String ptLabel;
  String get label => tr(ptLabel);

  /// Vão entre as teclas em fração do lado da tecla.
  final double gapRatio;

  /// Vão mínimo em celular e em tela maior.
  final double phoneMinGap;
  final double tabletMinGap;

  /// Multiplicador suave das margens externas da grade.
  final double marginScale;

  double minGapFor(Size screen) =>
      screen.shortestSide < 600 ? phoneMinGap : tabletMinGap;
}

/// Proporção dos ícones dentro da tecla neste aparelho.
enum DeckIconSize {
  small('Pequeno', appIconFraction: 0.66, glyphScale: 0.88),
  medium('Médio', appIconFraction: 0.76, glyphScale: 1.0),
  large('Grande', appIconFraction: 0.86, glyphScale: 1.12);

  const DeckIconSize(
    this.ptLabel, {
    required this.appIconFraction,
    required this.glyphScale,
  });

  /// Rótulo em português (chave de tradução); a tela usa [label].
  final String ptLabel;
  String get label => tr(ptLabel);

  /// Fração da tecla ocupada por um ícone de app (imagem).
  final double appIconFraction;

  /// Escala aplicada aos glifos de sistema.
  final double glyphScale;
}

/// Cores e estilo da grade do deck. Fica no [ThemeData] como extensão, então
/// qualquer widget lê com [DeckTheme.of].
@immutable
class DeckTheme extends ThemeExtension<DeckTheme> {
  const DeckTheme({
    required this.tileStyle,
    required this.background,
    required this.tileColor,
    required this.emptyTileColor,
    required this.outline,
    required this.foreground,
    required this.accent,
    required this.activeColor,
    this.showLabels = false,
    this.appIconFraction = 0.76,
    this.glyphScale = 1.0,
    this.spacing = DeckSpacing.balanced,
  });

  final DeckTileStyle tileStyle;

  /// Fundo atrás da grade.
  final Color background;

  /// Preenchimento do botão sem cor própria.
  final Color tileColor;

  /// Preenchimento do slot vazio.
  final Color emptyTileColor;

  /// Traço das molduras/contornos.
  final Color outline;

  /// Ícone e texto sobre o botão.
  final Color foreground;

  final Color accent;

  /// Cor de "ligado" quando o botão não define a sua.
  final Color activeColor;

  /// Nome embaixo do ícone. Desligado, só botão sem ícone mostra texto.
  final bool showLabels;

  /// Lado do ícone de app (imagem) em fração da tecla. O espelho do configurador usa
  /// uma escala proporcional para manter respiro em volta do ícone.
  final double appIconFraction;

  /// Fator aplicado aos glifos de sistema dentro da tecla.
  final double glyphScale;

  /// Espaçamento entre as teclas da grade neste aparelho.
  final DeckSpacing spacing;

  /// Fora do app (testes com um MaterialApp cru) a extensão não existe: deriva
  /// do esquema de cores para nunca quebrar.
  static DeckTheme of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<DeckTheme>() ??
        DeckTheme.fromScheme(theme.colorScheme);
  }

  factory DeckTheme.fromScheme(
    ColorScheme scheme, {
    DeckTileStyle style = DeckTileStyle.squircle,
  }) {
    final dark = scheme.brightness == Brightness.dark;
    if (style == DeckTileStyle.squircle) {
      // Preserva exatamente o visual atual das teclas do deck no escuro e no claro.
      return DeckTheme(
        tileStyle: style,
        background: dark ? Colors.black : const Color(0xFFF2F2F7),
        tileColor: dark ? const Color(0xFF141415) : Colors.white,
        emptyTileColor: dark
            ? const Color(0xFF0E0E10)
            : const Color(0xFFE5E5EA),
        outline: dark ? Colors.white : Colors.black,
        foreground: dark ? Colors.white : const Color(0xFF1C1C1E),
        accent: scheme.primary,
        activeColor: dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30),
      );
    }
    return DeckTheme(
      tileStyle: style,
      background: scheme.surface,
      tileColor: dark
          ? const Color(0xFF303030)
          : scheme.surfaceContainerHighest,
      emptyTileColor: scheme.surfaceContainerLow,
      outline: dark ? scheme.onSurface.withValues(alpha: 0.85) : scheme.outline,
      foreground: dark ? Colors.white : scheme.onSurface,
      accent: scheme.primary,
      activeColor: dark ? const Color(0xFFB71C1C) : const Color(0xFFD32F2F),
      showLabels: true,
    );
  }

  @override
  DeckTheme copyWith({
    DeckTileStyle? tileStyle,
    Color? background,
    Color? tileColor,
    Color? emptyTileColor,
    Color? outline,
    Color? foreground,
    Color? accent,
    Color? activeColor,
    bool? showLabels,
    double? appIconFraction,
    double? glyphScale,
    DeckSpacing? spacing,
  }) {
    return DeckTheme(
      tileStyle: tileStyle ?? this.tileStyle,
      background: background ?? this.background,
      tileColor: tileColor ?? this.tileColor,
      emptyTileColor: emptyTileColor ?? this.emptyTileColor,
      outline: outline ?? this.outline,
      foreground: foreground ?? this.foreground,
      accent: accent ?? this.accent,
      activeColor: activeColor ?? this.activeColor,
      showLabels: showLabels ?? this.showLabels,
      appIconFraction: appIconFraction ?? this.appIconFraction,
      glyphScale: glyphScale ?? this.glyphScale,
      spacing: spacing ?? this.spacing,
    );
  }

  @override
  DeckTheme lerp(DeckTheme? other, double t) {
    if (other == null) return this;
    return DeckTheme(
      tileStyle: t < 0.5 ? tileStyle : other.tileStyle,
      background: Color.lerp(background, other.background, t)!,
      tileColor: Color.lerp(tileColor, other.tileColor, t)!,
      emptyTileColor: Color.lerp(emptyTileColor, other.emptyTileColor, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      activeColor: Color.lerp(activeColor, other.activeColor, t)!,
      showLabels: t < 0.5 ? showLabels : other.showLabels,
      appIconFraction:
          appIconFraction + (other.appIconFraction - appIconFraction) * t,
      glyphScale: glyphScale + (other.glyphScale - glyphScale) * t,
      spacing: t < 0.5 ? spacing : other.spacing,
    );
  }
}
