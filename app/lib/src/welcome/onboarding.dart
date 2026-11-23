import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

/// Linha de recurso das telas de boas-vindas da Apple: ícone num quadradinho tingido,
/// título em negrito e o texto embaixo. [child] entra depois do texto (botões, endereço).
class OnboardingFeatureRow extends StatelessWidget {
  const OnboardingFeatureRow({
    super.key,
    required this.icon,
    required this.color,
    required this.title,
    this.body,
    this.child,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String? body;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppleSpacing.xl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppleRadii.md),
              border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: AppleSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: type.headline.copyWith(color: c.label)),
                if (body != null) ...[
                  const SizedBox(height: 2),
                  Text(body!, style: type.subheadline.copyWith(color: c.secondaryLabel)),
                ],
                if (child != null) ...[
                  const SizedBox(height: AppleSpacing.sm),
                  child!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Ícone do app no canto contínuo, como na tela de abertura.
class AppIconMark extends StatelessWidget {
  const AppIconMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: AppleShapes.squircle(AppleShapes.tileRadius(size)),
          shadows: AppleShadows.floating(Theme.of(context).brightness),
        ),
        // O logo já traz os próprios cantos transparentes: sem recorte.
        child: Image.asset('assets/images/logo.png', width: size, height: size),
      ),
    );
  }
}
