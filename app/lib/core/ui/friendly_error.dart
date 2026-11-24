import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../i18n/i18n.dart';
import '../theme/apple_tokens.dart';
import '../theme/apple_typography.dart';

/// Mensagem de erro para gente, não para desenvolvedor: diz o que aconteceu e o que fazer.
/// Se o PC mandou um texto próprio ({"error": "..."}), ele vale (já vem traduzido).
String friendlyError(Object error) {
  if (error is DioException) {
    if (error.toString().contains('HandshakeException') || error.type == DioExceptionType.badCertificate) {
      return tr('Cannot verify this PC. Update the PC companion, open a fresh pairing code on that PC, and try again. A changed certificate requires a new scan.');
    }
    final data = error.response?.data;
    if (data is Map && data['error'] is String) return data['error'] as String;
    final code = error.response?.statusCode;
    if (code == 401 || code == 403) {
      return tr('O PC recusou a chave deste aparelho. Refaça o pareamento.');
    }
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.sendTimeout:
        return tr('O PC demorou demais para responder. Tente de novo.');
      case DioExceptionType.connectionError:
        return tr(
          'O PC não respondeu. Confira se o DeckOS está aberto nele e se os dois estão na mesma rede.',
        );
      default:
        break;
    }
    if (code != null && code >= 500) {
      return tr(
        'O DeckOS do PC teve um problema. Tente de novo; se repetir, reinicie o DeckOS no PC.',
      );
    }
  }
  return tr('Algo deu errado. Tente de novo.');
}

/// Tom de um [AppleBanner]: muda a cor e o ícone.
enum BannerTone { info, success, warning, error }

/// Aviso em linha moderno (estilo Alert do shadcn/ui): superfície tingida sutil, borda
/// de 1 px na cor do tom, ícone limpo, título, explicação e ação opcional.
class AppleBanner extends StatelessWidget {
  const AppleBanner({
    super.key,
    required this.message,
    this.title,
    this.tone = BannerTone.info,
    this.icon,
    this.actionLabel,
    this.onAction,
    this.onDismiss,
    this.margin = EdgeInsets.zero,
  });

  /// Banner de erro com o texto de [friendlyError] e, com [onRetry], "Tentar de novo".
  factory AppleBanner.error(
    Object error, {
    Key? key,
    String? title,
    VoidCallback? onRetry,
    VoidCallback? onDismiss,
    EdgeInsetsGeometry margin = EdgeInsets.zero,
  }) => AppleBanner(
    key: key,
    tone: BannerTone.error,
    title: title,
    message: friendlyError(error),
    actionLabel: onRetry == null ? null : tr('Tentar de novo'),
    onAction: onRetry,
    onDismiss: onDismiss,
    margin: margin,
  );

  final String message;
  final String? title;
  final BannerTone tone;

  /// Troca o ícone padrão do tom.
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Mostra o "x" para fechar.
  final VoidCallback? onDismiss;
  final EdgeInsetsGeometry margin;

  static Color toneColor(AppleColors c, BannerTone tone) => switch (tone) {
    BannerTone.info => c.blue,
    BannerTone.success => c.green,
    BannerTone.warning => c.orange,
    BannerTone.error => c.red,
  };

  static IconData toneIcon(BannerTone tone) => switch (tone) {
    BannerTone.info => Icons.info_outline_rounded,
    BannerTone.success => Icons.check_circle_outline_rounded,
    BannerTone.warning => Icons.warning_amber_rounded,
    BannerTone.error => Icons.error_outline_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final color = toneColor(c, tone);
    final bg = Color.alphaBlend(
      color.withValues(alpha: c.isDark ? 0.12 : 0.08),
      c.secondaryGroupedBackground,
    );
    return Padding(
      padding: margin,
      child: Semantics(
        liveRegion: tone == BannerTone.error,
        container: true,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppleRadii.md),
            border: Border.all(
              color: color.withValues(alpha: c.isDark ? 0.32 : 0.25),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpacing.sm + 2,
              AppleSpacing.sm,
              AppleSpacing.xs,
              AppleSpacing.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(icon ?? toneIcon(tone), size: 20, color: color),
                ),
                const SizedBox(width: AppleSpacing.sm),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(right: AppleSpacing.xs),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (title != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Text(
                              title!,
                              style: type.subheadline.copyWith(
                                color: c.label,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        Text(
                          message,
                          style:
                              (title == null ? type.subheadline : type.footnote)
                                  .copyWith(
                                    color: title == null
                                        ? c.label
                                        : c.secondaryLabel,
                                  ),
                        ),
                        if (actionLabel != null && onAction != null)
                          Padding(
                            padding: const EdgeInsets.only(
                              top: AppleSpacing.xs,
                            ),
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: onAction,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Text(
                                  actionLabel!,
                                  style: type.footnote.copyWith(
                                    color: color,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (onDismiss != null)
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      iconSize: 16,
                      tooltip: tr('Fechar'),
                      onPressed: onDismiss,
                      icon: Icon(Icons.close_rounded, color: c.secondaryLabel),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
