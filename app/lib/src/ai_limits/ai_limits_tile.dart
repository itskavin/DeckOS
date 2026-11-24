import 'dart:async';
import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../stream_deck/buttons/colors.dart';
import '../stream_deck/widgets/usage_bars.dart' show CapsuleBar;
import 'ai_limits_models.dart';
import 'ai_limits_combined.dart';
import 'ai_limits_settings_page.dart';
import 'ai_limits_store.dart';
import 'ai_provider_icon.dart';
import 'ai_provider_style.dart';

/// Real live-bound AI quota tile drawn inside DeckOS's native [DeckTile] frame so
/// squircle geometry, glass/rim, shadows, font, themes, and press animations match
/// every other deck tile while adapting cleanly across spacious (2×1, 2×2), compact
/// horizontal, and square (1×1) spans.
class AiLimitsTile extends StatefulWidget {
  final DeckButton button;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const AiLimitsTile({
    super.key,
    required this.button,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  State<AiLimitsTile> createState() => _AiLimitsTileState();
}

class _AiLimitsTileState extends State<AiLimitsTile> {
  @override
  void initState() {
    super.initState();
    AiLimitsStore.instance.ensureInitialized();
  }

  @override
  Widget build(BuildContext context) {
    final config = AiLimitsTileConfig.fromParams(widget.button.dynamicParameters);
    return DeckTile(
      color: parseHexColor(widget.button.backgroundColor),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: Watch((context) {
        final store = AiLimitsStore.instance;
        final snap = store.snapshot.value;
        final loading = store.isLoading.value && snap == null;
        final error = store.error.value;
        final account = config.isBound ? snap?.accountById(config.accountId) : null;
        final source = account != null
            ? snap?.sourceById(account.sourceId)
            : (config.sourceId.isNotEmpty ? snap?.sourceById(config.sourceId) : null);

        if (config.combined) return AiLimitsCombinedBody(config: config, snapshot: snap, label: widget.button.label, loading: loading, error: error);
        return _AiLimitsTileBody(
          button: widget.button,
          config: config,
          account: account,
          source: source,
          hasSnapshot: snap != null,
          loading: loading,
          storeError: error,
        );
      }),
    );
  }
}

class _AiLimitsTileBody extends StatelessWidget {
  final DeckButton button;
  final AiLimitsTileConfig config;
  final AiLimitsAccount? account;
  final AiLimitsSource? source;
  final bool hasSnapshot;
  final bool loading;
  final String? storeError;

  const _AiLimitsTileBody({
    required this.button,
    required this.config,
    required this.account,
    required this.source,
    required this.hasSnapshot,
    required this.loading,
    required this.storeError,
  });

  @override
  Widget build(BuildContext context) {
    final fg = DeckTile.foregroundOf(context);
    final deck = DeckTheme.of(context);
    final dark = deck.background.computeLuminance() < 0.3;

    final customLabel = button.label?.trim();
    final style = AiProviderStyle.resolve(
      account?.provider ?? config.providerHint,
      fallbackLabel: account?.providerLabel,
    );
    final accent = style.legibleOn(dark: dark);

    // State 1: Unbound tile (user placed tile before picking an account).
    if (!config.isBound) {
      return _StatusTileLayout(
        style: style,
        accent: accent,
        dark: dark,
        fg: fg,
        title: (customLabel?.isNotEmpty ?? false) ? customLabel! : tr('Limites de IA'),
        badge: tr('Configurar'),
        badgeColor: dark ? const Color(0xFF60A5FA) : const Color(0xFF0369A1),
        message: tr('Conectar uma fonte'),
        hint: tr('Toque para escolher uma conta'),
      );
    }

    // State 2: Initial load before any snapshot arrived.
    if (loading && account == null) {
      final fallbackTitle = (customLabel?.isNotEmpty ?? false)
          ? customLabel!
          : style.displayName;
      return _LoadingTileLayout(
        style: style,
        accent: accent,
        dark: dark,
        fg: fg,
        title: fallbackTitle,
      );
    }

    // State 3: Snapshot loaded (or offline error) and bound account no longer exists.
    if (account == null) {
      final fallbackTitle = (customLabel?.isNotEmpty ?? false)
          ? customLabel!
          : style.displayName;
      if (!hasSnapshot && storeError != null) {
        return _StatusTileLayout(
          style: style,
          accent: accent,
          dark: dark,
          fg: fg,
          title: fallbackTitle,
          badge: tr('Offline'),
          badgeColor: DeckTileColors.orange,
          message: tr('Sem resposta do PC'),
          hint: tr('Toque para tentar novamente'),
        );
      }
      return _StatusTileLayout(
        style: style,
        overrideIcon: CupertinoIcons.exclamationmark_triangle_fill,
        accent: DeckTileColors.orange,
        dark: dark,
        fg: fg,
        title: fallbackTitle,
        badge: tr('Reparar'),
        badgeColor: DeckTileColors.orange,
        message: tr('Conta removida · toque para reconectar'),
      );
    }

    final acct = account!;
    final title = (customLabel?.isNotEmpty ?? false) && customLabel!.toLowerCase() != acct.providerLabel.toLowerCase()
        ? customLabel
        : acct.displayTitle;
    final aliasText = (acct.providerLabel.toLowerCase() != title.toLowerCase())
        ? acct.providerLabel
        : '';
    final planText = (acct.plan != null && acct.plan!.trim().isNotEmpty)
        ? acct.plan!.trim()
        : null;
    final dotColor = _connectionDotColor(acct, dark);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite ? constraints.maxWidth : 280.0;
        final maxH = constraints.maxHeight.isFinite ? constraints.maxHeight : 140.0;
        final isSquareOrSmall = maxW < 175 || (maxW < maxH * 1.22 && maxW < 215);
        final isRoomy = maxH >= 195 && maxW >= 220;
        final isSpacious = !isSquareOrSmall && maxW >= 215 && maxH >= 104 && !config.isCompact;

        final maxWindows = isRoomy ? 3 : 2;
        final windows = acct.selectWindows(
          config.preferredWindowKinds,
          maxCount: maxWindows,
          pool: config.pool,
        );
        final headerPill = _headerPillFor(acct, config, windows, dark, fg);

        if (isSquareOrSmall) {
          return _SquareAiTile(
            acct: acct,
            config: config,
            windows: windows,
            style: style,
            accent: accent,
            dark: dark,
            fg: fg,
            title: title,
            aliasText: aliasText,
            dotColor: dotColor,
            headerPill: headerPill,
            maxW: maxW,
            maxH: maxH,
          );
        }

        if (!isSpacious) {
          return _CompactHorizontalAiTile(
            acct: acct,
            config: config,
            windows: windows,
            style: style,
            accent: accent,
            dark: dark,
            fg: fg,
            title: title,
            aliasText: aliasText,
            planText: planText,
            dotColor: dotColor,
            headerPill: headerPill,
            maxW: maxW,
            maxH: maxH,
          );
        }

        return _SpaciousAiTile(
          acct: acct,
          config: config,
          windows: windows,
          style: style,
          accent: accent,
          dark: dark,
          fg: fg,
          title: title,
          aliasText: aliasText,
          planText: planText,
          dotColor: dotColor,
          headerPill: headerPill,
          isRoomy: isRoomy,
          maxW: maxW,
          maxH: maxH,
        );
      },
    );
  }

  static Color _connectionDotColor(AiLimitsAccount acct, bool dark) {
    if (!acct.enabled) return dark ? const Color(0xFF71717A) : const Color(0xFF9CA3AF);
    if (acct.isAuthRequired) return DeckTileColors.red;
    if (acct.isOffline || acct.connectionStatus == 'setup_required') {
      return DeckTileColors.orange;
    }
    if (acct.isConnectionHealthy) {
      return DeckTileColors.green;
    }
    return dark ? const Color(0xFF71717A) : const Color(0xFF9CA3AF);
  }

