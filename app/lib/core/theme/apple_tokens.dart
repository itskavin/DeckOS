import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Paleta semântica moderna e multiplataforma (inspirada em shadcn/ui e Zinc),
/// com variantes calibradas para contraste nos modos claro e escuro.
/// Para cores que mudam com o tema (fundos, superfícies, textos, bordas) use [AppleColors.of].
abstract final class AppleSystemColors {
  static const blueDark = Color(0xFF3B82F6);
  static const blueLight = Color(0xFF2563EB);
  static const greenDark = Color(0xFF22C55E);
  static const greenLight = Color(0xFF16A34A);
  static const redDark = Color(0xFFEF4444);
  static const redLight = Color(0xFFDC2626);
  static const orangeDark = Color(0xFFF97316);
  static const orangeLight = Color(0xFFEA580C);
  static const yellowDark = Color(0xFFEAB308);
  static const yellowLight = Color(0xFFCA8A04);
  static const pinkDark = Color(0xFFEC4899);
  static const pinkLight = Color(0xFFDB2777);
  static const purpleDark = Color(0xFFA855F7);
  static const purpleLight = Color(0xFF9333EA);
  static const indigoDark = Color(0xFF6366F1);
  static const indigoLight = Color(0xFF4F46E5);
  static const tealDark = Color(0xFF14B8A6);
  static const tealLight = Color(0xFF0D9488);
  static const mintDark = Color(0xFF10B981);
  static const mintLight = Color(0xFF059669);
  static const cyanDark = Color(0xFF06B6D4);
  static const cyanLight = Color(0xFF0891B2);
  static const grayDark = Color(0xFF71717A);
  static const grayLight = Color(0xFF71717A);
}

/// Paleta semântica neutra (fundos, cartões, bordas, textos e preenchimentos) mais
/// as cores de status já resolvidas para o brilho atual. Fica no [ThemeData] como
/// extensão: leia com `AppleColors.of(context)`.
@immutable
class AppleColors extends ThemeExtension<AppleColors> {
  const AppleColors({
    required this.brightness,
    required this.background,
    required this.groupedBackground,
    required this.secondaryGroupedBackground,
    required this.tertiaryGroupedBackground,
    required this.separator,
    required this.opaqueSeparator,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.quaternaryLabel,
    required this.fill,
    required this.secondaryFill,
    required this.tertiaryFill,
    required this.barBackground,
    required this.accent,
    required this.onAccent,
    required this.blue,
    required this.green,
    required this.red,
    required this.orange,
    required this.yellow,
    required this.pink,
    required this.purple,
    required this.indigo,
    required this.teal,
    required this.gray,
  });

  final Brightness brightness;

  /// Fundo principal da aplicação (Zinc 950 no escuro, branco no claro).
  final Color background;

  /// Fundo das telas de lista e configurações (Zinc 950 no escuro, Zinc 50 no claro).
  final Color groupedBackground;

  /// Cartões e grupos sobre o fundo (Zinc 900/950 elevado no escuro, branco no claro).
  final Color secondaryGroupedBackground;

  /// Um degrau acima dos cartões: campos, popovers, diálogos, células aninhadas.
  final Color tertiaryGroupedBackground;

  /// Borda sutil de cartões e divisores (Zinc 800 no escuro, Zinc 200 no claro).
  final Color separator;

  /// Borda interativa de maior contraste (Zinc 700 no escuro, Zinc 300 no claro).
  final Color opaqueSeparator;

  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color quaternaryLabel;

  /// Preenchimentos neutros (trilho de controles, fundos de hover, chips inativos).
  final Color fill;
  final Color secondaryFill;
  final Color tertiaryFill;

  /// Fundo das barras de navegação e cabeçalhos (translúcido discreto).
  final Color barBackground;

  /// Cor de destaque do app; padrão azul moderno.
  final Color accent;

  /// Texto/ícone legível sobre [accent].
  final Color onAccent;

  final Color blue;
  final Color green;
  final Color red;
  final Color orange;
  final Color yellow;
  final Color pink;
  final Color purple;
  final Color indigo;
  final Color teal;
  final Color gray;

  bool get isDark => brightness == Brightness.dark;

  /// Paleta escura neutra (Zinc), com o destaque escolhido.
  factory AppleColors.dark({Color accent = AppleSystemColors.blueDark}) {
    return AppleColors(
      brightness: Brightness.dark,
      background: const Color(0xFF09090B),
      groupedBackground: const Color(0xFF09090B),
      secondaryGroupedBackground: const Color(0xFF121215),
      tertiaryGroupedBackground: const Color(0xFF18181B),
      separator: const Color(0xFF27272A),
      opaqueSeparator: const Color(0xFF3F3F46),
      label: const Color(0xFFFAFAFA),
      secondaryLabel: const Color(0xFFA1A1AA),
      tertiaryLabel: const Color(0xFF71717A),
      quaternaryLabel: const Color(0xFF52525B),
      fill: const Color(0xFF27272A),
      secondaryFill: const Color(0xFF1F1F23),
      tertiaryFill: const Color(0xFF18181B),
      barBackground: const Color(0xEB09090B),
      accent: accent,
      onAccent: onColor(accent),
      blue: AppleSystemColors.blueDark,
      green: AppleSystemColors.greenDark,
      red: AppleSystemColors.redDark,
      orange: AppleSystemColors.orangeDark,
      yellow: AppleSystemColors.yellowDark,
      pink: AppleSystemColors.pinkDark,
      purple: AppleSystemColors.purpleDark,
      indigo: AppleSystemColors.indigoDark,
      teal: AppleSystemColors.tealDark,
      gray: AppleSystemColors.grayDark,
    );
  }

