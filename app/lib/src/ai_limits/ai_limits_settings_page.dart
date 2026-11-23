import 'dart:async';

import 'package:deckos/core/core.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/settings_kit.dart';
import '../connection/pc_store.dart';
import 'ai_limits_models.dart';
import 'ai_limits_dashboard.dart';
import 'ai_limits_store.dart';
import 'ai_provider_style.dart';

/// Settings → AI Limits screen.
/// Discoverable from ConfigPage, DesktopSidebar, Tile Detail Sheet, Tile Editor, and an empty
/// AI Usage deck page. Works standalone even when `deck_only = true` and returns cleanly.
class AiLimitsSettingsPage extends StatefulWidget {
  final bool openWizardOnStart;

  const AiLimitsSettingsPage({super.key, this.openWizardOnStart = false});

  @override
  State<AiLimitsSettingsPage> createState() => _AiLimitsSettingsPageState();
}

class _AiLimitsSettingsPageState extends State<AiLimitsSettingsPage> {
  final AiLimitsStore _store = AiLimitsStore.instance;
  Timer? _cooldownTick;
  int _previousCooldown = 0;
  bool _addingTiles = false;
  bool _showRemaining = false;
  (BannerTone, String)? _notice;

  @override
  void initState() {
    super.initState();
    _store.ensureInitialized();
    unawaited(_store.load(silent: _store.snapshot.value != null));
    _cooldownTick = Timer.periodic(const Duration(seconds: 1), (_) {
      final cooldown = _store.remainingCooldownSeconds();
      if (mounted && (cooldown > 0 || _previousCooldown > 0)) {
        setState(() {});
      }
      _previousCooldown = cooldown;
    });
    if (widget.openWizardOnStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _openOnboardingWizard();
      });
    }
  }

  @override
  void dispose() {
    _cooldownTick?.cancel();
    super.dispose();
  }

  void _showNotice(BannerTone tone, String msg) {
    if (mounted) setState(() => _notice = (tone, msg));
  }

  Future<void> _refreshAll() async {
    final res = await _store.refresh();
    if (!mounted || res == null) return;
    if (res.throttled && res.message != null) {
      _showNotice(BannerTone.warning, res.message!);
    } else {
      _showNotice(BannerTone.success, tr('Limites atualizados.'));
    }
  }

  Future<void> _openOnboardingWizard({
    AiLimitsSource? editing,
    String? initialKind,
  }) async {
    // The picker and its "Detected" badges come from the PC's capabilities: wait for the
    // first snapshot instead of showing generic fallbacks.
    if (_store.snapshot.value == null) await _store.load(silent: true);
    if (!mounted) return;
    final snap = _store.snapshot.value;
    final result = await Navigator.of(context).push<_WizardOutcome>(
      MaterialPageRoute(
        builder: (_) => _AiLimitsSourceWizardPage(
          capabilities: snap?.capabilities ?? const AiLimitsCapabilities(),
          editing: editing,
          initialKind: initialKind,
        ),
      ),
    );
    if (!mounted || result == null) return;
    if (result.addedTileCount > 0) {
      _showNotice(
        BannerTone.success,
        tr('{n} cartões adicionados à página AI Usage.', {
          'n': '${result.addedTileCount}',
        }),
      );
    } else if (result.saved) {
      _showNotice(BannerTone.success, tr('Fonte salva.'));
    }
    // A new Claude Code source has no readings until its statusLine hook is set up:
    // continue straight into the guided setup instead of leaving it "awaiting data".
    final setupFor = result.setupSource;
    if (setupFor != null && mounted) await _openSetupGuide(setupFor);
  }

  /// One tap on a tool found on the PC: set it up, or open what it needs next.
  Future<void> _onDetectedTap(_DetectedTool tool) async {
    final existing = tool.source;
    if (existing == null) {
      await _openOnboardingWizard(initialKind: tool.kind);
    } else if (existing.kind == 'claude_statusline' &&
        (existing.status == 'setup_required' ||
            existing.status == 'awaiting_data' ||
            existing.errorCode == 'hook_not_installed')) {
      await _openSetupGuide(existing);
    } else {
      await _openOnboardingWizard(editing: existing);
    }
  }

  Future<void> _confirmDeleteSource(AiLimitsSource source) async {
    final ok = await showAppleDialog<bool>(
      context: context,
      title: tr('Remover "{name}"?', {'name': source.label}),
      message: tr(
        'Remove esta fonte e a chave salva apenas do DeckOS. Não desconecta suas contas nem altera configurações externas.',
      ),
      actions: [
        AppleDialogAction(label: tr('Cancelar'), value: false),
        AppleDialogAction(
          label: tr('Remover'),
          value: true,
          isDestructive: true,
        ),
      ],
    );
    if (ok != true || !mounted) return;
    try {
      await _store.deleteSource(source.id);
      _showNotice(BannerTone.info, tr('Fonte removida do DeckOS.'));
    } on AiLimitsApiException catch (e) {
      _showNotice(BannerTone.error, e.message);
    }
  }

  Future<void> _renameAccount(AiLimitsAccount acct) async {
    final ctrl = TextEditingController(text: acct.alias);
    final res = await showAppleDialog<String>(
      context: context,
      title: tr('Renomear conta'),
      content: Padding(
        padding: const EdgeInsets.only(top: AppleSpacing.sm),
        child: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: AppleColors.of(context).tertiaryFill,
            hintText: tr('Ex.: Pessoal, Trabalho'),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
          onSubmitted: (v) => Navigator.of(context).pop(v.trim()),
        ),
      ),
      actions: [
        AppleDialogAction(label: tr('Cancelar')),
        AppleDialogAction(
          label: tr('Salvar'),
          isDefault: true,
          value: '\u0000',
        ),
      ],
    );
    final next = (res == '\u0000' ? ctrl.text.trim() : res)?.trim();
    ctrl.dispose();
    if (next == null || next.isEmpty || next == acct.alias || !mounted) return;
    try {
      await _store.updateAccount(acct.id, alias: next);
    } on AiLimitsApiException catch (e) {
      _showNotice(BannerTone.error, e.message);
    }
  }

  Future<void> _toggleAccount(AiLimitsAccount acct, bool enabled) async {
    try {
      await _store.updateAccount(acct.id, enabled: enabled);
    } on AiLimitsApiException catch (e) {
      _showNotice(BannerTone.error, e.message);
    }
  }

  Future<void> _confirmRemoveAccount(AiLimitsAccount acct) async {
    final ok = await showAppleDialog<bool>(
      context: context,
      title: tr('Remover "{name}"?', {'name': acct.displayTitle}),
      message: tr(
        'Oculta esta conta apenas no DeckOS sem desconectar o serviço de origem. Teclas vinculadas a ela ficarão no deck para você reatribuir depois.',
      ),
      actions: [
        AppleDialogAction(label: tr('Cancelar'), value: false),
        AppleDialogAction(
          label: tr('Remover'),
          value: true,
          isDestructive: true,
        ),
      ],
    );
    if (ok != true || !mounted) return;
    try {
      await _store.removeAccount(acct.id);
      _showNotice(BannerTone.info, tr('Conta removida localmente.'));
    } on AiLimitsApiException catch (e) {
      _showNotice(BannerTone.error, e.message);
    }
  }

  Future<void> _addAccountsToDeck(List<AiLimitsAccount> accounts) async {
    if (accounts.isEmpty || _addingTiles) return;
    setState(() => _addingTiles = true);
    try {
      final res = await AiLimitsStore.addAccountsToAiUsagePage(accounts);
      if (!mounted) return;
      if (res.added == 0) {
        _showNotice(
          BannerTone.info,
          tr('Essas contas já estão na página AI Usage.'),
        );
      } else {
        _showNotice(
          BannerTone.success,
          tr('{n} cartões adicionados à página AI Usage.', {
            'n': '${res.added}',
          }),
        );
      }
    } catch (_) {
      _showNotice(
        BannerTone.error,
        tr('Não foi possível salvar os cartões no deck.'),
      );
    } finally {
      if (mounted) setState(() => _addingTiles = false);
    }
  }

  Future<void> _openSetupGuide(AiLimitsSource source) async {
    await showSettingsSheet<void>(
      context: context,
      title: source.label,
      builder: (_) => _GuidedHookSetupSheet(source: source),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final snap = _store.snapshot.value;
      final loading = _store.isLoading.value && snap == null;
      final refreshing = _store.isRefreshing.value;
      final error = _store.error.value;
      final cooldown = _store.remainingCooldownSeconds();
      final sources = snap?.sources ?? const <AiLimitsSource>[];
      final accounts = snap?.accounts ?? const <AiLimitsAccount>[];
      final enabledAccounts = accounts.where((a) => a.enabled).toList();

      return SettingsScaffold(
        title: tr('Limites de IA'),
        maxWidth: 1040,
        largeTitle: MediaQuery.sizeOf(context).height >= 520,
        subtitle: _headerSummary(snap),
        actions: [
          IconButton(
            tooltip: cooldown > 0
                ? tr('Aguarde {s}s', {'s': '$cooldown'})
                : tr('Atualizar agora'),
            onPressed: (refreshing || cooldown > 0 || sources.isEmpty)
                ? null
                : _refreshAll,
            icon: refreshing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh_rounded, size: 22),
          ),
        ],
        bottom: PrimaryButton(
          label: sources.isEmpty
              ? tr('Conectar uma fonte')
              : tr('Adicionar fonte'),
          icon: Icons.add_rounded,
          expand: true,
          onPressed: () => _openOnboardingWizard(),
        ),
        children: [
          if (_notice != null)
            AppleBanner(
              tone: _notice!.$1,
              message: _notice!.$2,
              onDismiss: () => setState(() => _notice = null),
              margin: const EdgeInsets.fromLTRB(
                AppleSpacing.screen,
                0,
                AppleSpacing.screen,
                AppleSpacing.md,
              ),
            ),
          if (error != null)
            AppleBanner(
              tone: BannerTone.warning,
              message: error,
              margin: const EdgeInsets.fromLTRB(
                AppleSpacing.screen,
                0,
                AppleSpacing.screen,
                AppleSpacing.md,
              ),
            ),
          if (loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: AppleSpacing.xxl),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (sources.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpacing.screen,
                AppleSpacing.md,
                AppleSpacing.screen,
                AppleSpacing.xl,
              ),
              child: EmptyState(
                icon: CupertinoIcons.gauge,
                title: tr('Acompanhe seus limites de IA'),
                message: tr(
                  'Conecte seu CLIProxyAPI local, Codex app-server ou hook oficial do Claude Code para ver janelas reais em cartões móveis no deck.',
                ),
                action: PrimaryButton(
                  label: tr('Conectar uma fonte'),
                  icon: Icons.add_rounded,
                  onPressed: () => _openOnboardingWizard(),
                ),
              ),
            )
          else ...[
            if (accounts.isNotEmpty) ...[
              AiLimitsOverview(accounts: enabledAccounts),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppleSpacing.screen,
                ),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    Text(
                      tr('Uso por conta'),
                      style: AppleTextStyles.of(context).title3,
                    ),
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(value: false, label: Text(tr('Usado'))),
                        ButtonSegment(value: true, label: Text(tr('Restante'))),
                      ],
                      selected: {_showRemaining},
                      showSelectedIcon: false,
                      onSelectionChanged: (v) =>
                          setState(() => _showRemaining = v.first),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppleSpacing.screen,
                  8,
                  AppleSpacing.screen,
                  16,
                ),
                child: Text(
                  tr(
                    'Cada conta e janela tem seu próprio limite. Os valores não são somados.',
                  ),
                  style: AppleTextStyles.of(context).footnote.copyWith(
                    color: AppleColors.of(context).secondaryLabel,
                  ),
                ),
              ),
              for (final provider
                  in accounts.map((a) => a.provider).toSet()) ...[
                AiSectionTitle(
                  AiProviderStyle.resolve(
                    provider,
                    fallbackLabel: accounts
                        .firstWhere((a) => a.provider == provider)
                        .providerLabel,
                  ).displayName,
                ),
                AiCardGrid(
                  count: accounts.where((a) => a.provider == provider).length,
                  itemBuilder: (context, i, width) {
                    final a = accounts
                        .where((a) => a.provider == provider)
                        .elementAt(i);
                    return AiAccountUsageCard(
                      key: ValueKey('ai-account-${a.id}'),
                      account: a,
                      showRemaining: _showRemaining,
                      width: width,
                      onOpen: () => _openAccountActions(a),
                    );
                  },
                ),
                const SizedBox(height: AppleSpacing.lg),
              ],
            ],
            InsetGroupedSection(
              header: tr('Fontes conectadas'),
              footer:
                  snap?.capabilities.platform != null &&
                      snap!.capabilities.platform != 'unknown'
                  ? tr(
                      'Host do PC: {os} · Somente leitura passiva ou interfaces oficiais locais.',
                      {'os': _platformLabel(snap.capabilities.platform)},
                    )
                  : null,
              children: [
                for (final s in sources)
                  _SourceRow(
                    source: s,
                    onEdit: () => _openOnboardingWizard(editing: s),
                    onDelete: () => _confirmDeleteSource(s),
                    onSetup: s.kind == 'claude_statusline'
                        ? () => _openSetupGuide(s)
                        : null,
                  ),
              ],
            ),
            if (enabledAccounts.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppleSpacing.screen,
                  0,
                  AppleSpacing.screen,
                  AppleSpacing.xl,
                ),
                child: SecondaryButton(
                  label: _addingTiles
                      ? tr('Adicionando…')
                      : tr('Adicionar todas à página AI Usage'),
                  icon: Icons.dashboard_customize_rounded,
                  expand: true,
                  onPressed: _addingTiles
                      ? null
                      : () => _addAccountsToDeck(enabledAccounts),
                ),
              ),
          ],
          if (!loading && snap != null)
            _DetectedSection(
              tools: _DetectedTool.from(snap),
              platform: snap.capabilities.platform,
              onTap: _onDetectedTap,
            ),
        ],
      );
    });
  }

  Future<void> _openAccountActions(AiLimitsAccount account) async {
    final choice = await showSettingsSheet<String>(
      context: context,
      title: account.displayTitle,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        children: [
          InsetGroupedSection(
            children: [
              ListRow(
                title: account.enabled
                    ? tr('Desativar conta')
                    : tr('Ativar conta'),
                onTap: () => Navigator.of(sheet).pop('toggle'),
              ),
              ListRow(
                title: tr('Adicionar cartão à página AI Usage'),
                onTap: () => Navigator.of(sheet).pop('add_tile'),
              ),
              ListRow(
                title: tr('Renomear'),
                onTap: () => Navigator.of(sheet).pop('rename'),
              ),
              if (account.dashboardUrl != null &&
                  account.dashboardUrl!.isNotEmpty)
                ListRow(
                  title: tr('Abrir painel oficial'),
                  onTap: () => Navigator.of(sheet).pop('dashboard'),
                ),
              ListRow(
                title: tr('Remover do DeckOS'),
                destructive: true,
                onTap: () => Navigator.of(sheet).pop('remove'),
              ),
            ],
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (choice == 'toggle') await _toggleAccount(account, !account.enabled);
    if (choice == 'add_tile') await _addAccountsToDeck([account]);
    if (choice == 'rename') await _renameAccount(account);
    if (choice == 'remove') await _confirmRemoveAccount(account);
    if (choice == 'dashboard') {
      final uri = Uri.tryParse(account.dashboardUrl ?? '');
      if (uri != null) {
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {}
      }
    }
  }

  static String _accountPreview(AiLimitsAccount acct) {
    if (!acct.enabled) return tr('Desativado');
    if (acct.isAuthRequired) return tr('Autenticação necessária');
    final shown = acct.selectWindows(const ['five_hour', 'weekly']);
    final parts = <String>[];
    for (final w in shown) {
      if (w.hasPercent) {
        final lbl = w.kind == 'five_hour'
            ? tr('5h')
            : (w.kind == 'weekly' ? tr('Semanal') : w.label);
        parts.add(tr('{janela} {p}% usado', {
          'janela': lbl,
          'p': '${w.effectiveUsedPercent!.round()}',
        }));
      }
    }
    if (parts.isNotEmpty) {
      final stale = acct.isStale || shown.any((w) => w.isEffectivelyStale());
      return stale ? '${parts.join(' · ')} (${tr('Antigo')})' : parts.join(' · ');
    }
    if (acct.quotaStatus == 'manual_only') return tr('Somente painel oficial');
    if (acct.quotaStatus == 'local_only') return tr('Contagem local');
    if (acct.quotaStatus == 'awaiting_data') return tr('Aguardando dados');
    return tr('Uso indisponível');
  }

  static String _headerSummary(AiLimitsSnapshot? snap) {
    if (snap == null || snap.sources.isEmpty) {
      return tr('Nenhuma fonte configurada.');
    }
    final sCount = snap.sources.length;
    final aCount = snap.enabledAccounts.length;
    if (aCount == 0) {
      return sCount == 1
          ? tr('1 fonte conectada · aguardando contas')
          : tr('{n} fontes · aguardando contas', {'n': '$sCount'});
    }
    return tr('{s} fontes · {a} contas ativas', {
      's': '$sCount',
      'a': '$aCount',
    });
  }

  static String _platformLabel(String platform) =>
      switch (platform.toLowerCase()) {
        'windows' => 'Windows',
        'macos' => 'macOS',
        'linux' => 'Linux',
        _ => platform,
      };
}

class _SourceRow extends StatelessWidget {
  final AiLimitsSource source;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback? onSetup;

  const _SourceRow({
    required this.source,
    required this.onEdit,
    required this.onDelete,
    this.onSetup,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final Color statusColor = switch (source.status) {
      'connected' => c.green,
      'auth_required' || 'error' => c.red,
      'rate_limited' || 'degraded' || 'offline' || 'setup_required' => c.orange,
      _ => c.gray,
    };

    final subParts = <String>[
      _sourceStatusText(source),
      if (source.baseUrl != null && source.baseUrl!.isNotEmpty) source.baseUrl!,
      if (source.hasCredential) tr('Chave salva'),
    ];

    return ListRow(
      leading: ListRowIcon(_sourceIcon(source.kind), color: statusColor),
      title: source.label,
      subtitle: subParts.join(' · '),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onSetup != null)
            IconButton(
              tooltip: tr('Configuração do hook'),
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.terminal_rounded, size: 19, color: c.accent),
              onPressed: onSetup,
            ),
          IconButton(
            tooltip: tr('Opções'),
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.more_horiz_rounded, size: 20, color: c.secondaryLabel),
            onPressed: () => _showMenu(context),
          ),
        ],
      ),
      onTap: onEdit,
    );
  }

  Future<void> _showMenu(BuildContext context) async {
    final choice = await showSettingsSheet<String>(
      context: context,
      title: source.label,
      builder: (sheet) => ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(top: AppleSpacing.xs),
        children: [
          InsetGroupedSection(
            children: [
              ListRow(
                title: tr('Editar fonte'),
                onTap: () => Navigator.of(sheet).pop('edit'),
              ),
              if (onSetup != null)
                ListRow(
                  title: tr('Configuração guiada'),
                  onTap: () => Navigator.of(sheet).pop('setup'),
                ),
              ListRow(
                title: tr('Remover do DeckOS'),
                destructive: true,
                onTap: () => Navigator.of(sheet).pop('delete'),
              ),
            ],
          ),
        ],
      ),
    );
    if (choice == 'edit') onEdit();
    if (choice == 'setup') onSetup?.call();
    if (choice == 'delete') onDelete();
  }

  static String _sourceStatusText(AiLimitsSource s) {
    if (!s.enabled) return tr('Desativado');
    if (s.statusMessage != null && s.statusMessage!.isNotEmpty) {
      return s.statusMessage!;
    }
    return switch (s.status) {
      'connected' => tr('Conectado'),
      'auth_required' => tr('Autenticação necessária'),
      'rate_limited' => tr('Limite de taxa (429)'),
      'offline' => tr('Offline'),
      'setup_required' => tr('Configuração pendente'),
      'awaiting_data' => tr('Aguardando dados'),
      'degraded' => tr('Parcial'),
      _ => tr('Erro'),
    };
  }
}