  static ({String text, Color color, IconData? icon})? _headerPillFor(
    AiLimitsAccount acct,
    AiLimitsTileConfig config,
    List<AiLimitsWindow> shown,
    bool dark,
    Color fg,
  ) {
    final amber = dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309);
    if (acct.isAuthRequired) {
      return (text: tr('Auth'), color: DeckTileColors.red, icon: CupertinoIcons.lock_fill);
    }
    // The provider said ordinary usage is blocked; keep saying so even after the reset
    // timer runs out, until a new reading says otherwise.
    if (acct.isUsageBlocked) {
      return (text: tr('Bloqueado'), color: DeckTileColors.red, icon: CupertinoIcons.nosign);
    }
    if (acct.isRateLimited) {
      return (text: tr('429'), color: amber, icon: CupertinoIcons.clock_fill);
    }
    if (acct.isStale || shown.any((w) => w.isEffectivelyStale())) {
      return (text: tr('Antigo'), color: amber, icon: CupertinoIcons.exclamationmark_circle);
    }
    if (acct.freshness == 'local_only') {
      return (
        text: tr('Local'),
        color: dark ? const Color(0xFF60A5FA) : const Color(0xFF0369A1),
        icon: null,
      );
    }
    if (acct.freshness == 'manual_only' || acct.quotaStatus == 'manual_only') {
      return (
        text: tr('Painel'),
        color: fg.withValues(alpha: 0.72),
        icon: CupertinoIcons.arrow_up_right_square,
      );
    }
    if (config.showReset) {
      final reset = formatAiResetTime(
        acct.nextResetAfter(DateTime.now(), among: shown),
        compact: true,
      );
      if (reset != null) {
        return (
          text: tr('Zera {t}', {'t': reset}),
          color: fg.withValues(alpha: 0.78),
          icon: CupertinoIcons.clock,
        );
      }
    }
    return null;
  }
}

/// Picks the single most urgent / constrained window for compact/square tiles
/// (highest used %, or first available window), inspired by CodexBar & Quotio.
AiLimitsWindow? _prioritizedWindow(List<AiLimitsWindow> windows) {
  if (windows.isEmpty) return null;
  AiLimitsWindow? bestPct;
  for (final w in windows) {
    if (!w.hasPercent) continue;
    if (bestPct == null || w.effectiveUsedPercent! > bestPct.effectiveUsedPercent!) {
      bestPct = w;
    }
  }
  if (bestPct != null) return bestPct;
  for (final w in windows) {
    if (w.hasNativeCount) return w;
  }
  return windows.first;
}

Color _meterColor({
  required double usedPercent,
  required bool stale,
  required bool blocked,
  required Color accent,
  required bool dark,
}) {
  final amber = dark ? const Color(0xFFFFB84D) : const Color(0xFFD97706);
  if (stale) return amber;
  if (blocked || usedPercent >= 90) return DeckTileColors.red;
  if (usedPercent >= 70) return amber;
  return accent;
}

Color _valueColor({
  required double usedPercent,
  required bool stale,
  required bool blocked,
  required Color fg,
  required bool dark,
}) {
  final amber = dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309);
  if (stale) return amber;
  if (blocked || usedPercent >= 90) return DeckTileColors.red;
  if (usedPercent >= 75) return amber;
  return fg;
}

/// Spacious card layout for 2×1, 2×2, tablet, and full-width portrait cards.
/// Fills the tile cleanly with generous typography, flush-right bold percentages,
/// thick capsule bars, and clean single-strip status messaging when no limits exist yet.
class _SpaciousAiTile extends StatelessWidget {
  final AiLimitsAccount acct;
  final AiLimitsTileConfig config;
  final List<AiLimitsWindow> windows;
  final AiProviderStyle style;
  final Color accent;
  final bool dark;
  final Color fg;
  final String title;
  final String aliasText;
  final String? planText;
  final Color dotColor;
  final ({String text, Color color, IconData? icon})? headerPill;
  final bool isRoomy;
  final double maxW;
  final double maxH;

  const _SpaciousAiTile({
    required this.acct,
    required this.config,
    required this.windows,
    required this.style,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.title,
    required this.aliasText,
    required this.planText,
    required this.dotColor,
    required this.headerPill,
    required this.isRoomy,
    required this.maxW,
    required this.maxH,
  });

  @override
  Widget build(BuildContext context) {
    final tight = maxH < 132;
    final amber = dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309);
    final padH = isRoomy ? 6.0 : (tight ? 2.0 : 4.0);
    final padV = isRoomy ? 6.0 : (tight ? 1.0 : 3.0);

    final pctWindows = windows.where((w) => w.hasPercent).toList();
    final nativeWindows = windows.where((w) => w.hasNativeCount).toList();
    final naWindows = windows.where((w) => w.isNotApplicable).toList();

