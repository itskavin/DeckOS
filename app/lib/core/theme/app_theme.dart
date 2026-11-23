import 'package:deckos/core/i18n/i18n.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'apple_tokens.dart';
import 'apple_typography.dart';
import 'deck_theme.dart';

/// Tema nomeado: define o visual escuro inteiro (fundo, superfícies, destaque e
/// estilo dos botões). O claro usa a paleta clara neutra com a cor de destaque.
@immutable
class ThemePreset {
  const ThemePreset({
    required this.id,
    required String name,
    required this.accent,
    required this.background,
    required this.surface,
    required this.tile,
    required this.outline,
    required this.tileStyle,
  }) : ptName = name;

  final String id;

  /// Nome em português (chave de tradução); a tela usa [name].
  final String ptName;
  String get name => tr(ptName);
  final Color accent;
  final Color background;
  final Color surface;
  final Color tile;
  final Color outline;
  final DeckTileStyle tileStyle;
}

/// Amarelo do logo (e do site): destaque de marca opcional do DeckOS.
const kBrandYellow = Color(0xFFFDD400);

/// Id do tema padrão (mantido para preservar preferências salvas dos usuários):
/// paleta neutra moderna (Zinc escuro/claro + azul moderno).
const kApplePresetId = 'apple';

const kThemePresets = <ThemePreset>[
  // O primeiro é o padrão (e o que vale quando a preferência salva some).
  ThemePreset(
    id: kApplePresetId,
    name: 'Padrão',
    accent: AppleSystemColors.blueDark,
    background: Color(0xFF000000),
    surface: Color(0xFF121215),
    // Preserva exatamente o visual atual das teclas do deck (grafite escuro sobre preto).
    tile: Color(0xFF141415),
    outline: Color(0xFFFFFFFF),
    tileStyle: DeckTileStyle.squircle,
  ),
  ThemePreset(
    id: 'classico',
    name: 'Clássico',
    // O amarelo do logo, sobre o quase-preto do site.
    accent: kBrandYellow,
    background: Color(0xFF0D0D0F),
    surface: Color(0xFF18181C),
    tile: Color(0xFF27272A),
    outline: Color(0xFFE4E4E7),
    tileStyle: DeckTileStyle.solid,
  ),
  ThemePreset(
    id: 'neon',
    name: 'Neon',
    accent: Color(0xFF38BDF8),
    background: Color(0xFF0B1020),
    surface: Color(0xFF141A2E),
    tile: Color(0xFF111729),
    outline: Color(0xFFDCE6FF),
    tileStyle: DeckTileStyle.frame,
  ),
  ThemePreset(
    id: 'oled',
    name: 'OLED',
    accent: Color(0xFFFFFFFF),
    background: Color(0xFF000000),
    surface: Color(0xFF0D0D0D),
    tile: Color(0xFF000000),
    outline: Color(0xFF8A8A8A),
    tileStyle: DeckTileStyle.outline,
  ),
  ThemePreset(
    id: 'ambar',
    name: 'Âmbar',
    accent: Color(0xFFF59E0B),
    background: Color(0xFF15120B),
    surface: Color(0xFF221D13),
    tile: Color(0xFF2E2719),
    outline: Color(0xFFFFE0A3),
    tileStyle: DeckTileStyle.solid,
  ),
  ThemePreset(
    id: 'synthwave',
    name: 'Synthwave',
    accent: Color(0xFFE879F9),
    background: Color(0xFF140A24),
    surface: Color(0xFF211338),
    tile: Color(0xFF1A0F2E),
    outline: Color(0xFFF3C6FF),
    tileStyle: DeckTileStyle.frame,
  ),
];