class _WizardOutcome {
  final bool saved;
  final int addedTileCount;

  /// A newly saved source that still needs its guided setup (Claude statusLine hook).
  final AiLimitsSource? setupSource;

  const _WizardOutcome({this.saved = false, this.addedTileCount = 0, this.setupSource});
}

/// A CLI or proxy that the PC (not this phone) reported in `capabilities.detected`,
/// joined with the source already set up for it, if any.
@immutable
class _DetectedTool {
  final String kind;
  final String title;
  final String detail;
  final AiLimitsSource? source;
  final List<AiLimitsAccount> accounts;

  const _DetectedTool({
    required this.kind,
    required this.title,
    required this.detail,
    this.source,
    this.accounts = const [],
  });

  static List<_DetectedTool> from(AiLimitsSnapshot snap) {
    final d = snap.capabilities.detected;
    AiLimitsSource? sourceOf(String kind) =>
        snap.sources.where((s) => s.kind == kind).firstOrNull;
    List<AiLimitsAccount> accountsOf(AiLimitsSource? s) => s == null
        ? const []
        : snap.accounts.where((a) => a.sourceId == s.id).toList();
    _DetectedTool tool(String kind, String title, String detail) {
      final s = sourceOf(kind);
      return _DetectedTool(
        kind: kind,
        title: title,
        detail: detail,
        source: s,
        accounts: accountsOf(s),
      );
    }

    return [
      if (d.codexCliAvailable || d.codexDefaultHomeExists)
        tool(
          'codex_local',
          'Codex CLI',
          d.codexCliAvailable
              ? tr('Codex CLI encontrado')
              : tr('Pasta do Codex encontrada (CLI fora do PATH)'),
        ),
      if (d.claudeCliAvailable || d.claudeConfigDirExists)
        tool(
          'claude_statusline',
          'Claude Code',
          d.claudeStatusLineConfigured
              ? tr('Claude Code encontrado · statusLine já configurado')
              : tr('Claude Code encontrado'),
        ),
      if (d.geminiDirExists)
        tool('gemini_local_otel', 'Gemini CLI', tr('Pasta do Gemini CLI encontrada')),
      if (d.cliProxyReachable)
        tool(
          'cliproxy_passive',
          'CLIProxyAPI',
          tr('Respondendo em {url}', {
            'url': d.cliProxySuggestedUrl ?? 'http://127.0.0.1:8317',
          }),
        ),
    ];
  }