    Widget buildBody() {
      if (!acct.enabled) {
        return _StatusStrip(
          icon: CupertinoIcons.pause_circle_fill,
          color: fg.withValues(alpha: 0.56),
          fg: fg,
          dark: dark,
          title: tr('Conta desativada'),
          subtitle: tr('Toque para ativar em Limites de IA'),
          tight: tight,
        );
      }
      if (acct.isAuthRequired) {
        return _StatusStrip(
          icon: CupertinoIcons.lock_fill,
          color: DeckTileColors.red,
          fg: fg,
          dark: dark,
          title: tr('Autenticação necessária'),
          subtitle: tr('Toque para corrigir em Limites de IA'),
          tight: tight,
        );
      }
      if (acct.isOffline && pctWindows.isEmpty) {
        return _StatusStrip(
          icon: CupertinoIcons.wifi_slash,
          color: amber,
          fg: fg,
          dark: dark,
          title: tr('Não conectado'),
          subtitle: tr('Verifique o PC ou toque para detalhes'),
          tight: tight,
        );
      }
      if (acct.isRateLimited && pctWindows.isEmpty) {
        final until = formatAiResetTime(acct.cooldownUntil, compact: true);
        return _StatusStrip(
          icon: CupertinoIcons.clock_fill,
          color: amber,
          fg: fg,
          dark: dark,
          title: tr('Limite de taxa (429)'),
          subtitle: until != null
              ? tr('Em espera · {t}', {'t': until})
              : tr('Aguardando liberação do provedor'),
          tight: tight,
        );
      }

      // Active percentage windows (always shown even when blocked/429/stale so real
      // numbers & reset timers stay visible at a glance).
      if (pctWindows.isNotEmpty) {
        // Single active percent window (e.g. Codex Pro with No 5h limit, or single-window tile).
        if (pctWindows.length == 1 && nativeWindows.isEmpty) {
          final w = pctWindows.first;
          final naNote = naWindows.isNotEmpty
              ? (naWindows.first.kind == 'five_hour'
                  ? tr('Sem limite 5h')
                  : tr('Não aplicável'))
              : null;
          return _HeroPercentMeter(
            window: w,
            showRemaining: config.showRemaining,
            showReset: config.showReset,
            accountStale: acct.isStale,
            accountBlocked: acct.isUsageBlocked,
            accent: accent,
            dark: dark,
            fg: fg,
            tight: tight,
            isRoomy: isRoomy,
            secondaryNote: naNote,
          );
        }

        // Two or three windows: generous stacked full-width meters.
        final displayList = [
          for (final w in windows)
            if (w.hasPercent || w.hasNativeCount || w.isNotApplicable) w,
        ];
        final rowsToShow = displayList.isNotEmpty ? displayList : pctWindows;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < rowsToShow.length; i++) ...[
              if (i > 0) SizedBox(height: isRoomy ? 12 : (tight ? 6 : 9)),
              _WideWindowMeter(
                window: rowsToShow[i],
                showRemaining: config.showRemaining,
                showResetInline: config.showReset,
                accountStale: acct.isStale,
                accountBlocked: acct.isUsageBlocked,
                accent: accent,
                dark: dark,
                fg: fg,
                tight: tight,
                isRoomy: isRoomy,
              ),
            ],
          ],
        );
      }

      // Native non-percent count (e.g. Gemini CLI daily local requests, Copilot credits).
      if (nativeWindows.isNotEmpty) {
        final w = nativeWindows.first;
        return _NativeCountStrip(
          window: w,
          accent: accent,
          dark: dark,
          fg: fg,
          tight: tight,
        );
      }

      // Honest waiting / unavailable / manual dashboard state (single clean strip,
      // never double empty hairlines and never fake 0%).
      if (acct.quotaStatus == 'awaiting_data') {
        return _StatusStrip(
          icon: CupertinoIcons.waveform_path_ecg,
          color: accent,
          fg: fg,
          dark: dark,
          title: tr('Aguardando uso'),
          subtitle: tr('Os limites aparecem após o uso normal da CLI'),
          tight: tight,
        );
      }
      final hasDashboard = acct.dashboardUrl != null && acct.dashboardUrl!.isNotEmpty;
      return _StatusStrip(
        icon: hasDashboard
            ? CupertinoIcons.arrow_up_right_square
            : CupertinoIcons.info_circle,
        color: amber,
        fg: fg,
        dark: dark,
        title: tr('Indisponível'),
        subtitle: acct.quotaStatus == 'manual_only' || hasDashboard
            ? tr('Toque para abrir o painel oficial')
            : tr('Nenhuma janela de uso reportada ainda'),
        tight: tight,
      );
    }

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.26,
      child: SizedBox(
        width: maxW,
        height: maxH,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _SpaciousHeader(
                style: style,
                accent: accent,
                dark: dark,
                fg: fg,
                title: title,
                aliasText: aliasText,
                planText: planText,
                dotColor: dotColor,
                pill: headerPill,
                tight: tight,
                isRoomy: isRoomy,
              ),
              Flexible(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    child: buildBody(),
                  ),
                ),
              ),
              if (isRoomy && acct.observedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    tr('Atualizado {quando}', {
                      'quando': formatObservedAge(acct.observedAt) ?? '',
                    }),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.0,
                      fontWeight: FontWeight.w500,
                      color: fg.withValues(alpha: 0.50),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SpaciousHeader extends StatelessWidget {
  final AiProviderStyle style;
  final Color accent;
  final bool dark;
  final Color fg;
  final String title;
  final String aliasText;
  final String? planText;
  final Color dotColor;
  final ({String text, Color color, IconData? icon})? pill;
  final bool tight;
  final bool isRoomy;

  const _SpaciousHeader({
    required this.style,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.title,
    required this.aliasText,
    required this.planText,
    required this.dotColor,
    required this.pill,
    required this.tight,
    required this.isRoomy,
  });

  @override
  Widget build(BuildContext context) {
    final badgeSize = isRoomy ? 40.0 : (tight ? 30.0 : 35.0);
    final iconSize = isRoomy ? 21.0 : (tight ? 16.0 : 19.0);
    final titleSize = isRoomy ? 17.5 : (tight ? 14.0 : 16.0);
    final subSize = isRoomy ? 12.5 : (tight ? 10.5 : 11.8);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AiProviderBadge(
          style: style,
          size: badgeSize,
          iconSize: iconSize,
          dark: dark,
          borderRadius: isRoomy ? 11.0 : 9.5,
          accentOverride: accent,
          useBrandGradient: style.key == 'antigravity' ||
              style.key == 'gemini_cli' ||
              style.key == 'gemini_web',
        ),
        SizedBox(width: tight ? 8 : 10),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: titleSize,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                        height: 1.1,
                        color: fg,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  if (planText != null) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: dark ? 0.20 : 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        planText!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: tight ? 9.5 : 10.5,
                          fontWeight: FontWeight.w700,
                          height: 1.05,
                          color: accent,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              if (aliasText.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  aliasText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: subSize,
                    fontWeight: FontWeight.w500,
                    height: 1.1,
                    color: fg.withValues(alpha: 0.62),
                  ),
                ),
              ],
            ],
          ),
        ),
        if (pill != null) ...[
          const SizedBox(width: 8),
          _HeaderPill(
            text: pill!.text,
            color: pill!.color,
            icon: pill!.icon,
            dark: dark,
            tight: tight,
          ),
        ],
      ],
    );
  }
}

class _WideWindowMeter extends StatelessWidget {
  final AiLimitsWindow window;
  final bool showRemaining;
  final bool showResetInline;
  final bool accountStale;
  final bool accountBlocked;
  final Color accent;
  final bool dark;
  final Color fg;
  final bool tight;
  final bool isRoomy;

  const _WideWindowMeter({
    required this.window,
    required this.showRemaining,
    required this.showResetInline,
    required this.accountStale,
    required this.accountBlocked,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.tight,
    required this.isRoomy,
  });

  @override
  Widget build(BuildContext context) {
    final stale = accountStale || window.isEffectivelyStale();
    final label = _windowLabelWithPool(window, _windowShortLabel(window));
    final labelSize = isRoomy ? 14.0 : (tight ? 12.0 : 13.0);
    final resetSize = isRoomy ? 12.0 : (tight ? 10.5 : 11.5);
    final pctSize = isRoomy ? 20.0 : (tight ? 15.0 : 18.0);
    final suffixSize = isRoomy ? 12.0 : (tight ? 10.5 : 11.5);
    final barHeight = isRoomy ? 10.0 : (tight ? 7.0 : 8.5);
    final trackColor = fg.withValues(alpha: dark ? 0.14 : 0.11);

    final resetInline = showResetInline && window.hasPercent && !window.isPastReset()
        ? formatAiResetTime(window.resetsAt, compact: true)
        : null;

    if (window.hasPercent) {
      final used = window.effectiveUsedPercent!;
      final shown = showRemaining ? window.effectiveRemainingPercent! : used;
      final rounded = shown.round();
      final barFill = (shown / 100.0).clamp(0.0, 1.0);
      final barCol = _meterColor(
        usedPercent: used,
        stale: stale,
        blocked: accountBlocked,
        accent: accent,
        dark: dark,
      );
      final valCol = _valueColor(
        usedPercent: used,
        stale: stale,
        blocked: accountBlocked,
        fg: fg,
        dark: dark,
      );
      final fullText = showRemaining
          ? tr('{p}% livre', {'p': '$rounded'})
          : tr('{p}% usado', {'p': '$rounded'});
      final pctToken = '$rounded%';

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: labelSize,
                          fontWeight: FontWeight.w700,
                          height: 1.1,
                          color: fg.withValues(alpha: 0.88),
                        ),
                      ),
                    ),
                    if (resetInline != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        resetInline,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: resetSize,
                          fontWeight: FontWeight.w500,
                          height: 1.1,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: fg.withValues(alpha: 0.50),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _RichPercentText(
                fullText: fullText,
                pctToken: pctToken,
                pctSize: pctSize,
                suffixSize: suffixSize,
                color: valCol,
                suffixColor: valCol.withValues(alpha: 0.72),
              ),
            ],
          ),
          SizedBox(height: tight ? 4 : 5),
          CapsuleBar(
            value: barFill,
            color: barCol,
            height: barHeight,
            track: trackColor,
          ),
        ],
      );
    }

    // Non-percent row (native count or not_applicable alongside another window).
    final String valueText;
    final Color valCol;
    if (window.hasNativeCount) {
      valueText = _formatNativeMetric(window);
      valCol = dark ? const Color(0xFF60A5FA) : const Color(0xFF0369A1);
    } else if (window.isNotApplicable) {
      valueText = window.kind == 'five_hour'
          ? tr('Sem limite 5h')
          : tr('Não aplicável');
      valCol = fg.withValues(alpha: 0.52);
    } else {
      valueText = tr('Indisponível');
      valCol = dark ? const Color(0xFFD6A86E) : const Color(0xFF9A6700);
    }

    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: labelSize,
              fontWeight: FontWeight.w600,
              color: fg.withValues(alpha: 0.72),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          valueText,
          maxLines: 1,
          style: TextStyle(
            fontSize: labelSize,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
            color: valCol,
          ),
        ),
      ],
    );
  }
}

