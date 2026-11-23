import 'package:deckos/core/core.dart';
import 'package:deckos/src/stream_deck/backup/backup_file.dart';
import 'package:flutter/material.dart';

/// Exportar e importar os perfis num arquivo .deckos.
class BackupButtons extends StatefulWidget {
  /// Chamado depois de importar, para a tela recarregar os perfis.
  final VoidCallback? onImported;

  /// Aparência compacta (barra lateral do configurador) ou em lista (configurações).
  final bool dense;

  /// Seletor de arquivo opcional (usado nos testes fora do navegador).
  final Future<List<int>?> Function({String accept})? pickFile;

  const BackupButtons({super.key, this.onImported, this.dense = false, this.pickFile});

  @override
  State<BackupButtons> createState() => _BackupButtonsState();
}

class _BackupButtonsState extends State<BackupButtons> {
  bool _busy = false;

  DeckOSClient get _client => Injector.get<DeckOSClient>();

  Future<void> _run(Future<String> Function() job) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final message = await job();
      if (message.isNotEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(message)));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(_errorText(e))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _canPick => widget.pickFile != null || canPickBackup;

  Future<List<int>?> _pick({String accept = '.deckos,.droiddeck,.zip'}) =>
      (widget.pickFile ?? pickBackupFile)(accept: accept);

  static String _errorText(Object e) {
    if (e is BackupFileReadException) {
      return tr('Não foi possível ler o arquivo selecionado.');
    }
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['error'] is String) return data['error'] as String;
      if (e.response == null) return tr('O PC não respondeu.');
    }
    return friendlyError(e);
  }

  Future<String> _export() async {
    final bytes = await _client.exportBackup();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    await saveBackupFile(
        bytes, 'DeckOS-${now.year}-${two(now.month)}-${two(now.day)}.deckos');
    return '';
  }

  Future<String> _import() async {
    final bytes = await _pick();
    if (bytes == null || !mounted) return '';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('Importar backup?')),
        content: Text(tr(
          'Os perfis do arquivo entram no deck. Um perfil que já existe aqui (o mesmo '
          'perfil, de um backup anterior) é substituído pela versão do arquivo.',
        )),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('Cancelar'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('Importar'))),
        ],
      ),
    );
    if (ok != true) return '';
    final count = await _client.importBackup(bytes);
    widget.onImported?.call();
    return count == 1
        ? tr('1 perfil importado.')
        : tr('{n} perfis importados.', {'n': count});
  }

  Future<String> _importStreamDeck() async {
    final bytes = await _pick(accept: '.streamDeckProfile,.zip');
    if (bytes == null || !mounted) return '';
    final r = await _client.importStreamDeck(bytes);
    widget.onImported?.call();
    final profiles = (r['profiles'] as num?)?.toInt() ?? 0;
    final unsupported = ((r['unsupported'] as List?) ?? const []).cast<String>();
    final stripped = (r['stripped'] as num?)?.toInt() ?? 0;
    final parts = [
      profiles == 1
          ? tr('1 perfil importado do Stream Deck.')
          : tr('{n} perfis importados do Stream Deck.', {'n': profiles}),
      if (unsupported.isNotEmpty)
        tr('Sem equivalente (ficaram só com o título): {names}.',
            {'names': unsupported.join(', ')}),
      if (stripped > 0)
        tr('{n} botões de atalho ou programa ficaram sem ação: crie-os no configurador do PC.',
            {'n': stripped}),
    ];
    return parts.join(' ');
  }

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (widget.dense) {
      Widget button(IconData icon, String label, VoidCallback onTap) => Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
            child: TextButton.icon(
              onPressed: _busy ? null : onTap,
              icon: Icon(icon, size: 18),
              label: Text(label),
              style: TextButton.styleFrom(
                alignment: Alignment.centerLeft,
                minimumSize: const Size(double.infinity, 38),
                foregroundColor: muted,
              ),
            ),
          );
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(Icons.download, tr('Exportar backup'), () => _run(_export)),
          if (_canPick)
            button(Icons.upload, tr('Importar backup'), () => _run(_import)),
          if (_canPick)
            button(Icons.grid_view, tr('Importar do Stream Deck'),
                () => _run(_importStreamDeck)),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.save_alt),
          title: Text(tr('Exportar backup do deck')),
          subtitle: Text(_canPick
              ? tr('Salva todos os perfis num arquivo .deckos.')
              : tr('Salva todos os perfis num arquivo .deckos. Para importar, use o configurador no PC.')),
          trailing: _busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : null,
          onTap: _busy ? null : () => _run(_export),
        ),
        if (_canPick)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.upload_file),
            title: Text(tr('Importar backup')),
            onTap: _busy ? null : () => _run(_import),
          ),
        if (_canPick)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.grid_view),
            title: Text(tr('Importar do Stream Deck')),
            subtitle: Text(tr('Perfil exportado pelo app da Elgato (.streamDeckProfile).')),
            onTap: _busy ? null : () => _run(_importStreamDeck),
          ),
      ],
    );
  }
}