  /// Honest state: found on disk is not the same as signed in or reporting limits.
  ({String label, _ToolState state}) status() {
    final s = source;
    if (s == null) return (label: tr('Não configurado'), state: _ToolState.setup);
    if (!s.enabled) return (label: tr('Desativado'), state: _ToolState.idle);
    switch (s.status) {
      case 'auth_required':
        return (
          label: kind == 'cliproxy_passive' ? tr('Chave recusada') : tr('Faça login no CLI'),
          state: _ToolState.problem,
        );
      case 'setup_required':
      case 'awaiting_data':
        return (
          label: kind == 'claude_statusline' && s.status == 'setup_required'
              ? tr('Falta instalar o hook')
              : tr('Aguardando dados'),
          state: _ToolState.setup,
        );
      case 'rate_limited':
        return (label: tr('Em espera (429)'), state: _ToolState.warn);
      case 'offline':
      case 'error':
        return (label: tr('Sem resposta'), state: _ToolState.problem);
    }
    if (accounts.isNotEmpty && accounts.every((a) => a.isStale)) {
      return (label: tr('Antigo'), state: _ToolState.warn);
    }
    if (accounts.any((a) =>
        a.freshness == 'local_only' || a.coverageScope == 'account_wide_last_local_turn')) {
      return (label: tr('Estimativa local'), state: _ToolState.ok);
    }
    if (s.status == 'degraded') return (label: tr('Parcial'), state: _ToolState.warn);
    return (label: tr('Conectado'), state: _ToolState.ok);
  }
}

