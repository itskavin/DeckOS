import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Rolagem adaptada a cada plataforma: quique natural no iOS/macOS e rolagem firme
/// (sem brilho de overscroll) no Android, Windows, Linux e navegador.
class AppleScrollBehavior extends MaterialScrollBehavior {
  const AppleScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      return const BouncingScrollPhysics(parent: RangeMaintainingScrollPhysics());
    }
    return const ClampingScrollPhysics(parent: RangeMaintainingScrollPhysics());
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
