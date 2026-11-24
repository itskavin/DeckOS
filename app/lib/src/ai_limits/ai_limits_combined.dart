import 'dart:math' as math;
import 'package:deckos/core/core.dart';
import 'package:flutter/material.dart';
import 'ai_limits_models.dart';
import 'ai_limits_store.dart';
import 'ai_limits_tile.dart' show aiWindowShortLabel, showAiLimitsDetailSheet;
import 'ai_limits_settings_page.dart';
import 'ai_provider_icon.dart';
import 'ai_provider_style.dart';

/// Explicit selections retain missing accounts. All accounts follows enabled accounts.
/// Interleave providers so a small tile can represent multiple providers without pooling quotas.
List<AiLimitsAccount?> combinedAiAccounts(
  AiLimitsTileConfig config,
  AiLimitsSnapshot? snapshot,
) {
  final selected = config.allAccounts
      ? (snapshot?.enabledAccounts ?? const <AiLimitsAccount>[])
            .cast<AiLimitsAccount?>()
      : config.accountIds.map((id) => snapshot?.accountById(id)).toList();
  final groups = <String, List<AiLimitsAccount?>>{};
  for (final account in selected) {
    groups.putIfAbsent(account?.provider ?? 'missing', () => []).add(account);
  }
  final result = <AiLimitsAccount?>[];
  for (var i = 0; groups.values.any((group) => group.length > i); i++) {
    for (final group in groups.values) {
      if (i < group.length) result.add(group[i]);
    }
  }
  return result;
}

String combinedWindowValue(AiLimitsWindow window, bool remaining) {
  if (window.isNotApplicable) return tr('N/A');
  if (window.isAuthRequired) return tr('Autenticar');
  if (window.isRateLimited) return tr('Limite atingido');
  if (window.isNotConnected) return tr('Offline');
  if (window.hasNativeCount && !window.isUnavailable) {
    final used = window.used!.toStringAsFixed(0);
    return window.limit == null
        ? '$used ${window.unit}'
        : '$used / ${window.limit!.toStringAsFixed(0)} ${window.unit}';
  }
  if (window.hasPercent && !window.isUnavailable) {
    final value = remaining
        ? window.effectiveRemainingPercent
        : window.effectiveUsedPercent;
    return '${value!.round()}%${window.isEffectivelyStale() ? ' · ${tr('Antigo')}' : ''}';
  }
  return tr('Indisponível');
}