/// Prominent single-window hero meter (e.g. Codex Pro with weekly-only pool, or
/// single-window tile configuration).
class _HeroPercentMeter extends StatelessWidget {
  final AiLimitsWindow window;
  final bool showRemaining;
  final bool showReset;
  final bool accountStale;
  final bool accountBlocked;
  final Color accent;
  final bool dark;
  final Color fg;
  final bool tight;
  final bool isRoomy;
  final String? secondaryNote;

  const _HeroPercentMeter({
    required this.window,
    required this.showRemaining,
    required this.showReset,
    required this.accountStale,
    required this.accountBlocked,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.tight,
    required this.isRoomy,
    this.secondaryNote,
  });

  @override
  Widget build(BuildContext context) {
    final used = window.effectiveUsedPercent!;
    final shown = showRemaining ? window.effectiveRemainingPercent! : used;
    final rounded = shown.round();
    final stale = accountStale || window.isEffectivelyStale();
    final label = _windowLabelWithPool(window, _windowShortLabel(window));
    final barCol = _meterColor(
      usedPercent: used,
      stale: stale,
      blocked: accountBlocked,
      accent: accent,
      dark: dark,
    );
    final valCol = _valueColor(
      usedPercent: used,
      stale: stale,
      blocked: accountBlocked,
      fg: fg,
      dark: dark,
    );
    final resetInline = showReset && !window.isPastReset()
        ? formatAiResetTime(window.resetsAt, compact: true)
        : null;
    final fullText = showRemaining
        ? tr('{p}% livre', {'p': '$rounded'})
        : tr('{p}% usado', {'p': '$rounded'});

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: isRoomy ? 15.0 : 13.5,
                            fontWeight: FontWeight.w700,
                            color: fg.withValues(alpha: 0.88),
                          ),
                        ),
                      ),
                      if (resetInline != null) ...[
                        const SizedBox(width: 6),
                        Text(
                          resetInline,
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 12.0,
                            fontWeight: FontWeight.w500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: fg.withValues(alpha: 0.50),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (secondaryNote != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      secondaryNote!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.0,
                        fontWeight: FontWeight.w500,
                        color: fg.withValues(alpha: 0.52),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            _RichPercentText(
              fullText: fullText,
              pctToken: '$rounded%',
              pctSize: isRoomy ? 26.0 : (tight ? 20.0 : 24.0),
              suffixSize: isRoomy ? 13.0 : 12.0,
              color: valCol,
              suffixColor: valCol.withValues(alpha: 0.72),
            ),
          ],
        ),
        SizedBox(height: tight ? 6 : 8),
        CapsuleBar(
          value: (shown / 100.0).clamp(0.0, 1.0),
          color: barCol,
          height: isRoomy ? 11.0 : (tight ? 8.0 : 10.0),
          track: fg.withValues(alpha: dark ? 0.14 : 0.11),
        ),
      ],
    );
  }
}

/// Renders `"42% used"` / `"58% left"` with a large bold tabular percentage and a
/// lighter unit suffix in one single [Text.rich] so layout is sharp and accessibility
/// reads one natural phrase.
class _RichPercentText extends StatelessWidget {
  final String fullText;
  final String pctToken;
  final double pctSize;
  final double suffixSize;
  final Color color;
  final Color suffixColor;

  const _RichPercentText({
    required this.fullText,
    required this.pctToken,
    required this.pctSize,
    required this.suffixSize,
    required this.color,
    required this.suffixColor,
  });

  @override
  Widget build(BuildContext context) {
    final idx = fullText.indexOf(pctToken);
    final pctStyle = TextStyle(
      fontSize: pctSize,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.4,
      height: 1.0,
      fontFeatures: const [FontFeature.tabularFigures()],
      color: color,
    );
    final restStyle = TextStyle(
      fontSize: suffixSize,
      fontWeight: FontWeight.w600,
      height: 1.0,
      color: suffixColor,
    );
    if (idx < 0) {
      return Text(fullText, maxLines: 1, style: pctStyle);
    }
    final before = fullText.substring(0, idx);
    final after = fullText.substring(idx + pctToken.length);
    return Text.rich(
      TextSpan(
        children: [
          if (before.isNotEmpty) TextSpan(text: before, style: restStyle),
          TextSpan(text: pctToken, style: pctStyle),
          if (after.isNotEmpty) TextSpan(text: after, style: restStyle),
        ],
      ),
      maxLines: 1,
    );
  }
}

class _NativeCountStrip extends StatelessWidget {
  final AiLimitsWindow window;
  final Color accent;
  final bool dark;
  final Color fg;
  final bool tight;

  const _NativeCountStrip({
    required this.window,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.tight,
  });