  /// Paleta clara neutra (Zinc), com o destaque escolhido.
  factory AppleColors.light({Color accent = AppleSystemColors.blueLight}) {
    return AppleColors(
      brightness: Brightness.light,
      background: const Color(0xFFFFFFFF),
      groupedBackground: const Color(0xFFFAFAFA),
      secondaryGroupedBackground: const Color(0xFFFFFFFF),
      tertiaryGroupedBackground: const Color(0xFFF4F4F5),
      separator: const Color(0xFFE4E4E7),
      opaqueSeparator: const Color(0xFFD4D4D8),
      label: const Color(0xFF09090B),
      secondaryLabel: const Color(0xFF52525B),
      tertiaryLabel: const Color(0xFF71717A),
      quaternaryLabel: const Color(0xFFA1A1AA),
      fill: const Color(0xFFE4E4E7),
      secondaryFill: const Color(0xFFF4F4F5),
      tertiaryFill: const Color(0xFFF4F4F5),
      barBackground: const Color(0xF0FFFFFF),
      accent: accent,
      onAccent: onColor(accent),
      blue: AppleSystemColors.blueLight,
      green: AppleSystemColors.greenLight,
      red: AppleSystemColors.redLight,
      orange: AppleSystemColors.orangeLight,
      yellow: AppleSystemColors.yellowLight,
      pink: AppleSystemColors.pinkLight,
      purple: AppleSystemColors.purpleLight,
      indigo: AppleSystemColors.indigoLight,
      teal: AppleSystemColors.tealLight,
      gray: AppleSystemColors.grayLight,
    );
  }

  /// Fora do app (testes com um MaterialApp cru) a extensão não existe: usa a
  /// paleta do brilho atual, com o primário do esquema como destaque.
  static AppleColors of(BuildContext context) {
    final theme = Theme.of(context);
    final ext = theme.extension<AppleColors>();
    if (ext != null) return ext;
    final accent = theme.colorScheme.primary;
    return theme.brightness == Brightness.dark
        ? AppleColors.dark(accent: accent)
        : AppleColors.light(accent: accent);
  }

  /// Preto ou branco, o que for legível sobre [c].
  static Color onColor(Color c) =>
      c.computeLuminance() > 0.45 ? const Color(0xFF09090B) : Colors.white;

  @override
  AppleColors copyWith({
    Color? background,
    Color? groupedBackground,
    Color? secondaryGroupedBackground,
    Color? tertiaryGroupedBackground,
    Color? separator,
    Color? opaqueSeparator,
    Color? barBackground,
    Color? accent,
  }) {
    final a = accent ?? this.accent;
    return AppleColors(
      brightness: brightness,
      background: background ?? this.background,
      groupedBackground: groupedBackground ?? this.groupedBackground,
      secondaryGroupedBackground:
          secondaryGroupedBackground ?? this.secondaryGroupedBackground,
      tertiaryGroupedBackground:
          tertiaryGroupedBackground ?? this.tertiaryGroupedBackground,
      separator: separator ?? this.separator,
      opaqueSeparator: opaqueSeparator ?? this.opaqueSeparator,
      label: label,
      secondaryLabel: secondaryLabel,
      tertiaryLabel: tertiaryLabel,
      quaternaryLabel: quaternaryLabel,
      fill: fill,
      secondaryFill: secondaryFill,
      tertiaryFill: tertiaryFill,
      barBackground: barBackground ?? this.barBackground,
      accent: a,
      onAccent: accent != null ? onColor(a) : onAccent,
      blue: blue,
      green: green,
      red: red,
      orange: orange,
      yellow: yellow,
      pink: pink,
      purple: purple,
      indigo: indigo,
      teal: teal,
      gray: gray,
    );
  }