class AiLimitsCombinedBody extends StatelessWidget {
  const AiLimitsCombinedBody({
    super.key,
    required this.config,
    required this.snapshot,
    this.label,
    this.loading = false,
    this.error,
  });
  final AiLimitsTileConfig config;
  final AiLimitsSnapshot? snapshot;
  final String? label;
  final bool loading;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final accounts = combinedAiAccounts(config, snapshot);
    final fg = DeckTile.foregroundOf(context);
    final providers = <String, int>{};
    for (final account in accounts.whereType<AiLimitsAccount>()) {
      providers.update(
        account.provider,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final title = label?.trim().isNotEmpty == true
        ? label!.trim()
        : tr('Assinaturas de IA');
    return LayoutBuilder(
      builder: (context, size) {
        final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
        final compact = size.maxWidth < 210 || size.maxHeight < 112 * scale;
        if (compact) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: Text(
                  loading
                      ? tr('Carregando…')
                      : tr('{n} contas', {'n': '${accounts.length}'}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (final provider in providers.keys.take(4))
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: AiProviderIcon(
                          style: AiProviderStyle.resolve(provider),
                          size: 18,
                          color: fg,
                        ),
                      ),
                  ],
                ),
              ),
              if (size.maxHeight >= 90 * scale)
                Flexible(
                  child: Text(
                    tr('Toque para ver limites'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: fg.withValues(alpha: .65),
                    ),
                  ),
                ),
            ],
          );
        }
        final resetRows = config.showReset && size.maxWidth >= 300;
        final rowHeight = (resetRows ? 63 : 47) * scale;
        final headerHeight = 44 * scale;
        final footerHeight = 19 * scale;
        final capacity = math.max(
          0,
          ((size.maxHeight - headerHeight - footerHeight) / rowHeight).floor(),
        );
        final shown = accounts.take(capacity).toList();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '$title · ${accounts.length}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                for (final entry in providers.entries.take(4))
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AiProviderIcon(
                          style: AiProviderStyle.resolve(entry.key),
                          size: 16,
                          color: fg,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${entry.value}',
                          style: const TextStyle(fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                const Spacer(),
                Flexible(
                  child: Text(
                    config.showRemaining ? tr('% livre') : tr('% usado'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10,
                      color: fg.withValues(alpha: .65),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (accounts.isEmpty)
              Expanded(
                child: Center(
                  child: Text(
                    loading
                        ? tr('Carregando…')
                        : error != null
                        ? tr('Sem resposta do PC')
                        : tr('Escolha contas no editor'),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            for (final account in shown)
              SizedBox(
                height: rowHeight,
                child: _CombinedAccountRow(
                  account: account,
                  config: config,
                  showReset: resetRows,
                ),
              ),
            if (accounts.isNotEmpty) const Spacer(),
            Text(
              accounts.length > shown.length
                  ? tr('+{n} contas · toque para ver todas', {
                      'n': '${accounts.length - shown.length}',
                    })
                  : tr('Limites separados · toque para detalhes'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: fg.withValues(alpha: .65)),
            ),
          ],
        );
      },
    );
  }
}

class _CombinedAccountRow extends StatelessWidget {
  const _CombinedAccountRow({
    required this.account,
    required this.config,
    required this.showReset,
  });
  final AiLimitsAccount? account;
  final AiLimitsTileConfig config;
  final bool showReset;

  @override
  Widget build(BuildContext context) {
    final a = account;
    if (a == null)
      return Align(
        alignment: Alignment.centerLeft,
        child: Text(
          tr('Conta removida · reatribuir no editor'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
      );
    final windows = a.selectWindows(config.preferredWindowKinds, maxCount: 2);
    final fg = DeckTile.foregroundOf(context);
    final metrics = !a.enabled
        ? tr('Desativado')
        : a.isAuthRequired
        ? tr('Autenticação necessária')
        : a.isUsageBlocked ||
              a.quotaStatus == 'rate_limited' ||
              a.quotaStatus == 'cooldown'
        ? tr('Limite atingido')
        : windows.isEmpty
        ? tr('Indisponível')
        : windows
              .map(
                (w) =>
                    '${aiWindowShortLabel(w)} ${combinedWindowValue(w, config.showRemaining)}',
              )
              .join('   ·   ');
    final resets = windows
        .where((w) => w.resetsAt != null && !w.isPastReset())
        .map(
          (w) =>
              '${aiWindowShortLabel(w)} ${formatAiResetTime(w.resetsAt, compact: true)}',
        )
        .join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            AiProviderIcon(
              style: AiProviderStyle.resolve(a.provider),
              size: 15,
              color: fg,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                a.displayTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        Text(
          metrics,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: a.isStale ? Colors.orangeAccent : fg.withValues(alpha: .85),
          ),
        ),
        if (showReset)
          Text(
            resets.isEmpty ? a.providerLabel : resets,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: fg.withValues(alpha: .6)),
          ),
      ],
    );
  }
}

Future<void> showAiLimitsCombinedSheet(
  BuildContext context,
  DeckButton button, {
  VoidCallback? onEditTile,
  VoidCallback? onSettingsClosed,
}) {
  final config = AiLimitsTileConfig.fromParams(button.dynamicParameters);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheet).height * .88,
        child: Watch((context) {
          final snapshot = AiLimitsStore.instance.snapshot.value;
          final accounts = combinedAiAccounts(config, snapshot);
          final colors = AppleColors.of(context);
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('Assinaturas de IA'),
                      style: AppleTextStyles.of(context).title2,
                    ),
                  ),
                  IconButton(
                    tooltip: tr('Fechar'),
                    onPressed: () => Navigator.of(sheet).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Text(tr('{n} contas', {'n': '${accounts.length}'})),
              const SizedBox(height: 8),
              Text(
                tr(
                  'Cada assinatura tem seus próprios limites. Percentuais não são somados nem calculados como média.',
                ),
                style: TextStyle(color: colors.secondaryLabel),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < accounts.length; i++) ...[
                if (accounts[i] == null)
                  ListTile(
                    leading: const Icon(Icons.link_off),
                    title: Text(tr('Conta removida')),
                    subtitle: Text(tr('Escolha outra conta no editor.')),
                  )
                else
                  Builder(
                    builder: (context) {
                      final a = accounts[i]!;
                      final windows = a.selectWindows(
                        config.preferredWindowKinds,
                        maxCount: 20,
                      );
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  AiProviderIcon(
                                    style: AiProviderStyle.resolve(a.provider),
                                    size: 22,
                                    color: colors.label,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      a.displayTitle,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                [
                                  a.providerLabel,
                                  if (a.plan != null) a.plan!,
                                  if (!a.enabled) tr('Desativado'),
                                  if (a.isAuthRequired)
                                    tr('Autenticação necessária'),
                                  if (a.isStale) tr('Antigo'),
                                ].join(' · '),
                                style: TextStyle(color: colors.secondaryLabel),
                              ),
                              for (final w in windows)
                                Padding(
                                  padding: const EdgeInsets.only(top: 10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        '${aiWindowShortLabel(w)} · ${combinedWindowValue(w, config.showRemaining)}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      if (config.showReset &&
                                          w.resetsAt != null &&
                                          !w.isPastReset())
                                        Text(
                                          formatAiResetTime(w.resetsAt) ?? '',
                                          style: TextStyle(
                                            color: colors.secondaryLabel,
                                          ),
                                        ),
                                      if (w.note?.isNotEmpty == true)
                                        Text(
                                          w.note!,
                                          style: TextStyle(
                                            color: colors.secondaryLabel,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              TextButton(
                                onPressed: () => showAiLimitsDetailSheet(
                                  context,
                                  button.copyWithForAiAccount(a.id),
                                ),
                                child: Text(tr('Detalhes da conta')),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                const SizedBox(height: 8),
              ],
              if (accounts.isEmpty) Text(tr('Escolha contas no editor')),
              if (onEditTile != null)
                TextButton(
                  onPressed: () {
                    Navigator.of(sheet).pop();
                    onEditTile();
                  },
                  child: Text(tr('Editar cartão')),
                ),
              TextButton(
                onPressed: () async {
                  final nav = Navigator.of(sheet);
                  nav.pop();
                  await nav.push(
                    MaterialPageRoute(
                      builder: (_) => const AiLimitsSettingsPage(),
                    ),
                  );
                  onSettingsClosed?.call();
                },
                child: Text(tr('Gerenciar fontes e contas')),
              ),
            ],
          );
        }),
      ),
    ),
  );
}

extension on DeckButton {
  DeckButton copyWithForAiAccount(String accountId) => DeckButton(
    id: id,
    row: row,
    column: column,
    dynamicType: aiLimitsDynamicType,
    dynamicParameters: AiLimitsTileConfig(accountId: accountId).toParams(),
  );
}