  @override
  Widget build(BuildContext context) {
    final label = _windowLabelWithPool(window, _windowShortLabel(window));
    final valueText = _formatNativeMetric(window);
    final valueColor = dark ? const Color(0xFF60A5FA) : const Color(0xFF0369A1);
    final barFill = window.limit != null && window.limit! > 0
        ? (window.used! / window.limit!).clamp(0.0, 1.0)
        : null;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tight ? 10 : 12,
        vertical: tight ? 8 : 10,
      ),
      decoration: BoxDecoration(
        color: fg.withValues(alpha: dark ? 0.06 : 0.045),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: tight ? 12.0 : 13.0,
                        fontWeight: FontWeight.w700,
                        color: fg.withValues(alpha: 0.86),
                      ),
                    ),
                    Text(
                      tr('Contagem local'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.0,
                        fontWeight: FontWeight.w500,
                        color: fg.withValues(alpha: 0.54),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                valueText,
                maxLines: 1,
                style: TextStyle(
                  fontSize: tight ? 17.0 : 20.0,
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: valueColor,
                ),
              ),
            ],
          ),
          if (barFill != null) ...[
            const SizedBox(height: 6),
            CapsuleBar(
              value: barFill,
              color: accent,
              height: 7,
              track: fg.withValues(alpha: dark ? 0.14 : 0.11),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusStrip extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Color fg;
  final bool dark;
  final String title;
  final String? subtitle;
  final bool tight;

  const _StatusStrip({
    required this.icon,
    required this.color,
    required this.fg,
    required this.dark,
    required this.title,
    this.subtitle,
    required this.tight,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tight ? 10 : 12,
        vertical: tight ? 8 : 11,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.13 : 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: color.withValues(alpha: dark ? 0.24 : 0.16),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: tight ? 17 : 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: tight ? 12.5 : 13.5,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    color: fg,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: tight ? 10.5 : 11.5,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
                      color: fg.withValues(alpha: 0.62),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact horizontal layout (when tile height is tight or user picked Compact density):
/// shows clear provider header + the single highest-priority metric with a crisp bar.
class _CompactHorizontalAiTile extends StatelessWidget {
  final AiLimitsAccount acct;
  final AiLimitsTileConfig config;
  final List<AiLimitsWindow> windows;
  final AiProviderStyle style;
  final Color accent;
  final bool dark;
  final Color fg;
  final String title;
  final String aliasText;
  final String? planText;
  final Color dotColor;
  final ({String text, Color color, IconData? icon})? headerPill;
  final double maxW;
  final double maxH;

  const _CompactHorizontalAiTile({
    required this.acct,
    required this.config,
    required this.windows,
    required this.style,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.title,
    required this.aliasText,
    required this.planText,
    required this.dotColor,
    required this.headerPill,
    required this.maxW,
    required this.maxH,
  });

  @override
  Widget build(BuildContext context) {
    final primary = _prioritizedWindow(windows);
    final amber = dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309);

    Widget bottomMetric() {
      if (!acct.enabled) {
        return _InlineNote(text: tr('Conta desativada'), color: fg.withValues(alpha: 0.58));
      }
      if (acct.isAuthRequired) {
        return _InlineNote(text: tr('Autenticação necessária'), color: DeckTileColors.red);
      }
      if (acct.isRateLimited && (primary == null || !primary.hasPercent)) {
        return _InlineNote(text: tr('Limite de taxa (429)'), color: amber);
      }
      if (primary != null && primary.hasPercent) {
        final used = primary.effectiveUsedPercent!;
        final shown = config.showRemaining ? primary.effectiveRemainingPercent! : used;
        final rounded = shown.round();
        final stale = acct.isStale || primary.isEffectivelyStale();
        final label = _windowLabelWithPool(primary, _windowShortLabel(primary));
        final valText = config.showRemaining
            ? tr('{p}% livre', {'p': '$rounded'})
            : tr('{p}% usado', {'p': '$rounded'});
        final barCol = _meterColor(
          usedPercent: used,
          stale: stale,
          blocked: acct.isUsageBlocked,
          accent: accent,
          dark: dark,
        );
        final valCol = _valueColor(
          usedPercent: used,
          stale: stale,
          blocked: acct.isUsageBlocked,
          fg: fg,
          dark: dark,
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: fg.withValues(alpha: 0.78),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _RichPercentText(
                  fullText: valText,
                  pctToken: '$rounded%',
                  pctSize: 15.0,
                  suffixSize: 10.5,
                  color: valCol,
                  suffixColor: valCol.withValues(alpha: 0.72),
                ),
              ],
            ),
            const SizedBox(height: 4),
            CapsuleBar(
              value: (shown / 100.0).clamp(0.0, 1.0),
              color: barCol,
              height: 6.5,
              track: fg.withValues(alpha: dark ? 0.14 : 0.11),
            ),
          ],
        );
      }
      if (primary != null && primary.hasNativeCount) {
        return Row(
          children: [
            Expanded(
              child: Text(
                _windowShortLabel(primary),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: fg.withValues(alpha: 0.7)),
              ),
            ),
            Text(
              _formatNativeMetric(primary),
              style: TextStyle(
                fontSize: 14.0,
                fontWeight: FontWeight.w800,
                color: dark ? const Color(0xFF60A5FA) : const Color(0xFF0369A1),
              ),
            ),
          ],
        );
      }
      return _InlineNote(
        text: acct.quotaStatus == 'awaiting_data' ? tr('Aguardando uso') : tr('Indisponível'),
        color: acct.quotaStatus == 'awaiting_data' ? fg.withValues(alpha: 0.65) : amber,
      );
    }

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: SizedBox(
        width: maxW,
        height: maxH,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  AiProviderBadge(
                    style: style,
                    size: 24,
                    iconSize: 14,
                    dark: dark,
                    borderRadius: 7,
                    showBorder: false,
                    accentOverride: accent,
                    useBrandGradient: style.key == 'antigravity' ||
                        style.key == 'gemini_cli' ||
                        style.key == 'gemini_web',
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      aliasText.isNotEmpty ? '$title · $aliasText' : title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                  ),
                  if (headerPill != null) ...[
                    const SizedBox(width: 6),
                    _CompactBadge(text: headerPill!.text, color: headerPill!.color, dark: dark),
                  ],
                ],
              ),
              bottomMetric(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Square / 1×1 single-focus glanceable layout: prioritizes the most constrained window
/// with a big readable percentage and one clean bar instead of cramming two tiny rows.
class _SquareAiTile extends StatelessWidget {
  final AiLimitsAccount acct;
  final AiLimitsTileConfig config;
  final List<AiLimitsWindow> windows;
  final AiProviderStyle style;
  final Color accent;
  final bool dark;
  final Color fg;
  final String title;
  final String aliasText;
  final Color dotColor;
  final ({String text, Color color, IconData? icon})? headerPill;
  final double maxW;
  final double maxH;

  const _SquareAiTile({
    required this.acct,
    required this.config,
    required this.windows,
    required this.style,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.title,
    required this.aliasText,
    required this.dotColor,
    required this.headerPill,
    required this.maxW,
    required this.maxH,
  });

  @override
  Widget build(BuildContext context) {
    final primary = _prioritizedWindow(windows);
    final tiny = maxW < 92 || maxH < 92;
    final micro = maxW < 70 || maxH < 70;
    final amber = dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309);

    Widget centerHero() {
      if (!acct.enabled) {
        return _SquareStatus(label: tr('Desativado'), color: fg.withValues(alpha: 0.58), tiny: tiny);
      }
      if (acct.isAuthRequired) {
        return _SquareStatus(label: tr('Auth'), color: DeckTileColors.red, tiny: tiny);
      }
      if (acct.isRateLimited && (primary == null || !primary.hasPercent)) {
        return _SquareStatus(label: tr('429'), color: amber, tiny: tiny);
      }
      if (primary != null && primary.hasPercent) {
        final used = primary.effectiveUsedPercent!;
        final shown = config.showRemaining ? primary.effectiveRemainingPercent! : used;
        final rounded = shown.round();
        final stale = acct.isStale || primary.isEffectivelyStale();
        final barCol = _meterColor(
          usedPercent: used,
          stale: stale,
          blocked: acct.isUsageBlocked,
          accent: accent,
          dark: dark,
        );
        final valCol = _valueColor(
          usedPercent: used,
          stale: stale,
          blocked: acct.isUsageBlocked,
          fg: fg,
          dark: dark,
        );
        final shortWin = _windowShortLabel(primary);
        final sub = config.showRemaining
            ? '$shortWin · ${tr('livre')}'
            : '$shortWin · ${tr('usado')}';
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                '$rounded%',
                style: TextStyle(
                  fontSize: micro ? 15.0 : (tiny ? 18.0 : 25.0),
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                  height: 1.0,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: valCol,
                ),
              ),
            ),
            if (!micro) ...[
              const SizedBox(height: 2),
              Text(
                sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: tiny ? 9.0 : 10.5,
                  fontWeight: FontWeight.w600,
                  color: fg.withValues(alpha: 0.62),
                ),
              ),
            ],
            SizedBox(height: micro ? 3 : (tiny ? 4 : 6)),
            CapsuleBar(
              value: (shown / 100.0).clamp(0.0, 1.0),
              color: barCol,
              height: micro ? 4.0 : (tiny ? 4.5 : 6.0),
              track: fg.withValues(alpha: dark ? 0.14 : 0.11),
            ),
          ],
        );
      }
      if (primary != null && primary.hasNativeCount) {
        return _SquareStatus(
          label: _formatNativeMetric(primary),
          color: dark ? const Color(0xFF60A5FA) : const Color(0xFF0369A1),
          tiny: tiny,
        );
      }
      return _SquareStatus(
        label: acct.quotaStatus == 'awaiting_data' ? tr('Aguardando') : tr('Indisponível'),
        color: acct.quotaStatus == 'awaiting_data' ? fg.withValues(alpha: 0.65) : amber,
        tiny: tiny,
      );
    }

    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.12,
      child: SizedBox(
        width: maxW,
        height: maxH,
        child: Padding(
          padding: EdgeInsets.all(tiny ? 1 : 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  AiProviderBadge(
                    style: style,
                    size: micro ? 16 : (tiny ? 18 : 24),
                    iconSize: micro ? 10 : (tiny ? 11 : 14),
                    dark: dark,
                    borderRadius: tiny ? 5 : 7,
                    showBorder: false,
                    accentOverride: accent,
                    useBrandGradient: style.key == 'antigravity' ||
                        style.key == 'gemini_cli' ||
                        style.key == 'gemini_web',
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: micro ? 9.5 : (tiny ? 10.0 : 12.0),
                        fontWeight: FontWeight.w700,
                        color: fg,
                      ),
                    ),
                  ),
                  const SizedBox(width: 3),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
                  ),
                ],
              ),
              Flexible(
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: micro
                      ? FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.bottomLeft,
                          child: SizedBox(
                            width: math.max(24.0, maxW - 4),
                            child: centerHero(),
                          ),
                        )
                      : SingleChildScrollView(
                          physics: const NeverScrollableScrollPhysics(),
                          child: centerHero(),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SquareStatus extends StatelessWidget {
  final String label;
  final Color color;
  final bool tiny;

  const _SquareStatus({
    required this.label,
    required this.color,
    required this.tiny,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          fontSize: tiny ? 11.5 : 14.0,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

class _HeaderPill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final bool dark;
  final bool tight;

  const _HeaderPill({
    required this.text,
    required this.color,
    required this.icon,
    required this.dark,
    this.tight = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: tight ? 7.0 : 9.0,
        vertical: tight ? 3.5 : 4.5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: color.withValues(alpha: dark ? 0.28 : 0.18),
          width: 0.8,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: tight ? 10.5 : 12.0, color: color),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            maxLines: 1,
            style: TextStyle(
              fontSize: tight ? 10.0 : 11.2,
              fontWeight: FontWeight.w700,
              height: 1.05,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactBadge extends StatelessWidget {
  final String text;
  final Color color;
  final bool dark;

  const _CompactBadge({
    required this.text,
    required this.color,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.18 : 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          height: 1.05,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: color,
        ),
      ),
    );
  }
}

class _StatusTileLayout extends StatelessWidget {
  final AiProviderStyle style;
  final IconData? overrideIcon;
  final Color accent;
  final bool dark;
  final Color fg;
  final String title;
  final String badge;
  final Color badgeColor;
  final String message;
  final String? hint;

  const _StatusTileLayout({
    required this.style,
    this.overrideIcon,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.title,
    required this.badge,
    required this.badgeColor,
    required this.message,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth.isFinite ? c.maxWidth : 240.0;
        final h = c.maxHeight.isFinite ? c.maxHeight : 120.0;
        final small = w < 150 || h < 90;
        final micro = w < 88 || h < 64;
        return MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.2,
          child: SizedBox(
            width: w,
            height: h,
            child: Padding(
              padding: EdgeInsets.all(micro ? 1 : (small ? 2 : 4)),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (overrideIcon != null)
                        Container(
                          width: micro ? 16 : (small ? 22 : 30),
                          height: micro ? 16 : (small ? 22 : 30),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: dark ? 0.24 : 0.14),
                            borderRadius: BorderRadius.circular(micro ? 5 : (small ? 6 : 8)),
                          ),
                          child: Icon(
                            overrideIcon,
                            size: micro ? 9.5 : (small ? 12 : 16),
                            color: accent,
                          ),
                        )
                      else
                        AiProviderBadge(
                          style: style,
                          size: micro ? 16 : (small ? 22 : 30),
                          iconSize: micro ? 10 : (small ? 12.5 : 16.5),
                          dark: dark,
                          borderRadius: micro ? 5 : (small ? 6 : 8),
                          showBorder: !micro,
                          accentOverride: accent,
                          useBrandGradient: style.key == 'antigravity' ||
                              style.key == 'gemini_cli' ||
                              style.key == 'gemini_web',
                        ),
                      SizedBox(width: micro ? 4 : 8),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: micro ? 9.5 : (small ? 11.5 : 14.5),
                            fontWeight: FontWeight.w700,
                            color: fg,
                          ),
                        ),
                      ),
                      if (!micro) ...[
                        const SizedBox(width: 6),
                        Flexible(
                          flex: 0,
                          child: _CompactBadge(text: badge, color: badgeColor, dark: dark),
                        ),
                      ],
                    ],
                  ),
                  Flexible(
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              micro ? badge : message,
                              maxLines: micro ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: micro ? 9.0 : (small ? 10.5 : 13.0),
                                fontWeight: FontWeight.w600,
                                height: 1.2,
                                color: micro ? badgeColor : fg.withValues(alpha: 0.85),
                              ),
                            ),
                            if (!small && hint != null && hint!.isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                hint!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.0,
                                  fontWeight: FontWeight.w500,
                                  color: fg.withValues(alpha: 0.56),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LoadingTileLayout extends StatelessWidget {
  final AiProviderStyle style;
  final Color accent;
  final bool dark;
  final Color fg;
  final String title;

  const _LoadingTileLayout({
    required this.style,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AiProviderIcon(
                style: style,
                size: 16,
                color: accent,
                useBrandGradient: style.key == 'antigravity' ||
                    style.key == 'gemini_cli' ||
                    style.key == 'gemini_web',
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const CupertinoActivityIndicator(radius: 9),
        ],
      ),
    );
  }
}

class _InlineNote extends StatelessWidget {
  final String text;
  final Color color;

  const _InlineNote({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 12.0,
        fontWeight: FontWeight.w600,
        height: 1.2,
        color: color,
      ),
    );
  }
}