/// Cores oferecidas para trocar o destaque do tema (paleta moderna multiplataforma).
const kAccentChoices = <Color>[
  AppleSystemColors.blueDark, // azul
  kBrandYellow, // amarelo DeckOS
  AppleSystemColors.cyanDark, // ciano
  AppleSystemColors.mintDark, // esmeralda
  AppleSystemColors.greenDark, // verde
  AppleSystemColors.orangeDark, // laranja
  AppleSystemColors.redDark, // vermelho
  AppleSystemColors.pinkDark, // rosa
  AppleSystemColors.purpleDark, // roxo
  AppleSystemColors.indigoDark, // índigo
];

/// Cor escura -> equivalente de melhor contraste no tema claro.
const _lightVariants = <int, Color>{
  0xFF3B82F6: AppleSystemColors.blueLight,
  0xFF0A84FF: AppleSystemColors.blueLight,
  0xFF06B6D4: AppleSystemColors.cyanLight,
  0xFF64D2FF: AppleSystemColors.cyanLight,
  0xFF10B981: AppleSystemColors.mintLight,
  0xFF63E6E2: AppleSystemColors.mintLight,
  0xFF22C55E: AppleSystemColors.greenLight,
  0xFF30D158: AppleSystemColors.greenLight,
  0xFFF97316: AppleSystemColors.orangeLight,
  0xFFFF9F0A: AppleSystemColors.orangeLight,
  0xFFEF4444: AppleSystemColors.redLight,
  0xFFFF453A: AppleSystemColors.redLight,
  0xFFEC4899: AppleSystemColors.pinkLight,
  0xFFFF375F: AppleSystemColors.pinkLight,
  0xFFA855F7: AppleSystemColors.purpleLight,
  0xFFBF5AF2: AppleSystemColors.purpleLight,
  0xFF6366F1: AppleSystemColors.indigoLight,
  0xFF5E5CE6: AppleSystemColors.indigoLight,
};

ThemePreset presetById(String? id) => kThemePresets.firstWhere(
  (p) => p.id == id,
  orElse: () => kThemePresets.first,
);

/// Escolhas do usuário. Destaque e estilo nulos seguem o tema escolhido.
@immutable
class ThemeSettings {
  const ThemeSettings({
    this.presetId = kApplePresetId,
    this.mode = ThemeMode.dark,
    this.accent,
    this.tileStyle,
    this.showLabels,
    this.spacing = DeckSpacing.balanced,
    this.iconSize = DeckIconSize.medium,
  });

  final String presetId;
  final ThemeMode mode;
  final Color? accent;
  final DeckTileStyle? tileStyle;

  /// Nome embaixo do ícone nos botões do deck. Desligado, só botão sem ícone mostra
  /// texto. Nulo segue o estilo: o arredondado esconde, os estilos antigos mostram.
  final bool? showLabels;

  /// Espaçamento entre as teclas da grade neste aparelho.
  final DeckSpacing spacing;

  /// Escala dos ícones dentro da tecla neste aparelho.
  final DeckIconSize iconSize;

  ThemePreset get preset => presetById(presetId);
  Color get effectiveAccent => accent ?? preset.accent;
  DeckTileStyle get effectiveTileStyle => tileStyle ?? preset.tileStyle;
  bool get effectiveShowLabels =>
      showLabels ?? effectiveTileStyle != DeckTileStyle.squircle;

  ThemeSettings copyWith({
    String? presetId,
    ThemeMode? mode,
    Color? Function()? accent,
    DeckTileStyle? Function()? tileStyle,
    bool? Function()? showLabels,
    DeckSpacing? spacing,
    DeckIconSize? iconSize,
  }) {
    return ThemeSettings(
      presetId: presetId ?? this.presetId,
      mode: mode ?? this.mode,
      accent: accent != null ? accent() : this.accent,
      tileStyle: tileStyle != null ? tileStyle() : this.tileStyle,
      showLabels: showLabels != null ? showLabels() : this.showLabels,
      spacing: spacing ?? this.spacing,
      iconSize: iconSize ?? this.iconSize,
    );
  }
}