enum _ToolState { ok, setup, warn, problem, idle }

class _DetectedSection extends StatelessWidget {
  final List<_DetectedTool> tools;
  final String platform;
  final ValueChanged<_DetectedTool> onTap;

  const _DetectedSection({
    required this.tools,
    required this.platform,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final os = _AiLimitsSettingsPageState._platformLabel(platform);
    return InsetGroupedSection(
      header: tr('Encontrado neste PC'),
      footer: tools.isEmpty
          ? tr('Nada encontrado automaticamente. Instale o Codex CLI, Claude Code ou Gemini CLI no PC, ou adicione uma fonte manualmente.')
          : tr('Detectado no PC com o DeckOS ({os}), não neste celular. Encontrar a ferramenta não significa que os limites já estejam disponíveis.', {
              'os': os == 'unknown' ? 'PC' : os,
            }),
      children: [
        for (final t in tools)
          Builder(builder: (context) {
            final st = t.status();
            final color = switch (st.state) {
              _ToolState.ok => c.green,
              _ToolState.setup => c.accent,
              _ToolState.warn => c.orange,
              _ToolState.problem => c.red,
              _ToolState.idle => c.gray,
            };
            return ListRow(
              key: ValueKey('ai-detected-${t.kind}'),
              leading: ListRowIcon(_sourceIcon(t.kind), color: _sourceColor(c, t.kind)),
              title: t.title,
              subtitle: t.detail,
              trailing: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: c.isDark ? 0.20 : 0.13),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  t.source == null ? tr('Configurar') : st.label,
                  style: type.caption2.copyWith(color: color, fontWeight: FontWeight.w700),
                ),
              ),
              chevron: true,
              onTap: () => onTap(t),
            );
          }),
      ],
    );
  }
}

/// Easy step-by-step onboarding & source edit screen.
class _AiLimitsSourceWizardPage extends StatefulWidget {
  final AiLimitsCapabilities capabilities;
  final AiLimitsSource? editing;

  /// Preselected source kind (a tool found on the PC), skipping the picker.
  final String? initialKind;

  const _AiLimitsSourceWizardPage({
    required this.capabilities,
    this.editing,
    this.initialKind,
  });

  @override
  State<_AiLimitsSourceWizardPage> createState() => _AiLimitsSourceWizardPageState();
}

class _AiLimitsSourceWizardPageState extends State<_AiLimitsSourceWizardPage> {
  final AiLimitsStore _store = AiLimitsStore.instance;

  late String? _selectedKind = widget.editing?.kind ?? widget.initialKind;
  late final _labelCtrl = TextEditingController(text: widget.editing?.label ?? '');
  late final _urlCtrl = TextEditingController(
    text: widget.editing?.baseUrl ??
        widget.capabilities.detected.cliProxySuggestedUrl ??
        'http://127.0.0.1:8317',
  );
  final _secretCtrl = TextEditingController();
  late final _configDirCtrl = TextEditingController(text: widget.editing?.configDir ?? '');
  late final _snapshotFileCtrl =
      TextEditingController(text: widget.editing?.snapshotFile ?? '');
  late final _planCtrl = TextEditingController(text: widget.editing?.planLabel ?? '');
  late final _dashboardCtrl =
      TextEditingController(text: widget.editing?.dashboardUrl ?? '');
  late final _dailyLimitCtrl = TextEditingController(
    text: widget.editing?.dailyLimitHint != null
        ? '${widget.editing!.dailyLimitHint}'
        : '',
  );

  late String _codexMode = widget.editing?.codexMode ?? 'rpc_with_log_fallback';
  late String _manualProvider = widget.editing?.provider ?? 'antigravity';
  late bool _enabled = widget.editing?.enabled ?? true;
  bool _clearCredential = false;
  bool _showAdvanced = false;
  bool _testing = false;
  bool _saving = false;
  bool _addTilesOnSave = true;
  String? _authBlockedSignature;

  AiLimitsSourceTestResult? _testResult;
  final Set<String> _selectedPreviewAccountIds = {};
  (BannerTone, String)? _notice;

  bool get _isEditing => widget.editing != null;
  bool get _hasExistingCredential => widget.editing?.hasCredential == true;

