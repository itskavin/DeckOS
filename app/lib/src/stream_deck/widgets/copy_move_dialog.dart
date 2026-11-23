import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

import '../stream_deck_controller.dart';

/// Copia ou move um botão para outro perfil (ou duplica no mesmo), perguntando o destino.
/// Vai para a primeira casa livre numa grade de [rows]×[columns] (a do celular); quem
/// copia é o PC (ver [StreamDeckController.copyButtonTo]).
Future<void> copyOrMoveButton(
  BuildContext context, {
  required StreamDeckController controller,
  required DeckButton button,
  required int rows,
  required int columns,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final chosen = await showDialog<(DeckProfile, bool)>(
    context: context,
    builder: (context) => _CopyMoveDialog(
      profiles: controller.profiles.value,
      current: controller.currentProfile.value,
    ),
  );
  if (chosen == null) return;
  final (target, move) = chosen;
  final error = await controller.copyButtonTo(button, target, rows: rows, columns: columns, move: move);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(error ??
          (move
              ? tr('Botão movido para "{name}".', {'name': target.name})
              : tr('Botão copiado para "{name}".', {'name': target.name}))),
      duration: const Duration(seconds: 4),
    ));
}

class _CopyMoveDialog extends StatefulWidget {
  final List<DeckProfile> profiles;
  final DeckProfile? current;

  const _CopyMoveDialog({required this.profiles, required this.current});

  @override
  State<_CopyMoveDialog> createState() => _CopyMoveDialogState();
}

class _CopyMoveDialogState extends State<_CopyMoveDialog> {
  bool _move = false;
  late DeckProfile? _target = widget.current;

  @override
  Widget build(BuildContext context) {
    final current = widget.current;
    // Mover para o mesmo perfil não faz sentido (para isso, arraste no modo de edição).
    final options = _move ? widget.profiles.where((p) => p.id != current?.id).toList() : widget.profiles;
    final target = options.any((p) => p.id == _target?.id) ? _target : null;
    return AlertDialog(
      title: Text(tr('Copiar ou mover')),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedControl<bool>(
              segments: {
                false: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.content_copy_rounded, size: 15),
                      const SizedBox(width: 6),
                      Text(tr('Copiar')),
                    ],
                  ),
                ),
                true: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.drive_file_move_outlined, size: 15),
                      const SizedBox(width: 6),
                      Text(tr('Mover')),
                    ],
                  ),
                ),
              },
              value: _move,
              onChanged: (v) => setState(() => _move = v),
            ),
            const SizedBox(height: 12),
            Text(tr('Para o perfil'), style: Theme.of(context).textTheme.labelLarge),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in options)
                    ListTile(
                      dense: true,
                      selected: target?.id == p.id,
                      leading: Icon(target?.id == p.id ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                      title: Text(p.id == current?.id ? tr('{name} (este)', {'name': p.name}) : p.name),
                      onTap: () => setState(() => _target = p),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Cancelar'))),
        FilledButton(
          onPressed: target == null ? null : () => Navigator.of(context).pop((target, _move)),
          child: Text(_move ? tr('Mover') : tr('Copiar')),
        ),
      ],
    );
  }
}