  @override
  AppleColors lerp(AppleColors? other, double t) {
    if (other == null) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppleColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      background: l(background, other.background),
      groupedBackground: l(groupedBackground, other.groupedBackground),
      secondaryGroupedBackground: l(
        secondaryGroupedBackground,
        other.secondaryGroupedBackground,
      ),
      tertiaryGroupedBackground: l(
        tertiaryGroupedBackground,
        other.tertiaryGroupedBackground,
      ),
      separator: l(separator, other.separator),
      opaqueSeparator: l(opaqueSeparator, other.opaqueSeparator),
      label: l(label, other.label),
      secondaryLabel: l(secondaryLabel, other.secondaryLabel),
      tertiaryLabel: l(tertiaryLabel, other.tertiaryLabel),
      quaternaryLabel: l(quaternaryLabel, other.quaternaryLabel),
      fill: l(fill, other.fill),
      secondaryFill: l(secondaryFill, other.secondaryFill),
      tertiaryFill: l(tertiaryFill, other.tertiaryFill),
      barBackground: l(barBackground, other.barBackground),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      blue: l(blue, other.blue),
      green: l(green, other.green),
      red: l(red, other.red),
      orange: l(orange, other.orange),
      yellow: l(yellow, other.yellow),
      pink: l(pink, other.pink),
      purple: l(purple, other.purple),
      indigo: l(indigo, other.indigo),
      teal: l(teal, other.teal),
      gray: l(gray, other.gray),
    );
  }
}

/// Escala de espaçamento (múltiplos de 4). Use estes nomes em vez de números soltos.
abstract final class AppleSpacing {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;

  /// Margem lateral padrão de uma tela.
  static const double screen = 16;
}

/// Raios de canto inspirados em shadcn/ui: definidos, limpos e multiplataforma.
abstract final class AppleRadii {
  /// Badge pequeno, chip de ícone de uma linha.
  static const double xs = 6;
  static const double sm = 8;

  /// Botões, campos e cartões compactos.
  static const double md = 10;
  static const double lg = 12;

  /// Painéis grandes e janelas.
  static const double xl = 16;

  /// Topo das folhas (sheets).
  static const double sheet = 16;

  /// Fração do lado da tecla usada como raio: preserva o visual atual das teclas do deck.
  static const double tileFactor = 0.24;
}

/// Formas de canto limpo. Mantém o superelipse suave para teclas e superfícies.
abstract final class AppleShapes {
  /// Borda arredondada suave de raio [radius]; use em `ShapeDecoration`, botões,
  /// cartões e diálogos.
  static RoundedSuperellipseBorder squircle(
    double radius, {
    BorderSide side = BorderSide.none,
  }) => RoundedSuperellipseBorder(
    borderRadius: BorderRadius.circular(radius),
    side: side,
  );

  /// Só os cantos de cima arredondados (folhas que sobem da base).
  static RoundedSuperellipseBorder topSquircle(
    double radius, {
    BorderSide side = BorderSide.none,
  }) => RoundedSuperellipseBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
    side: side,
  );

  /// Raio de uma tecla do deck de lado [side].
  static double tileRadius(double side) => side * AppleRadii.tileFactor;

  /// Linha fina de 0,5 px lógico (preserva o traço fino nas teclas vazias do deck).
  static BorderSide hairline(Color color) => BorderSide(color: color, width: 0.5);
}

/// Sombras suaves para cartões, elementos flutuantes e teclas do deck.
abstract final class AppleShadows {
  /// Cartões e teclas sobre fundo claro ou escuro.
  static List<BoxShadow> card(Brightness b) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: b == Brightness.dark ? 0.35 : 0.06),
      blurRadius: 12,
      offset: const Offset(0, 4),
    ),
  ];

  /// Elementos que flutuam (menus, folhas, popovers).
  static List<BoxShadow> floating(Brightness b) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: b == Brightness.dark ? 0.45 : 0.10),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
  ];

  /// Tecla do deck: sombra curta original para separar do fundo escuro.
  static const tile = [
    BoxShadow(color: Color(0x66000000), blurRadius: 6, offset: Offset(0, 3)),
  ];
}

/// Tempos e curvas de animação responsivas, respeitando "reduzir movimento".
abstract final class AppleMotion {
  /// Resposta imediata ao toque.
  static const fast = Duration(milliseconds: 120);

  /// Troca de estado (ligado/desligado, página, visibilidade de controles).
  static const normal = Duration(milliseconds: 220);

  /// Entrada de folhas e painéis.
  static const slow = Duration(milliseconds: 320);

  /// Mola amortecida sem quique.
  static final Curve smooth = SpringCurve(bounce: 0);

  /// Mola rápida com resposta tátil leve.
  static final Curve snappy = SpringCurve(bounce: 0.12);

  /// Mola com leve realce para indicadores e confirmações.
  static final Curve bouncy = SpringCurve(bounce: 0.24);

  /// Saída suave.
  static const Curve easeOut = Curves.easeOutCubic;

  /// Duração respeitando "reduzir movimento" do sistema: zero quando desligado.
  static Duration of(BuildContext context, Duration d) =>
      (MediaQuery.maybeDisableAnimationsOf(context) ?? false)
      ? Duration.zero
      : d;
}

/// Curva de mola normalizada para 0..1 dentro da duração da animação.
class SpringCurve extends Curve {
  SpringCurve({this.bounce = 0})
    : _sim = SpringSimulation(
        SpringDescription.withDurationAndBounce(
          duration: const Duration(milliseconds: 1000),
          bounce: bounce,
        ),
        0,
        1,
        0,
      );

  final double bounce;
  final SpringSimulation _sim;

  @override
  double transformInternal(double t) {
    final v = _sim.x(t);
    return lerpDouble(v, 1, t * t * t)!;
  }
}