  /// The PC this screen was opened for. A management key typed here is only ever sent
  /// to that PC: if the active PC changes meanwhile, nothing is sent and the key is wiped.
  final String? _pcIdAtOpen = PcStore.currentId;
  final DeckOSClient _clientAtOpen = Injector.get<DeckOSClient>();
  final String _routeAtOpen = Injector.get<DeckOSClient>().currentBaseUrl;

  bool get _pcChanged => PcStore.currentId != _pcIdAtOpen ||
      !identical(Injector.get<DeckOSClient>(), _clientAtOpen) ||
      _clientAtOpen.currentBaseUrl != _routeAtOpen;

  bool _abortIfPcChanged() {
    if (!_pcChanged) return false;
    _secretCtrl.clear();
    setState(() {
      _notice = (
        BannerTone.error,
        tr('O PC ativo mudou. Nada foi enviado; abra esta tela de novo no PC certo.'),
      );
    });
    return true;
  }

  List<AiLimitsSourceKindCapability> get _kinds {
    // `external_monitor_cache` is reserved by the backend and never offered.
    final fromPc = widget.capabilities.supportedSourceKinds
        .where((k) => k.kind != 'external_monitor_cache')
        .toList();
    return fromPc.isNotEmpty ? fromPc : _fallbackSourceKinds;
  }

  AiLimitsSourceKindCapability? get _currentKindInfo {
    if (_selectedKind == null) return null;
    for (final k in _kinds) {
      if (k.kind == _selectedKind) return k;
    }
    return null;
  }

  String get _currentAuthSignature =>
      '${_selectedKind ?? ''}|${_urlCtrl.text.trim()}|${_secretCtrl.text.trim()}|$_clearCredential';

  bool get _isAuthRetryBlocked =>
      _authBlockedSignature != null &&
      _authBlockedSignature == _currentAuthSignature;

  @override
  void initState() {
    super.initState();
    final preset = widget.editing == null ? widget.initialKind : null;
    if (preset != null) {
      final cap = _kinds.where((k) => k.kind == preset).firstOrNull;
      if (cap == null) {
        _selectedKind = null; // The PC doesn't offer it: fall back to the picker.
      } else {
        _applyKindDefaults(cap);
      }
    }
    // A source whose key was already rejected must not be re-tested with the stored key
    // (CLIProxyAPI bans an IP after repeated bad keys). Editing the key or URL unlocks it;
    // a name-only change doesn't.
    final e = widget.editing;
    if (e != null && (e.errorCode == 'auth_failed' || e.status == 'auth_required')) {
      _authBlockedSignature = _currentAuthSignature;
    }
    void clearBlockOnEdit() {
      if (_authBlockedSignature != null &&
          _authBlockedSignature != _currentAuthSignature &&
          mounted) {
        setState(() => _authBlockedSignature = null);
      }
    }

    _urlCtrl.addListener(clearBlockOnEdit);
    _secretCtrl.addListener(clearBlockOnEdit);
  }

  @override
  void dispose() {
    _labelCtrl.dispose();
    _urlCtrl.dispose();
    _secretCtrl.dispose();
    _configDirCtrl.dispose();
    _snapshotFileCtrl.dispose();
    _planCtrl.dispose();
    _dashboardCtrl.dispose();
    _dailyLimitCtrl.dispose();
    super.dispose();
  }

  void _pickKind(AiLimitsSourceKindCapability cap) {
    setState(() {
      _selectedKind = cap.kind;
      _notice = null;
      _testResult = null;
      _selectedPreviewAccountIds.clear();
      _applyKindDefaults(cap);
    });
  }

  void _applyKindDefaults(AiLimitsSourceKindCapability cap) {
    if (_labelCtrl.text.trim().isEmpty) {
      _labelCtrl.text = cap.title;
    }
    if (cap.kind == 'cliproxy_passive' && _urlCtrl.text.trim().isEmpty) {
      _urlCtrl.text = widget.capabilities.detected.cliProxySuggestedUrl ??
          'http://127.0.0.1:8317';
    }
    if (cap.kind == 'manual_dashboard' && _dashboardCtrl.text.trim().isEmpty) {
      _dashboardCtrl.text = _defaultDashboardUrl(_manualProvider);
    }
  }

  AiLimitsSourceDraft _buildDraft() {
    final kind = _selectedKind ?? 'cliproxy_passive';
    final label = _labelCtrl.text.trim().isEmpty
        ? (_currentKindInfo?.title ?? kind)
        : _labelCtrl.text.trim();
    final secret = _secretCtrl.text.trim();
    return AiLimitsSourceDraft(
      sourceId: widget.editing?.id,
      kind: kind,
      label: label,
      enabled: _enabled,
      baseUrl: kind == 'cliproxy_passive' ? _urlCtrl.text.trim() : null,
      credential: kind == 'cliproxy_passive' && secret.isNotEmpty && !_clearCredential
          ? secret
          : null,
      clearCredential: _isEditing && _clearCredential,
      configDir: (kind == 'codex_local' || kind == 'claude_statusline') &&
              _configDirCtrl.text.trim().isNotEmpty
          ? _configDirCtrl.text.trim()
          : null,
      snapshotFile: (kind == 'claude_statusline' || kind == 'gemini_local_otel') &&
              _snapshotFileCtrl.text.trim().isNotEmpty
          ? _snapshotFileCtrl.text.trim()
          : null,
      codexMode: kind == 'codex_local' ? _codexMode : null,
      provider: kind == 'manual_dashboard' ? _manualProvider : null,
      planLabel: kind == 'manual_dashboard' && _planCtrl.text.trim().isNotEmpty
          ? _planCtrl.text.trim()
          : null,
      dashboardUrl: kind == 'manual_dashboard' && _dashboardCtrl.text.trim().isNotEmpty
          ? _dashboardCtrl.text.trim()
          : null,
      dailyLimitHint: kind == 'gemini_local_otel'
          ? int.tryParse(_dailyLimitCtrl.text.trim())
          : null,
    );
  }