String _windowShortLabel(AiLimitsWindow w) => switch (w.kind) {
      'five_hour' => tr('5h'),
      'weekly' => tr('Semanal'),
      'daily' => tr('Diário'),
      'monthly' => tr('Mensal'),
      'spend_limit' => tr('Gasto'),
      'credits' => tr('Créditos'),
      _ => w.label.isNotEmpty ? w.label : w.kind,
    };

/// Shared wording for the account dashboard and deck tiles.
String aiWindowShortLabel(AiLimitsWindow w) => _windowShortLabel(w);
String aiWindowLabelWithPool(AiLimitsWindow w, String base) => _windowLabelWithPool(w, base);
String aiFormatNativeMetric(AiLimitsWindow w) => _formatNativeMetric(w);

/// Adds the model pool name for extra pools ("5h · Spark") so two 5h rows never look alike.
String _windowLabelWithPool(AiLimitsWindow w, String base) {
  if (w.isMainPool) return base;
  final pool = w.modelPool!.trim();
  return base.toLowerCase().contains(pool.toLowerCase()) ? base : '$base · $pool';
}

String _formatNumber(double v) {
  if ((v - v.roundToDouble()).abs() < 0.01) return '${v.round()}';
  return decimalText(v.toStringAsFixed(2));
}

/// Formats non-percent metrics strictly from backend-reported values (never invents denominators).
String _formatNativeMetric(AiLimitsWindow w) {
  final used = w.used;
  if (used == null) return tr('Indisponível');
  final u = _formatNumber(used);
  final lim = w.limit != null && w.limit! > 0 ? _formatNumber(w.limit!) : null;
  return switch (w.unit) {
    'usd' => lim != null ? '\$$u / \$$lim' : '\$$u',
    'requests' => lim != null ? '$u / $lim ${tr('req')}' : '$u ${tr('req')}',
    'credits' => lim != null ? '$u / $lim ${tr('créd.')}' : '$u ${tr('créd.')}',
    'tokens' => lim != null ? '$u / $lim tok' : '$u tok',
    _ => lim != null ? '$u / $lim' : u,
  };
}

/// Opens the live quota detail sheet for a bound (or repairable) `ai_limits` tile.
Future<void> showAiLimitsDetailSheet(
  BuildContext context,
  DeckButton button, {
  VoidCallback? onEditTile,
  VoidCallback? onSettingsClosed,
}) {
  final config = AiLimitsTileConfig.fromParams(button.dynamicParameters);
  AiLimitsStore.instance.ensureInitialized();
  if (config.combined) return showAiLimitsCombinedSheet(context, button, onEditTile: onEditTile, onSettingsClosed: onSettingsClosed);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => _AiLimitsDetailSheet(
      button: button,
      config: config,
      onEditTile: onEditTile,
      onSettingsClosed: onSettingsClosed,
    ),
  );
}

