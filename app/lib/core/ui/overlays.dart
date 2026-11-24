import 'package:flutter/material.dart';

import '../theme/apple_tokens.dart';
import '../theme/apple_typography.dart';
import 'controls.dart';

/// Abre uma folha modal moderna (bottom sheet): cantos limpos, alça discreta e, com
/// [title], cabeçalho claro. Em tela larga fica limitada a 640 px e sobe com o teclado.
Future<T?> showAppleSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  String? title,
  bool isDismissible = true,
  bool useRootNavigator = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: isDismissible,
    useRootNavigator: useRootNavigator,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) {
      final c = AppleColors.of(context);
      final type = AppleTextStyles.of(context);
      return Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppleSpacing.lg,
                    0,
                    AppleSpacing.lg,
                    AppleSpacing.sm,
                  ),
                  child: Text(
                    title,
                    style: type.title3.copyWith(color: c.label),
                  ),
                ),
              Flexible(child: Builder(builder: builder)),
            ],
          ),
        ),
      );
    },
  );
}

/// Botão de um [showAppleDialog]. [isDefault] vira ação principal; [isDestructive] usa
/// vermelho. Tocar fecha o alerta devolvendo [value].
class AppleDialogAction<T> {
  const AppleDialogAction({
    required this.label,
    this.value,
    this.isDefault = false,
    this.isDestructive = false,
  });

  final String label;
  final T? value;
  final bool isDefault;
  final bool isDestructive;
}

/// Diálogo moderno (estilo AlertDialog do shadcn/ui): título e descrição alinhados à
/// esquerda, borda nítida de 1 px e barra de botões responsiva na base.
Future<T?> showAppleDialog<T>({
  required BuildContext context,
  required String title,
  String? message,
  Widget? content,
  required List<AppleDialogAction<T>> actions,
  bool barrierDismissible = true,
  bool scrollable = false,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (context) => _ModernAlertDialog<T>(
      title: title,
      message: message,
      content: content,
      actions: actions,
      scrollable: scrollable,
    ),
  );
}

class _ModernAlertDialog<T> extends StatelessWidget {
  const _ModernAlertDialog({
    required this.title,
    required this.actions,
    this.message,
    this.content,
    this.scrollable = false,
  });

  final String title;
  final String? message;
  final Widget? content;
  final List<AppleDialogAction<T>> actions;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);

    Widget buildButton(AppleDialogAction<T> a) {
      if (a.isDestructive) {
        return PrimaryButton(
          label: a.label,
          color: c.red,
          compact: true,
          onPressed: () => Navigator.of(context).pop(a.value),
        );
      }
      if (a.isDefault) {
        return PrimaryButton(
          label: a.label,
          compact: true,
          onPressed: () => Navigator.of(context).pop(a.value),
        );
      }
      return SecondaryButton(
        label: a.label,
        compact: true,
        onPressed: () => Navigator.of(context).pop(a.value),
      );
    }

    final body = Padding(
      padding: const EdgeInsets.all(AppleSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: type.title3.copyWith(color: c.label)),
          if (message != null) ...[
            const SizedBox(height: AppleSpacing.xs),
            Text(
              message!,
              style: type.subheadline.copyWith(color: c.secondaryLabel),
            ),
          ],
          if (content != null) ...[
            const SizedBox(height: AppleSpacing.sm),
            content!,
          ],
          const SizedBox(height: AppleSpacing.lg),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: AppleSpacing.xs,
            runSpacing: AppleSpacing.xs,
            children: [for (final a in actions) buildButton(a)],
          ),
        ],
      ),
    );

    return Dialog(
      insetPadding: const EdgeInsets.all(AppleSpacing.lg),
      backgroundColor: c.isDark ? c.tertiaryGroupedBackground : Colors.white,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppleRadii.lg),
        side: BorderSide(color: c.separator),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        // A keyboard can leave only a short viewport in landscape. Keep the
        // complete form and its actions reachable without overflowing it.
        child: scrollable ? SingleChildScrollView(child: body) : body,
      ),
    );
  }
}