  Future<void> _testConnection() async {
    if (_isAuthRetryBlocked) {
      setState(() {
        _notice = (
          BannerTone.warning,
          tr('Altere a chave de gestão ou o endereço antes de testar novamente.'),
        );
      });
      return;
    }
    if (_abortIfPcChanged()) return;
    final sig = _currentAuthSignature;
    setState(() {
      _testing = true;
      _notice = null;
    });
    try {
      final res = await _store.testSource(_buildDraft());
      if (!mounted) return;
      final authFailed =
          res.errorCode == 'auth_failed' || res.status == 'auth_required';
      setState(() {
        _testResult = res;
        _authBlockedSignature = authFailed ? sig : null;
        _selectedPreviewAccountIds
          ..clear()
          ..addAll(res.accounts.map((a) => a.id));
        _notice = (
          res.ok ? BannerTone.success : BannerTone.warning,
          authFailed
              ? '${res.message.isNotEmpty ? '${res.message} ' : ''}${tr('Altere a chave de gestão ou o endereço antes de testar novamente.')}'
              : (res.message.isNotEmpty
                  ? res.message
                  : (res.ok ? tr('Conexão verificada.') : tr('Não foi possível conectar.'))),
        );
      });
    } on AiLimitsApiException catch (e) {
      if (mounted) {
        setState(() {
          if (e.errorCode == 'auth_failed' || e.statusCode == 401 || e.statusCode == 403) {
            _authBlockedSignature = sig;
          }
          _notice = (BannerTone.error, e.message);
        });
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    if (_abortIfPcChanged()) return;
    setState(() {
      _saving = true;
      _notice = null;
    });
    try {
      final draft = _buildDraft();
      // Clear the key field as soon as the one-time request is built: it is never kept
      // on the phone, and a failed save asks for it again.
      _secretCtrl.clear();
      final res = _isEditing
          ? await _store.updateSource(widget.editing!.id, draft)
          : await _store.createSource(draft);

      var addedTiles = 0;
      if (!_isEditing && _addTilesOnSave && res.accounts.isNotEmpty) {
        final chosen = _selectedPreviewAccountIds.isEmpty
            ? res.accounts
            : res.accounts
                .where((a) => _selectedPreviewAccountIds.contains(a.id))
                .toList();
        final toAdd = chosen.isNotEmpty ? chosen : res.accounts;
        try {
          final placed = await AiLimitsStore.addAccountsToAiUsagePage(toAdd);
          addedTiles = placed.added;
        } catch (_) {
          // Source is already saved safely even if deck profile append fails.
        }
      }
      if (!mounted) return;
      final needsHook = !_isEditing &&
          res.source.kind == 'claude_statusline' &&
          !widget.capabilities.detected.claudeStatusLineConfigured;
      Navigator.of(context).pop(_WizardOutcome(
        saved: true,
        addedTileCount: addedTiles,
        setupSource: needsHook ? res.source : null,
      ));
    } on AiLimitsApiException catch (e) {
      if (mounted) setState(() => _notice = (BannerTone.error, e.message));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final detected = widget.capabilities.detected;

    if (_selectedKind == null) {
      return SettingsScaffold(
        title: tr('Escolher fonte'),
        subtitle: tr('Conecte ferramentas locais já instaladas no PC.'),
        largeTitle: false,
        maxWidth: 620,
        children: [
          InsetGroupedSection(
            header: tr('Fontes compatíveis'),
            footer: tr(
              'O DeckOS usa apenas interfaces oficiais locais e leitura passiva, sem consultas não documentadas.',
            ),
            children: [
              for (final cap in _kinds)
                ListRow(
                  leading: ListRowIcon(
                    _sourceIcon(cap.kind),
                    color: _sourceColor(c, cap.kind),
                  ),
                  title: cap.title,
                  subtitle: _capabilitySubtitle(cap, detected),
                  trailing: _isRecommended(cap.kind, detected)
                      ? Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: c.green.withValues(alpha: c.isDark ? 0.20 : 0.14),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            tr('Detectado'),
                            style: type.caption2.copyWith(
                              color: c.green,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : null,
                  chevron: true,
                  onTap: () => _pickKind(cap),
                ),
            ],
          ),
        ],
      );
    }

    final kind = _selectedKind!;
    final cap = _currentKindInfo;

    return SettingsScaffold(
      title: _isEditing ? tr('Editar fonte') : (cap?.title ?? kind),
      largeTitle: false,
      maxWidth: 620,
      children: [
        if (_notice != null)
          AppleBanner(
            tone: _notice!.$1,
            message: _notice!.$2,
            onDismiss: () => setState(() => _notice = null),
            margin: const EdgeInsets.fromLTRB(
              AppleSpacing.screen,
              0,
              AppleSpacing.screen,
              AppleSpacing.md,
            ),
          ),
        InsetGroupedSection(
          header: tr('Configuração'),
          footer: _kindHelpFooter(kind, widget.capabilities.platform),
          children: [
            FormTextRow(
              label: tr('Nome'),
              controller: _labelCtrl,
              hint: cap?.title ?? kind,
            ),
            if (kind == 'cliproxy_passive') ...[
              FormTextRow(
                label: tr('Endereço'),
                controller: _urlCtrl,
                hint: 'http://127.0.0.1:8317',
                monospace: true,
                keyboardType: TextInputType.url,
              ),
              FormTextRow(
                label: tr('Chave de gestão'),
                controller: _secretCtrl,
                secure: true,
                hint: _hasExistingCredential && !_clearCredential
                    ? tr('Guardado no PC (deixe vazio para manter)')
                    : tr('Cole a management key'),
              ),
              if (_isEditing && _hasExistingCredential)
                ListRow(
                  title: tr('Limpar chave salva'),
                  trailing: AppleSwitch(
                    value: _clearCredential,
                    onChanged: (v) => setState(() {
                      _clearCredential = v;
                      if (v) _secretCtrl.clear();
                    }),
                  ),
                ),
            ],
            if (kind == 'codex_local') ...[
              ListRow(
                title: tr('Modo de leitura'),
                value: _codexMode == 'log_only'
                    ? tr('Somente registros locais')
                    : tr('RPC oficial + fallback'),
                chevron: true,
                onTap: () async {
                  final picked = await showChoiceSheet<String>(
                    context: context,
                    title: tr('Modo de leitura'),
                    selected: _codexMode,
                    choices: [
                      Choice(
                        'rpc_with_log_fallback',
                        tr('RPC oficial + fallback'),
                        subtitle: tr('Usa codex app-server (sem inferência) com fallback local.'),
                      ),
                      Choice(
                        'log_only',
                        tr('Somente registros locais'),
                        subtitle: tr('Lê apenas ~/.codex/sessions sem abrir subprocesso.'),
                      ),
                    ],
                  );
                  if (picked != null && mounted) {
                    setState(() => _codexMode = picked);
                  }
                },
              ),
            ],
            if (kind == 'manual_dashboard') ...[
              ListRow(
                title: tr('Serviço'),
                value: AiProviderStyle.resolve(_manualProvider).displayName,
                chevron: true,
                onTap: () async {
                  final picked = await showChoiceSheet<String>(
                    context: context,
                    title: tr('Serviço'),
                    selected: _manualProvider,
                    choices: [
                      for (final p in _manualProviders)
                        Choice(p.$1, p.$2, subtitle: p.$3),
                    ],
                  );
                  if (picked != null && mounted) {
                    setState(() {
                      _manualProvider = picked;
                      _dashboardCtrl.text = _defaultDashboardUrl(picked);
                    });
                  }
                },
              ),
              FormTextRow(
                label: tr('Plano'),
                controller: _planCtrl,
                hint: tr('Opcional (ex.: Pro)'),
              ),
              FormTextRow(
                label: tr('Painel oficial'),
                controller: _dashboardCtrl,
                hint: 'https://…',
                monospace: true,
                keyboardType: TextInputType.url,
              ),
            ],
            if (_isEditing)
              ListRow(
                title: tr('Ativada'),
                trailing: AppleSwitch(
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
              ),
          ],
        ),
        if (kind == 'codex_local' ||
            kind == 'claude_statusline' ||
            kind == 'gemini_local_otel')
          InsetGroupedSection(
            footer: _showAdvanced
                ? tr('Caminhos no PC ({os}), não neste celular. Deixe vazio para usar a pasta padrão encontrada automaticamente. Caminhos personalizados só podem ser salvos pelo próprio PC.', {
                    'os': _AiLimitsSettingsPageState._platformLabel(widget.capabilities.platform),
                  })
                : null,
            children: [
              ListRow(
                title: tr('Pasta ou perfil personalizado (opcional)'),
                subtitle: tr('Para múltiplas contas em pastas separadas no PC'),
                trailing: Icon(
                  _showAdvanced ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                  color: c.secondaryLabel,
                ),
                onTap: () => setState(() => _showAdvanced = !_showAdvanced),
              ),
              if (_showAdvanced) ...[
                if (kind == 'codex_local' || kind == 'claude_statusline')
                  FormTextRow(
                    label: kind == 'codex_local' ? 'CODEX_HOME' : 'CLAUDE_CONFIG_DIR',
                    controller: _configDirCtrl,
                    hint: _defaultDirHint(kind, widget.capabilities.platform),
                    monospace: true,
                  ),
                if (kind == 'claude_statusline' || kind == 'gemini_local_otel')
                  FormTextRow(
                    label: tr('Arquivo'),
                    controller: _snapshotFileCtrl,
                    hint: tr('Padrão automático'),
                    monospace: true,
                  ),
                if (kind == 'gemini_local_otel')
                  FormTextRow(
                    label: tr('Referência diária'),
                    controller: _dailyLimitCtrl,
                    hint: tr('Opcional (ex.: 1000)'),
                    keyboardType: TextInputType.number,
                  ),
              ],
            ],
          ),
        if (_testResult != null && _testResult!.accounts.isNotEmpty)
          InsetGroupedSection(
            header: tr('Contas descobertas ({n})', {
              'n': '${_testResult!.accounts.length}',
            }),
            footer: _testResult!.capabilitiesNote,
            children: [
              for (final a in _testResult!.accounts)
                ListRow(
                  leading: ListRowIcon(
                    AiProviderStyle.resolve(a.provider).icon,
                    color: AiProviderStyle.resolve(a.provider).legibleOn(dark: c.isDark),
                  ),
                  title: a.displayTitle,
                  subtitle: _AiLimitsSettingsPageState._accountPreview(a),
                  trailing: !_isEditing
                      ? Checkbox(
                          value: _selectedPreviewAccountIds.contains(a.id),
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _selectedPreviewAccountIds.add(a.id);
                            } else {
                              _selectedPreviewAccountIds.remove(a.id);
                            }
                          }),
                        )
                      : null,
                ),
            ],
          ),
        if (!_isEditing)
          InsetGroupedSection(
            children: [
              ListRow(
                title: tr('Adicionar cartões à página AI Usage'),
                subtitle: tr('Cria cartões 2×1 móveis que você pode arrastar ou redimensionar.'),
                trailing: AppleSwitch(
                  value: _addTilesOnSave,
                  onChanged: (v) => setState(() => _addTilesOnSave = v),
                ),
              ),
            ],
          ),
        if (cap?.provenanceNote != null && cap!.provenanceNote!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppleSpacing.screen + AppleSpacing.xs,
              0,
              AppleSpacing.screen + AppleSpacing.xs,
              AppleSpacing.md,
            ),
            child: Text(
              cap.provenanceNote!,
              style: type.caption1.copyWith(color: c.secondaryLabel),
            ),
          ),
        FormActions(
          children: [
            if (cap?.supportsTestConnection ?? true)
              SecondaryButton(
                label: _testing ? tr('Testando…') : tr('Testar conexão'),
                icon: Icons.network_check_rounded,
                expand: true,
                onPressed: (_testing || _saving || _isAuthRetryBlocked)
                    ? null
                    : _testConnection,
              ),
            PrimaryButton(
              label: _isEditing ? tr('Salvar alterações') : tr('Salvar fonte'),
              loading: _saving,
              expand: true,
              onPressed: (_testing || _saving) ? null : _save,
            ),
            SecondaryButton(
              label: tr('Cancelar'),
              expand: true,
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ],
    );
  }

  static bool _isRecommended(String kind, AiLimitsDetectedEnvironment d) => switch (kind) {
        'cliproxy_passive' => d.cliProxyReachable,
        'codex_local' => d.codexCliAvailable || d.codexDefaultHomeExists,
        'claude_statusline' => d.claudeCliAvailable || d.claudeConfigDirExists,
        'gemini_local_otel' => d.geminiDirExists,
        _ => false,
      };

  static String _capabilitySubtitle(
    AiLimitsSourceKindCapability cap,
    AiLimitsDetectedEnvironment d,
  ) {
    if (cap.kind == 'cliproxy_passive' && d.cliProxyReachable) {
      return '${d.cliProxySuggestedUrl ?? 'http://127.0.0.1:8317'} · ${cap.description}';
    }
    return cap.description;
  }

  static String _kindHelpFooter(String kind, String platform) => switch (kind) {
        'cliproxy_passive' => tr(
            'Endereços como 127.0.0.1 apontam para o PC com o DeckOS, não para este celular. A chave é enviada uma vez e guardada apenas no PC. Confira a chave antes de testar: o CLIProxyAPI bloqueia o PC por 30 min após várias chaves erradas.',
          ),
        'codex_local' => tr(
            'Usa o codex app-server oficial no PC sem consumir inferência, com fallback passivo nos arquivos locais de sessão.',
          ),
        'claude_statusline' => tr(
            'Observa passivamente o JSON oficial do statusLine do Claude Code. Após salvar, abra a configuração guiada para instalar ou copiar o comando.',
          ),
        'gemini_local_otel' => tr(
            'Lê apenas a telemetria local do Gemini CLI (contagem diária neste PC). Não inventa limites de 5h ou semanais.',
          ),
        _ => tr(
            'Mostra um cartão honesto com atalho direto para o painel oficial de uso do provedor.',
          ),
      };

  static String _defaultDirHint(String kind, String platform) {
    final win = platform.toLowerCase() == 'windows';
    if (kind == 'codex_local') {
      return win ? r'%USERPROFILE%\.codex' : '~/.codex';
    }
    return win ? r'%USERPROFILE%\.claude' : '~/.claude';
  }

  static String _defaultDashboardUrl(String provider) => switch (provider) {
        'antigravity' => 'https://antigravity.google',
        'gemini_web' => 'https://gemini.google.com/usage',
        'cursor' => 'https://cursor.com/dashboard',
        'windsurf' => 'https://windsurf.com/settings',
        'copilot' => 'https://github.com/settings/billing',
        'claude' => 'https://claude.ai/settings/usage',
        'codex' => 'https://chatgpt.com/codex/settings/usage',
        _ => '',
      };

  static const _manualProviders = [
    ('antigravity', 'Antigravity', 'https://antigravity.google'),
    ('gemini_web', 'Gemini Web', 'https://gemini.google.com/usage'),
    ('cursor', 'Cursor', 'https://cursor.com/dashboard'),
    ('windsurf', 'Windsurf', 'https://windsurf.com/settings'),
    ('copilot', 'GitHub Copilot', 'https://github.com/settings/billing'),
    ('other', 'Outro', ''),
  ];

  static final _fallbackSourceKinds = <AiLimitsSourceKindCapability>[
    AiLimitsSourceKindCapability(
      kind: 'cliproxy_passive',
      title: 'CLIProxyAPI',
      description: tr('Lê metadados passivos já capturados pelo CLIProxyAPI local.'),
      accessMode: 'passive_local_proxy',
      requiresCredential: true,
      supportsMultiAccount: true,
    ),
    AiLimitsSourceKindCapability(
      kind: 'codex_local',
      title: 'Codex (app-server)',
      description: tr('RPC local oficial do Codex CLI com fallback de sessão.'),
      accessMode: 'official_local_rpc',
      supportsMultiAccount: true,
    ),
    AiLimitsSourceKindCapability(
      kind: 'claude_statusline',
      title: 'Claude Code (statusLine)',
      description: tr('Hook oficial passivo do Claude Code sem chamadas extras.'),
      accessMode: 'official_local_hook',
      supportsGuidedSetup: true,
    ),
    AiLimitsSourceKindCapability(
      kind: 'gemini_local_otel',
      title: 'Gemini CLI (OTel local)',
      description: tr('Contagem diária local via OpenTelemetry oficial.'),
      accessMode: 'passive_local_file',
    ),
    AiLimitsSourceKindCapability(
      kind: 'manual_dashboard',
      title: tr('Painel oficial'),
      description: tr('Atalho honesto para serviços sem API oficial de cota.'),
      accessMode: 'manual_dashboard',
      supportsTestConnection: false,
    ),
  ];
}

/// Guided non-destructive setup sheet for `claude_statusline`.
class _GuidedHookSetupSheet extends StatefulWidget {
  final AiLimitsSource source;

  const _GuidedHookSetupSheet({required this.source});

  @override
  State<_GuidedHookSetupSheet> createState() => _GuidedHookSetupSheetState();
}

class _GuidedHookSetupSheetState extends State<_GuidedHookSetupSheet> {
  AiLimitsSetupGuide? _guide;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String? _success;

  /// The PC refused because this phone isn't the PC itself (`local_only_action`).
  bool _remoteOnly = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final g = await AiLimitsStore.instance.getSetupGuide(widget.source.id);
      if (mounted) setState(() => _guide = g);
    } on AiLimitsApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _install() => _runHookAction(install: true);

  Future<void> _uninstall() => _runHookAction(install: false);

  /// Runs install/uninstall and reports only what the PC actually did: a 200 reply can
  /// still carry `setup.errorCode` (settings.json left untouched), which is never shown
  /// as success.
  Future<void> _runHookAction({required bool install}) async {
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      final store = AiLimitsStore.instance;
      final g = install
          ? await store.installHook(widget.source.id)
          : await store.uninstallHook(widget.source.id);
      if (!mounted) return;
      setState(() {
        _guide = g;
        if (g.hasError) {
          _error = g.message ?? tr('O PC recusou a alteração e não mudou nada.');
        } else if (install && g.isInstalled) {
          _success = tr('Hook instalado. Use o Claude Code normalmente: o próximo turno envia os limites.');
        } else if (!install && !g.isInstalled) {
          _success = tr('Hook removido. O statusLine anterior foi restaurado.');
        } else {
          _error = tr('O PC não confirmou a alteração. Confira as instruções abaixo.');
        }
      });
    } on AiLimitsApiException catch (e) {
      if (mounted) {
        setState(() {
          _remoteOnly = e.errorCode == 'local_only_action';
          _error = _remoteOnly
              ? tr('Por segurança, o hook só pode ser instalado pelo próprio PC. Abra o DeckOS no PC ou copie o comando abaixo para o settings.json do Claude Code.')
              : e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(AppleSpacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    final g = _guide;
    const bannerMargin = EdgeInsets.fromLTRB(
      AppleSpacing.screen,
      0,
      AppleSpacing.screen,
      AppleSpacing.md,
    );
    // A refusal reported in the guide itself (e.g. settings.json isn't plain JSON).
    final guideError = _error == null && g != null && g.hasError ? g.message : null;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.only(top: AppleSpacing.xs),
      children: [
        if (_error != null || guideError != null)
          AppleBanner(
            tone: BannerTone.warning,
            message: _error ?? guideError!,
            margin: bannerMargin,
          ),
        if (_success != null)
          AppleBanner(tone: BannerTone.success, message: _success!, margin: bannerMargin),
        if (g != null && g.isInstalled && _success == null && _error == null)
          AppleBanner(
            tone: BannerTone.info,
            message: tr('Hook do DeckOS ativo neste PC.'),
            margin: bannerMargin,
          ),
        if (g != null && !g.supported)
          AppleBanner(
            tone: BannerTone.info,
            message: tr('Esta fonte não precisa de configuração guiada.'),
            margin: bannerMargin,
          ),
        if (g != null) ...[
          if (g.steps.isNotEmpty)
            SetupStepsSection(
              steps: g.steps,
              initiallyExpanded: true,
            ),
          if (g.commandPreview != null && g.commandPreview!.isNotEmpty)
            InsetGroupedSection(
              header: tr('Comando statusLine'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppleSpacing.sm),
                  child: CopyField(value: g.commandPreview!),
                ),
              ],
            ),
          if (g.caveats.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpacing.screen + AppleSpacing.xs,
                0,
                AppleSpacing.screen + AppleSpacing.xs,
                AppleSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final note in g.caveats)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '• $note',
                        style: type.caption1.copyWith(color: c.secondaryLabel),
                      ),
                    ),
                ],
              ),
            ),
          if (!g.canAutoInstall && g.supported && !g.isInstalled)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppleSpacing.screen + AppleSpacing.xs,
                0,
                AppleSpacing.screen + AppleSpacing.xs,
                AppleSpacing.md,
              ),
              child: Text(
                tr('A instalação automática não está disponível neste PC. Copie o comando acima para o statusLine do Claude Code.'),
                style: type.caption1.copyWith(color: c.secondaryLabel),
              ),
            ),
          if (g.canAutoInstall && !_remoteOnly)
            FormActions(
              children: [
                if (!g.isInstalled)
                  PrimaryButton(
                    label: tr('Instalar hook no PC'),
                    loading: _busy,
                    expand: true,
                    onPressed: _busy ? null : _install,
                  )
                else
                  SecondaryButton(
                    label: tr('Remover hook do PC'),
                    color: c.red,
                    expand: true,
                    onPressed: _busy ? null : _uninstall,
                  ),
              ],
            ),
        ],
      ],
    );
  }
}

IconData _sourceIcon(String kind) => switch (kind) {
      'cliproxy_passive' => Icons.lan_rounded,
      'codex_local' => CupertinoIcons.chevron_left_slash_chevron_right,
      'claude_statusline' => CupertinoIcons.sparkles,
      'gemini_local_otel' => CupertinoIcons.bolt_fill,
      'manual_dashboard' => Icons.open_in_new_rounded,
      _ => CupertinoIcons.gauge,
    };

Color _sourceColor(AppleColors c, String kind) => switch (kind) {
      'cliproxy_passive' => c.blue,
      'codex_local' => c.green,
      'claude_statusline' => c.orange,
      'gemini_local_otel' => c.indigo,
      'manual_dashboard' => c.gray,
      _ => c.accent,
    };