class _AiLimitsDetailSheet extends StatefulWidget {
  final DeckButton button;
  final AiLimitsTileConfig config;
  final VoidCallback? onEditTile;
  final VoidCallback? onSettingsClosed;

  const _AiLimitsDetailSheet({
    required this.button,
    required this.config,
    this.onEditTile,
    this.onSettingsClosed,
  });

  @override
  State<_AiLimitsDetailSheet> createState() => _AiLimitsDetailSheetState();
}

class _AiLimitsDetailSheetState extends State<_AiLimitsDetailSheet> {
  bool _showDetails = false;
  late bool _showRemaining = widget.config.showRemaining;
  Timer? _cooldownTick;

  @override
  void initState() {
    super.initState();
    _cooldownTick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && AiLimitsStore.instance.remainingCooldownSeconds() > 0) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _cooldownTick?.cancel();
    super.dispose();
  }

  Future<void> _openSettings() async {
    final nav = Navigator.of(context);
    nav.pop();
    await nav.push(
      MaterialPageRoute(builder: (_) => const AiLimitsSettingsPage()),
    );
    widget.onSettingsClosed?.call();
  }

  Future<void> _openDashboard(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final dark = c.isDark;

    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Container(
            margin: const EdgeInsets.all(AppleSpacing.md),
            decoration: BoxDecoration(
              color: c.secondaryGroupedBackground,
              borderRadius: BorderRadius.circular(AppleRadii.xl),
              border: Border.all(color: c.separator, width: 1),
              boxShadow: AppleShadows.floating(Theme.of(context).brightness),
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(AppleSpacing.md),
              child: Watch((context) {
                final store = AiLimitsStore.instance;
                final snap = store.snapshot.value;
                final refreshing = store.isRefreshing.value;
                final cooldown = store.remainingCooldownSeconds();
                final notice = store.lastNotice.value;
                final acct = widget.config.isBound
                    ? snap?.accountById(widget.config.accountId)
                    : null;
                final style = AiProviderStyle.resolve(
                  acct?.provider ?? widget.config.providerHint,
                  fallbackLabel: acct?.providerLabel,
                );
                final accent = style.legibleOn(dark: dark);

                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        AiProviderBadge(
                          style: style,
                          size: 40,
                          iconSize: 21,
                          dark: dark,
                          borderRadius: AppleRadii.sm,
                          accentOverride: accent,
                          useBrandGradient: style.key == 'antigravity' ||
                              style.key == 'gemini_cli' ||
                              style.key == 'gemini_web',
                        ),
                        const SizedBox(width: AppleSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                acct?.displayTitle ??
                                    (widget.config.aliasHint.isNotEmpty
                                        ? '${style.displayName} · ${widget.config.aliasHint}'
                                        : tr('Limites de IA')),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: type.headline.copyWith(color: c.label),
                              ),
                              if (acct != null)
                                Text(
                                  [
                                    if (acct.plan != null) acct.plan!,
                                    _connectionLabel(acct),
                                    if (acct.observedAt != null)
                                      formatObservedAge(acct.observedAt) ?? '',
                                  ].where((s) => s.isNotEmpty).join(' · '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: type.caption1.copyWith(color: c.secondaryLabel),
                                ),
                            ],
                          ),
                        ),
                        if (acct != null)
                          IconButton(
                            tooltip: acct.isAuthRequired
                                ? tr('Autenticação necessária')
                                : (cooldown > 0
                                    ? tr('Aguarde {s}s', {'s': '$cooldown'})
                                    : tr('Atualizar agora')),
                            onPressed: (refreshing || cooldown > 0 || acct.isAuthRequired)
                                ? null
                                : () => store.refresh(sourceId: acct.sourceId),
                            icon: refreshing
                                ? const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Icon(
                                    Icons.refresh_rounded,
                                    size: 20,
                                    color: (cooldown > 0 || acct.isAuthRequired)
                                        ? c.tertiaryLabel
                                        : c.accent,
                                  ),
                          ),
                      ],
                    ),
                    if (notice != null && notice.isNotEmpty) ...[
                      const SizedBox(height: AppleSpacing.xs),
                      Text(
                        notice,
                        style: type.caption1.copyWith(color: c.orange),
                      ),
                    ],
                    const SizedBox(height: AppleSpacing.sm),
                    if (acct == null) ...[
                      _RepairBanner(
                        title: widget.config.isBound
                            ? tr('Esta conta não está mais conectada')
                            : tr('Nenhuma conta vinculada a esta tecla'),
                        message: widget.config.isBound
                            ? tr('A posição e o tamanho da tecla foram mantidos. Reconecte a fonte ou escolha outra conta.')
                            : tr('Conecte uma fonte em Ajustes → Limites de IA para acompanhar suas assinaturas.'),
                        onOpenSettings: _openSettings,
                      ),
                    ] else ...[
                      if (acct.isUsageBlocked) ...[
                        _InfoCallout(
                          color: c.red,
                          text: tr('Uso comum bloqueado pelo provedor nesta conta até a liberação da janela.'),
                        ),
                        const SizedBox(height: AppleSpacing.sm),
                      ],
                      if (acct.statusMessage != null && acct.statusMessage!.isNotEmpty) ...[
                        _InfoCallout(
                          color: acct.isAuthRequired ? c.red : c.orange,
                          text: acct.statusMessage!,
                        ),
                        const SizedBox(height: AppleSpacing.sm),
                      ],
                      if (acct.windows.any((w) => w.hasPercent)) ...[
                        SegmentedButton<bool>(
                          segments: [
                            ButtonSegment(value: false, label: Text(tr('% usado'))),
                            ButtonSegment(value: true, label: Text(tr('% livre'))),
                          ],
                          selected: {_showRemaining},
                          onSelectionChanged: (v) =>
                              setState(() => _showRemaining = v.first),
                        ),
                        const SizedBox(height: AppleSpacing.sm),
                      ],
                      if (acct.windows.isEmpty)
                        _InfoCallout(
                          color: c.secondaryLabel,
                          text: acct.quotaStatus == 'manual_only'
                              ? tr('Este serviço não oferece API oficial de limite restante. Abra o painel oficial abaixo.')
                              : acct.quotaStatus == 'awaiting_data'
                                  ? tr('Os limites aparecem após o uso normal da CLI')
                                  : tr('Ainda não há janelas de uso disponíveis para esta conta.'),
                        )
                      else
                        for (final w in acct.windows) ...[
                          _DetailWindowCard(
                            window: w,
                            showRemaining: _showRemaining,
                            accountStale: acct.isStale,
                            accent: accent,
                          ),
                          const SizedBox(height: AppleSpacing.xs),
                        ],
                      if (acct.dashboardUrl != null && acct.dashboardUrl!.isNotEmpty) ...[
                        const SizedBox(height: AppleSpacing.xs),
                        SecondaryButton(
                          label: tr('Abrir painel oficial'),
                          icon: Icons.open_in_new_rounded,
                          expand: true,
                          onPressed: () => _openDashboard(acct.dashboardUrl!),
                        ),
                      ],
                      const SizedBox(height: AppleSpacing.xs),
                      InkWell(
                        borderRadius: BorderRadius.circular(AppleRadii.sm),
                        onTap: () => setState(() => _showDetails = !_showDetails),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Row(
                            children: [
                              Icon(
                                _showDetails
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                                size: 18,
                                color: c.secondaryLabel,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                tr('Detalhes da fonte'),
                                style: type.caption1.copyWith(
                                  color: c.secondaryLabel,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_showDetails)
                        Container(
                          padding: const EdgeInsets.all(AppleSpacing.sm),
                          decoration: BoxDecoration(
                            color: c.tertiaryGroupedBackground,
                            borderRadius: BorderRadius.circular(AppleRadii.md),
                            border: Border.all(color: c.separator, width: 0.75),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (acct.provenanceLabel != null)
                                Text(
                                  acct.provenanceLabel!,
                                  style: type.caption1.copyWith(
                                    color: c.label,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              if (acct.provenanceDetails != null) ...[
                                const SizedBox(height: 3),
                                Text(
                                  acct.provenanceDetails!,
                                  style: type.caption1.copyWith(color: c.secondaryLabel),
                                ),
                              ],
                              const SizedBox(height: 4),
                              Text(
                                '${tr('Estado da cota')}: ${_quotaStatusLabel(acct.quotaStatus)}',
                                style: type.caption2.copyWith(color: c.tertiaryLabel),
                              ),
                              if (_sourceAttribution(acct.sourceKind) != null) ...[
                                const SizedBox(height: 3),
                                Text(
                                  _sourceAttribution(acct.sourceKind)!,
                                  style: type.caption2.copyWith(color: c.tertiaryLabel),
                                ),
                              ],
                            ],
                          ),
                        ),
                    ],
                    const SizedBox(height: AppleSpacing.md),
                    // Wraps instead of overflowing with large text or long translations.
                    OverflowBar(
                      alignment: MainAxisAlignment.spaceBetween,
                      overflowAlignment: OverflowBarAlignment.end,
                      children: [
                        Wrap(
                          children: [
                            TextButton.icon(
                              onPressed: _openSettings,
                              icon: const Icon(Icons.tune_rounded, size: 16),
                              label: Text(tr('Limites de IA')),
                            ),
                            if (widget.onEditTile != null)
                              TextButton(
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  widget.onEditTile!.call();
                                },
                                child: Text(tr('Editar')),
                              ),
                          ],
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: Text(tr('Fechar')),
                        ),
                      ],
                    ),
                  ],
                );
              }),
            ),
          ),
        ),
      ),
    );
  }

  static String _connectionLabel(AiLimitsAccount acct) => switch (acct.connectionStatus) {
        'connected' => tr('Conectado'),
        'auth_required' => tr('Autenticação necessária'),
        'offline' => tr('Offline'),
        'setup_required' => tr('Configuração pendente'),
        'disabled' => tr('Desativado'),
        _ => tr('Indisponível'),
      };

  static String _quotaStatusLabel(String status) => switch (status) {
        'ok' => tr('Atualizado'),
        'stale' => tr('Antigo'),
        'rate_limited' => tr('Limite de taxa (429)'),
        'cooldown' => tr('Em espera'),
        'awaiting_data' => tr('Aguardando dados'),
        'auth_required' => tr('Autenticação necessária'),
        'manual_only' => tr('Somente painel oficial'),
        'local_only' => tr('Contagem local'),
        _ => tr('Indisponível'),
      };

  static String? _sourceAttribution(String kind) => switch (kind) {
        'cliproxy_passive' =>
          'CLIProxyAPI Management API v8 (MIT) · passive read-only',
        'codex_local' =>
          'OpenAI codex app-server stdio:// · patterns informed by CodexBar (MIT)',
        'claude_statusline' =>
          'Claude Code statusLine · patterns informed by Claude-Code-Usage-Monitor (MIT)',
        'gemini_local_otel' =>
          'Gemini CLI OpenTelemetry (local outfile)',
        _ => null,
      };
}

