import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';

import 'ai_limits_models.dart';
import 'ai_limits_settings_page.dart';
import 'ai_limits_store.dart';
import 'ai_provider_icon.dart';
import 'ai_provider_style.dart';

/// Editor fields rendered inside `InfoSection` when a deck button uses `dynamicType == 'ai_limits'`.
/// Binds only opaque `accountId`/`sourceId` and display preferences—never secrets, emails, or tokens.
/// Changing the bound account never resets button position, columnSpan, or rowSpan.
class AiLimitsEditorFields extends StatefulWidget {
  final Map<String, String> params;
  final void Function(Map<String, String> nextParams) onChanged;

  const AiLimitsEditorFields({
    super.key,
    required this.params,
    required this.onChanged,
  });

  @override
  State<AiLimitsEditorFields> createState() => _AiLimitsEditorFieldsState();
}

class _AiLimitsEditorFieldsState extends State<AiLimitsEditorFields> {
  @override
  void initState() {
    super.initState();
    AiLimitsStore.instance.ensureInitialized();
  }

  void _update(AiLimitsTileConfig next) {
    widget.onChanged(next.toParams());
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AiLimitsSettingsPage()),
    );
    if (mounted) {
      AiLimitsStore.instance.load(silent: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = AiLimitsTileConfig.fromParams(widget.params);
    return Watch((context) {
      final store = AiLimitsStore.instance;
      final snap = store.snapshot.value;
      final accounts = snap?.accounts ?? const <AiLimitsAccount>[];
      final selectedExists =
          config.accountId.isEmpty || accounts.any((a) => a.id == config.accountId);

      final windowChoice = switch (config.windows) {
        'five_hour' || 'weekly' || 'all' || 'five_hour,weekly' => config.windows,
        _ => 'five_hour,weekly',
      };
      final bound = accounts.where((a) => a.id == config.accountId).firstOrNull;
      final pools = bound?.extraPools ?? const <String>[];
      // Keep a saved pool visible even if the PC stopped reporting it, so saving the
      // tile never silently switches pools.
      final poolChoices = [
        ...pools,
        if (config.pool.isNotEmpty && !pools.contains(config.pool)) config.pool,
      ];

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(tr('Uma conta'))),
                ButtonSegment(value: true, label: Text(tr('Combinar contas'))),
              ],
              selected: {config.combined},
              onSelectionChanged: (value) => _update(config.copyWith(
                combined: value.first,
                accountIds: config.accountIds.isEmpty && config.accountId.isNotEmpty ? [config.accountId] : config.accountIds,
              )),
            ),
          ),
          if (config.combined) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Todas as contas ativadas')),
              subtitle: Text(tr('Inclui novas contas automaticamente. Cada limite continua separado.')),
              value: config.allAccounts,
              onChanged: (value) => _update(config.copyWith(allAccounts: value)),
            ),
            if (!config.allAccounts) ...[
              for (final account in accounts)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(account.displayTitle),
                  subtitle: Text(account.providerLabel),
                  value: config.accountIds.contains(account.id),
                  onChanged: (value) => _update(config.copyWith(accountIds: value == true
                      ? [...config.accountIds, account.id].toSet().toList()
                      : config.accountIds.where((id) => id != account.id).toList())),
                ),
              for (final id in config.accountIds.where((id) => !accounts.any((a) => a.id == id)))
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(tr('Conta removida')),
                  subtitle: Text(tr('Escolha outra conta ou desmarque esta entrada.')),
                  value: true,
                  onChanged: (_) => _update(config.copyWith(accountIds: config.accountIds.where((a) => a != id).toList())),
                ),
            ],
            Text(tr('Use um cartão largo ou alto para ver mais contas. Toque nele para ver todos os limites, sem somar percentuais.')),
          ],
          if (!config.combined) Padding(
            padding: const EdgeInsets.only(top: 12),
            child: DropdownButtonFormField<String>(
              key: ValueKey('ai_limits_acct_${config.accountId}_${accounts.length}'),
              initialValue: config.accountId,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: tr('Conta de IA'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: '',
                  child: Text(
                    accounts.isEmpty
                        ? tr('Nenhuma conta conectada')
                        : tr('Escolha uma conta…'),
                  ),
                ),
                for (final a in accounts)
                  DropdownMenuItem(
                    value: a.id,
                    child: Row(
                      children: [
                        AiProviderIcon(
                          style: AiProviderStyle.resolve(a.provider),
                          size: 16,
                          color: AiProviderStyle.resolve(a.provider).legibleOn(
                            dark: Theme.of(context).brightness == Brightness.dark,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            [
                              a.displayTitle,
                              if (a.plan != null && a.plan!.isNotEmpty) '(${a.plan!})',
                              if (!a.enabled) '· ${tr('Desativado')}',
                            ].join(' '),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!selectedExists)
                  DropdownMenuItem(
                    value: config.accountId,
                    child: Text(
                      tr('Conta removida'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                final id = v ?? '';
                final match = accounts.where((a) => a.id == id).firstOrNull;
                _update(config.copyWith(
                  accountId: id,
                  sourceId: match?.sourceId ?? (id.isEmpty ? '' : config.sourceId),
                  providerHint: match?.provider ?? (id.isEmpty ? '' : config.providerHint),
                  aliasHint: match?.defaultAlias ?? '',
                  // Pools belong to one account: a new account starts on its main pool.
                  pool: id == config.accountId ? config.pool : '',
                ));
              },
            ),
          ),
          if (!config.combined && poolChoices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: DropdownButtonFormField<String>(
                key: ValueKey('ai_limits_pool_${config.accountId}_${config.pool}'),
                initialValue: config.pool,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: tr('Grupo de modelos'),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem(value: '', child: Text(tr('Principal (conta toda)'))),
                  for (final p in poolChoices)
                    DropdownMenuItem(
                      value: p,
                      child: Text(p, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => _update(config.copyWith(pool: v ?? '')),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'used', label: Text(tr('% usado'))),
                ButtonSegment(value: 'remaining', label: Text(tr('% livre'))),
              ],
              selected: {config.displayMode},
              onSelectionChanged: (v) => _update(config.copyWith(displayMode: v.first)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: DropdownButtonFormField<String>(
              key: ValueKey('ai_limits_win_$windowChoice'),
              initialValue: windowChoice,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: tr('Janelas exibidas'),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                  value: 'five_hour,weekly',
                  child: Text(tr('5 horas e Semanal')),
                ),
                DropdownMenuItem(
                  value: 'five_hour',
                  child: Text(tr('Somente 5 horas')),
                ),
                DropdownMenuItem(
                  value: 'weekly',
                  child: Text(tr('Somente Semanal')),
                ),
                DropdownMenuItem(
                  value: 'all',
                  child: Text(tr('Todas as janelas disponíveis')),
                ),
              ],
              onChanged: (v) => _update(config.copyWith(windows: v ?? 'five_hour,weekly')),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'comfortable', label: Text(tr('Confortável'))),
                ButtonSegment(value: 'compact', label: Text(tr('Compacto'))),
              ],
              selected: {config.density},
              onSelectionChanged: (v) => _update(config.copyWith(density: v.first)),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(tr('Mostrar contagem de reinício')),
            value: config.showReset,
            onChanged: (v) => _update(config.copyWith(showReset: v)),
          ),
          const SizedBox(height: 4),
          SecondaryButton(
            label: tr('Gerenciar fontes e contas'),
            icon: Icons.tune_rounded,
            compact: true,
            expand: true,
            onPressed: _openSettings,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              tr('Dica: em "Tamanho", largura 2 × altura 1 deixa os medidores mais legíveis. Trocar a conta mantém a posição e o tamanho da tecla.'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    });
  }
}