/// Monta o tema do app com design neutro moderno (inspirado em shadcn/ui), amigável
/// para Android, iOS e desktop: superfícies limpas com bordas de 1 px, tipografia Inter,
/// controles acessíveis e transições nativas de cada plataforma.
ThemeData buildAppTheme(ThemeSettings s, Brightness brightness) {
  final preset = s.preset;
  final accent = s.effectiveAccent;
  final style = s.effectiveTileStyle;
  final dark = brightness == Brightness.dark;
  final isDefault = preset.id == kApplePresetId;

  // No tema claro, garante contraste mínimo da cor de destaque sobre superfícies brancas.
  var primary = dark ? accent : (_lightVariants[accent.toARGB32()] ?? accent);
  if (!dark && primary.computeLuminance() > 0.4) {
    primary = HSLColor.fromColor(primary).withLightness(0.32).toColor();
  }

  Color step(double t) => Color.lerp(preset.background, preset.outline, t)!;
  var colors = dark
      ? AppleColors.dark(accent: primary)
      : AppleColors.light(accent: primary);
  if (dark && !isDefault) {
    colors = colors.copyWith(
      background: preset.background,
      groupedBackground: preset.background,
      secondaryGroupedBackground: preset.surface,
      tertiaryGroupedBackground: step(0.12),
      separator: preset.outline.withValues(alpha: 0.16),
      opaqueSeparator: step(0.22),
      barBackground: preset.surface.withValues(alpha: 0.92),
    );
  }

  final scaffold = colors.groupedBackground;
  final surface = colors.secondaryGroupedBackground;
  final secondaryText = colors.secondaryLabel;
  var scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: primary,
        onPrimary: colors.onAccent,
        error: colors.red,
        onError: Colors.white,
        surface: surface,
        onSurface: colors.label,
        onSurfaceVariant: secondaryText,
        outline: colors.opaqueSeparator,
        outlineVariant: colors.separator,
      );
  if (dark && !isDefault) {
    scheme = scheme.copyWith(
      surfaceContainerLowest: preset.background,
      surfaceContainerLow: step(0.04),
      surfaceContainer: step(0.07),
      surfaceContainerHigh: step(0.10),
      surfaceContainerHighest: step(0.14),
    );
  } else if (dark) {
    scheme = scheme.copyWith(
      surfaceContainerLowest: const Color(0xFF09090B),
      surfaceContainerLow: const Color(0xFF121215),
      surfaceContainer: const Color(0xFF18181B),
      surfaceContainerHigh: const Color(0xFF27272A),
      surfaceContainerHighest: const Color(0xFF3F3F46),
    );
  } else {
    scheme = scheme.copyWith(
      surfaceContainerLowest: const Color(0xFFFFFFFF),
      surfaceContainerLow: const Color(0xFFFAFAFA),
      surfaceContainer: const Color(0xFFF4F4F5),
      surfaceContainerHigh: const Color(0xFFE4E4E7),
      surfaceContainerHighest: const Color(0xFFD4D4D8),
    );
  }

  final DeckTheme deck;
  if (dark) {
    deck = DeckTheme(
      tileStyle: style,
      background: preset.background,
      tileColor: preset.tile,
      emptyTileColor: Color.lerp(preset.background, preset.tile, 0.6)!,
      outline: preset.outline,
      foreground: Colors.white,
      accent: accent,
      // Preserva exatamente o vermelho de estado ativo das teclas do deck.
      activeColor: isDefault ? const Color(0xFFFF453A) : const Color(0xFFB71C1C),
      showLabels: s.effectiveShowLabels,
      appIconFraction: s.iconSize.appIconFraction,
      glyphScale: s.iconSize.glyphScale,
      spacing: s.spacing,
    );
  } else {
    deck = DeckTheme.fromScheme(scheme, style: style).copyWith(
      showLabels: s.effectiveShowLabels,
      appIconFraction: s.iconSize.appIconFraction,
      glyphScale: s.iconSize.glyphScale,
      spacing: s.spacing,
    );
  }

  final family = appleFontFamily();
  final type = AppleTextStyles(fontFamily: family);
  final textTheme = type.toTextTheme().apply(
    bodyColor: colors.label,
    displayColor: colors.label,
  );

  final pressed = WidgetStateProperty.resolveWith<Color?>((states) {
    final ink = dark ? Colors.white : Colors.black;
    if (states.contains(WidgetState.pressed)) {
      return ink.withValues(alpha: 0.08);
    }
    if (states.contains(WidgetState.hovered)) {
      return ink.withValues(alpha: 0.04);
    }
    return null;
  });

  final mdShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppleRadii.md),
  );
  final smShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppleRadii.sm),
  );

  // Botões retangulares arredondados (shadcn/ui), altura de toque confortável (44 px).
  final buttonStyle = ButtonStyle(
    shape: WidgetStatePropertyAll(mdShape),
    minimumSize: const WidgetStatePropertyAll(Size(64, 44)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: AppleSpacing.md),
    ),
    textStyle: WidgetStatePropertyAll(
      type.subheadline.copyWith(fontWeight: FontWeight.w600),
    ),
    overlayColor: pressed,
    elevation: const WidgetStatePropertyAll(0),
    splashFactory: NoSplash.splashFactory,
  );

  final raised = dark ? colors.tertiaryGroupedBackground : Colors.white;
  OutlineInputBorder field(BorderSide side) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppleRadii.sm),
    borderSide: side,
  );

  return ThemeData(
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: family,
    textTheme: textTheme,
    scaffoldBackgroundColor: scaffold,
    canvasColor: scaffold,
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: colors.tertiaryFill,
    hoverColor: colors.label.withValues(alpha: 0.04),
    focusColor: primary.withValues(alpha: dark ? 0.25 : 0.16),
    dividerColor: colors.separator,
    // Transições adaptadas a cada plataforma (sem forçar estilo iOS no Android/Desktop).
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
        TargetPlatform.fuchsia: FadeUpwardsPageTransitionsBuilder(),
      },
    ),
    cupertinoOverrideTheme: NoDefaultCupertinoThemeData(
      brightness: brightness,
      primaryColor: primary,
      scaffoldBackgroundColor: scaffold,
      barBackgroundColor: colors.barBackground,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scaffold,
      foregroundColor: colors.label,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: type.headline.copyWith(color: colors.label),
      iconTheme: IconThemeData(color: colors.label),
      actionsIconTheme: IconThemeData(color: colors.label),
    ),
    filledButtonTheme: FilledButtonThemeData(style: buttonStyle),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: buttonStyle.copyWith(
        backgroundColor: WidgetStatePropertyAll(colors.tertiaryGroupedBackground),
        foregroundColor: WidgetStatePropertyAll(colors.label),
        side: WidgetStatePropertyAll(BorderSide(color: colors.separator)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: buttonStyle.copyWith(
        side: WidgetStatePropertyAll(BorderSide(color: colors.opaqueSeparator)),
        foregroundColor: WidgetStatePropertyAll(colors.label),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(primary),
        textStyle: WidgetStatePropertyAll(
          type.subheadline.copyWith(fontWeight: FontWeight.w500),
        ),
        overlayColor: pressed,
        shape: WidgetStatePropertyAll(smShape),
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        overlayColor: pressed,
        shape: WidgetStatePropertyAll(smShape),
        splashFactory: NoSplash.splashFactory,
      ),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: primary,
      foregroundColor: colors.onAccent,
      elevation: 2,
      highlightElevation: 2,
      shape: mdShape,
      splashColor: Colors.transparent,
    ),
    // Switch moderno com cor de destaque no trilho ativo e borda limpa no inativo.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (st) => st.contains(WidgetState.selected)
            ? colors.onAccent
            : (dark ? const Color(0xFFE4E4E7) : Colors.white),
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (st) => st.contains(WidgetState.selected) ? primary : colors.fill,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (st) => st.contains(WidgetState.selected)
            ? Colors.transparent
            : colors.opaqueSeparator,
      ),
      trackOutlineWidth: const WidgetStatePropertyAll(1),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      fillColor: WidgetStateProperty.resolveWith(
        (st) =>
            st.contains(WidgetState.selected) ? primary : Colors.transparent,
      ),
      checkColor: WidgetStatePropertyAll(colors.onAccent),
      side: BorderSide(color: colors.opaqueSeparator, width: 1.5),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    radioTheme: RadioThemeData(
      fillColor: WidgetStateProperty.resolveWith(
        (st) =>
            st.contains(WidgetState.selected) ? primary : colors.tertiaryLabel,
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    // Slider limpo e preciso.
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: primary,
      inactiveTrackColor: colors.fill,
      thumbColor: dark ? const Color(0xFFFAFAFA) : Colors.white,
      overlayColor: primary.withValues(alpha: 0.14),
      thumbShape: const RoundSliderThumbShape(
        enabledThumbRadius: 10,
        elevation: 2,
        pressedElevation: 3,
      ),
      trackShape: const RoundedRectSliderTrackShape(),
      activeTickMarkColor: Colors.transparent,
      inactiveTickMarkColor: Colors.transparent,
      showValueIndicator: ShowValueIndicator.never,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: colors.fill,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 4,
      borderRadius: BorderRadius.circular(2),
    ),
    // Cartão shadcn: superfície limpa com borda nítida de 1 px e sem sombra pesada.
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleRadii.lg),
        side: BorderSide(color: colors.separator),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: colors.secondaryLabel,
      textColor: colors.label,
      titleTextStyle: type.body.copyWith(color: colors.label),
      subtitleTextStyle: type.footnote.copyWith(color: secondaryText),
      leadingAndTrailingTextStyle: type.subheadline.copyWith(color: secondaryText),
      selectedColor: primary,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppleSpacing.md),
      minLeadingWidth: 24,
      horizontalTitleGap: AppleSpacing.sm,
    ),
    expansionTileTheme: const ExpansionTileThemeData(
      shape: Border(),
      collapsedShape: Border(),
    ),
    dividerTheme: DividerThemeData(
      color: colors.separator,
      thickness: 1,
      space: 1,
    ),
    // Campo moderno: borda nítida de 1 px em repouso e anel de destaque no foco.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? colors.tertiaryGroupedBackground : Colors.white,
      hintStyle: TextStyle(color: colors.tertiaryLabel),
      labelStyle: TextStyle(color: colors.secondaryLabel),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppleSpacing.sm,
        vertical: AppleSpacing.sm,
      ),
      border: field(BorderSide(color: colors.separator)),
      enabledBorder: field(BorderSide(color: colors.separator)),
      disabledBorder: field(BorderSide(color: colors.separator.withValues(alpha: 0.5))),
      focusedBorder: field(BorderSide(color: primary, width: 1.5)),
      errorBorder: field(BorderSide(color: colors.red)),
      focusedErrorBorder: field(BorderSide(color: colors.red, width: 1.5)),
    ),
    chipTheme: ChipThemeData(
      shape: smShape,
      side: BorderSide(color: colors.separator),
      showCheckmark: false,
      color: WidgetStateProperty.resolveWith(
        (st) => st.contains(WidgetState.selected) ? primary : colors.tertiaryFill,
      ),
      labelStyle: type.footnote.copyWith(
        fontWeight: FontWeight.w500,
        color: WidgetStateColor.resolveWith(
          (st) => st.contains(WidgetState.selected)
              ? colors.onAccent
              : colors.label,
        ),
      ),
      iconTheme: IconThemeData(color: colors.label, size: 16),
      padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.xs),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected)
              ? (dark ? const Color(0xFF27272A) : Colors.white)
              : colors.tertiaryFill,
        ),
        foregroundColor: WidgetStatePropertyAll(colors.label),
        side: WidgetStatePropertyAll(BorderSide(color: colors.separator)),
        shape: WidgetStatePropertyAll(smShape),
        overlayColor: pressed,
        textStyle: WidgetStatePropertyAll(
          type.footnote.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.barBackground,
      surfaceTintColor: Colors.transparent,
      indicatorColor: primary.withValues(alpha: dark ? 0.16 : 0.12),
      elevation: 0,
      height: 62,
      iconTheme: WidgetStateProperty.resolveWith(
        (st) => IconThemeData(
          color: st.contains(WidgetState.selected) ? primary : colors.secondaryLabel,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith(
        (st) => type.caption1.copyWith(
          fontWeight: st.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: st.contains(WidgetState.selected) ? primary : colors.secondaryLabel,
        ),
      ),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: Colors.transparent,
      indicatorColor: primary.withValues(alpha: dark ? 0.16 : 0.12),
      selectedIconTheme: IconThemeData(color: primary),
      unselectedIconTheme: IconThemeData(color: colors.secondaryLabel),
      selectedLabelTextStyle: type.caption1.copyWith(
        color: primary,
        fontWeight: FontWeight.w600,
      ),
      unselectedLabelTextStyle: type.caption1.copyWith(color: colors.secondaryLabel),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: colors.label,
      unselectedLabelColor: secondaryText,
      indicatorColor: primary,
      dividerColor: colors.separator,
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      splashFactory: NoSplash.splashFactory,
      labelStyle: type.subheadline.copyWith(fontWeight: FontWeight.w600),
      unselectedLabelStyle: type.subheadline,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: raised,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleRadii.lg),
        side: BorderSide(color: colors.separator),
      ),
      titleTextStyle: type.title3.copyWith(color: colors.label),
      contentTextStyle: type.subheadline.copyWith(color: colors.secondaryLabel),
      barrierColor: Colors.black.withValues(alpha: dark ? 0.65 : 0.45),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      modalBackgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      modalElevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppleRadii.sheet),
        ),
        side: BorderSide(color: colors.separator),
      ),
      showDragHandle: true,
      dragHandleColor: colors.opaqueSeparator,
      dragHandleSize: const Size(36, 4),
      modalBarrierColor: Colors.black.withValues(alpha: dark ? 0.60 : 0.40),
      clipBehavior: Clip.antiAlias,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: raised,
      surfaceTintColor: Colors.transparent,
      elevation: 6,
      shadowColor: Colors.black.withValues(alpha: dark ? 0.45 : 0.14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleRadii.md),
        side: BorderSide(color: colors.separator),
      ),
      textStyle: type.subheadline.copyWith(color: colors.label),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(raised),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide(color: colors.separator)),
        shape: WidgetStatePropertyAll(mdShape),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF27272A) : const Color(0xFF18181B),
        borderRadius: BorderRadius.circular(AppleRadii.xs),
        border: Border.all(color: dark ? const Color(0xFF3F3F46) : Colors.transparent),
      ),
      textStyle: type.caption1.copyWith(color: const Color(0xFFFAFAFA)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(3),
      thumbColor: WidgetStatePropertyAll(colors.tertiaryLabel.withValues(alpha: 0.45)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: dark ? colors.tertiaryGroupedBackground : const Color(0xFF18181B),
      contentTextStyle: type.subheadline.copyWith(color: const Color(0xFFFAFAFA)),
      actionTextColor: dark ? primary : const Color(0xFF60A5FA),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleRadii.md),
        side: BorderSide(color: dark ? colors.separator : Colors.transparent),
      ),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    extensions: [deck, colors],
  );
}

/// builder do MaterialApp: em tela larga (configurador no navegador), o aviso de baixo
/// tem largura de aviso, centralizado, em vez de uma faixa de ponta a ponta.
Widget narrowSnackBars(BuildContext context, Widget? child) {
  if (MediaQuery.sizeOf(context).width < 640) return child!;
  final t = Theme.of(context);
  return Theme(
    data: t.copyWith(snackBarTheme: t.snackBarTheme.copyWith(width: 480)),
    child: child!,
  );
}
