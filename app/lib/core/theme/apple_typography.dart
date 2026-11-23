import 'package:flutter/material.dart';

/// Família de fonte consistente em todas as plataformas (Android, iOS, desktop e web):
/// usa a fonte 'Inter' empacotada no app, com aparência neutra e legível.
String? appleFontFamily([TargetPlatform? platform]) => 'Inter';

/// Escala tipográfica moderna (inspirada em shadcn/ui + Inter), limpa e escalável
/// para acessibilidade. Os estilos não trazem cor: herdam a do tema.
/// Leia com `AppleTextStyles.of(context)`.
@immutable
class AppleTextStyles {
  const AppleTextStyles({this.fontFamily});

  final String? fontFamily;

  /// Estilos com a fonte do tema atual.
  static AppleTextStyles of(BuildContext context) => AppleTextStyles(
    fontFamily: Theme.of(context).textTheme.bodyLarge?.fontFamily,
  );

  TextStyle get largeTitle => _style(28, FontWeight.w700, 34);
  TextStyle get title1 => _style(24, FontWeight.w700, 30);
  TextStyle get title2 => _style(20, FontWeight.w600, 26);
  TextStyle get title3 => _style(18, FontWeight.w600, 24);
  TextStyle get headline => _style(16, FontWeight.w600, 22);
  TextStyle get body => _style(15, FontWeight.w400, 22);
  TextStyle get callout => _style(15, FontWeight.w500, 20);
  TextStyle get subheadline => _style(14, FontWeight.w400, 20);
  TextStyle get footnote => _style(13, FontWeight.w400, 18);
  TextStyle get caption1 => _style(12, FontWeight.w500, 16);
  TextStyle get caption2 => _style(11, FontWeight.w500, 14);

  TextStyle _style(double size, FontWeight weight, double lineHeight) {
    return TextStyle(
      fontFamily: fontFamily,
      fontSize: size,
      fontWeight: weight,
      height: lineHeight / size,
      letterSpacing: tracking(size, sf: isSystemFont(fontFamily)),
      leadingDistribution: TextLeadingDistribution.even,
    );
  }

  /// Verifica se a fonte ativa é uma fonte de sistema da Apple.
  static bool isSystemFont(String? family) =>
      family == null ||
      family.startsWith('.') ||
      family.startsWith('CupertinoSystem');

  /// Espaçamento entre letras por tamanho (Inter com tracking limpo para títulos).
  static double tracking(double size, {required bool sf}) {
    if (sf) {
      if (size >= 28) return 0.2;
      if (size >= 20) return 0.1;
      if (size >= 16) return -0.25;
      if (size >= 14) return -0.15;
      return 0;
    }
    if (size >= 24) return size * -0.025;
    if (size >= 18) return size * -0.018;
    if (size >= 15) return size * -0.01;
    if (size >= 13) return -0.05;
    return 0;
  }

  /// Mapeamento da escala nos papéis do Material para consistência em todos os widgets.
  TextTheme toTextTheme() {
    return TextTheme(
      displayLarge: largeTitle.copyWith(fontSize: 42, height: 1.12),
      displayMedium: largeTitle.copyWith(fontSize: 36, height: 1.12),
      displaySmall: largeTitle,
      headlineLarge: largeTitle,
      headlineMedium: title1,
      headlineSmall: title2,
      titleLarge: title3,
      titleMedium: headline,
      titleSmall: subheadline.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: body,
      bodyMedium: subheadline,
      bodySmall: footnote,
      labelLarge: callout.copyWith(fontWeight: FontWeight.w600),
      labelMedium: footnote.copyWith(fontWeight: FontWeight.w500),
      labelSmall: caption2.copyWith(fontWeight: FontWeight.w500),
    );
  }
}