class _DetailWindowCard extends StatelessWidget {
  final AiLimitsWindow window;
  final bool showRemaining;
  final bool accountStale;
  final Color accent;

  const _DetailWindowCard({
    required this.window,
    required this.showRemaining,
    required this.accountStale,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final stale = accountStale || window.isEffectivelyStale();
    final resetStr = window.isPastReset() ? null : formatAiResetTime(window.resetsAt);

    final String rightValue;
    final Color rightColor;
    double? barFill;
    Color barColor = accent;

    if (window.hasPercent) {
      final used = window.effectiveUsedPercent!;
      final shown = showRemaining ? window.effectiveRemainingPercent! : used;
      rightValue = showRemaining
          ? tr('{p}% livre', {'p': '${shown.round()}'})
          : tr('{p}% usado', {'p': '${shown.round()}'});
      barFill = (shown / 100.0).clamp(0.0, 1.0);
      if (stale) {
        rightColor = c.orange;
        barColor = c.orange;
      } else if (used >= 90) {
        rightColor = c.red;
        barColor = c.red;
      } else if (used >= 70) {
        rightColor = c.orange;
        barColor = c.orange;
      } else {
        rightColor = c.label;
      }
    } else if (window.hasNativeCount) {
      rightValue = _formatNativeMetric(window);
      rightColor = c.accent;
    } else if (window.isNotApplicable) {
      rightValue = window.kind == 'five_hour'
          ? tr('Sem limite 5h')
          : tr('Não aplicável');
      rightColor = c.secondaryLabel;
    } else if (window.isRateLimited) {
      rightValue = tr('Limite de taxa (429)');
      rightColor = c.orange;
    } else if (window.isAuthRequired) {
      rightValue = tr('Autenticação necessária');
      rightColor = c.red;
    } else if (window.isNotConnected) {
      rightValue = tr('Não conectado');
      rightColor = c.secondaryLabel;
    } else {
      rightValue = tr('Uso indisponível');
      rightColor = c.orange;
    }

    return Container(
      padding: const EdgeInsets.all(AppleSpacing.sm),
      decoration: BoxDecoration(
        color: c.tertiaryGroupedBackground,
        borderRadius: BorderRadius.circular(AppleRadii.md),
        border: Border.all(color: c.separator, width: 0.75),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _windowLabelWithPool(
                    window,
                    window.label.isNotEmpty ? window.label : _windowShortLabel(window),
                  ),
                  style: type.subheadline.copyWith(
                    color: c.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                rightValue,
                style: type.subheadline.copyWith(
                  color: rightColor,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (barFill != null) ...[
            const SizedBox(height: 6),
            CapsuleBar(
              value: barFill,
              color: barColor,
              height: 7.5,
              track: c.fill,
            ),
          ],
          if (resetStr != null ||
              stale ||
              (window.resetsAt == null && window.hasPercent) ||
              (window.note != null && window.note!.isNotEmpty)) ...[
            const SizedBox(height: 5),
            Text(
              [
                if (resetStr != null) tr('Reinicia: {t}', {'t': resetStr}),
                if (window.isPastReset())
                  tr('Reinício já passou, aguardando nova leitura')
                else if (window.resetsAt == null && window.hasPercent)
                  tr('Reinício não informado'),
                if (stale) tr('Antigo'),
                if (window.note != null && window.note!.isNotEmpty) window.note!,
              ].join(' · '),
              style: type.caption1.copyWith(color: c.secondaryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

class _RepairBanner extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback onOpenSettings;

  const _RepairBanner({
    required this.title,
    required this.message,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Container(
      padding: const EdgeInsets.all(AppleSpacing.md),
      decoration: BoxDecoration(
        color: c.orange.withValues(alpha: c.isDark ? 0.16 : 0.10),
        borderRadius: BorderRadius.circular(AppleRadii.md),
        border: Border.all(color: c.orange.withValues(alpha: 0.30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: type.subheadline.copyWith(
              color: c.label,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            message,
            style: type.caption1.copyWith(color: c.secondaryLabel),
          ),
          const SizedBox(height: AppleSpacing.sm),
          PrimaryButton(
            label: tr('Abrir Limites de IA'),
            icon: Icons.tune_rounded,
            compact: true,
            onPressed: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

class _InfoCallout extends StatelessWidget {
  final Color color;
  final String text;

  const _InfoCallout({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    final type = AppleTextStyles.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppleRadii.md),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Text(
        text,
        style: type.caption1.copyWith(color: color),
      ),
    );
  }
}
