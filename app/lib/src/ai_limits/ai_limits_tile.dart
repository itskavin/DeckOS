import 'dart:async';
import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator, CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../stream_deck/buttons/colors.dart';
import '../stream_deck/widgets/usage_bars.dart' show CapsuleBar;
import 'ai_limits_models.dart';
import 'ai_limits_settings_page.dart';
import 'ai_limits_store.dart';
import 'ai_provider_style.dart';

/// Real live-bound AI quota tile drawn inside DeckOS's native [DeckTile] frame so
/// squircle geometry, glass/rim, shadows, font, themes, and press animations match
/// every other deck tile while supporting wide (2×1), square (1×1), and large (2×2) spans.
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
        icon: style.icon,
        accent: accent,
        dark: dark,
        fg: fg,
        title: (customLabel?.isNotEmpty ?? false) ? customLabel! : tr('Limites de IA'),
        badge: tr('Configurar'),
        badgeColor: dark ? const Color(0xFF60A5FA) : const Color(0xFF0369A1),
        message: tr('Conectar uma fonte'),
      );
    }

    // State 2: Initial load before any snapshot arrived.
    if (loading && account == null) {
      final fallbackTitle = (customLabel?.isNotEmpty ?? false)
          ? customLabel!
          : (config.aliasHint.isNotEmpty ? config.aliasHint : style.displayName);
      return _LoadingTileLayout(
        icon: style.icon,
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
          : (config.aliasHint.isNotEmpty
              ? '${style.displayName} · ${config.aliasHint}'
              : style.displayName);
      if (!hasSnapshot && storeError != null) {
        return _StatusTileLayout(
          icon: style.icon,
          accent: accent,
          dark: dark,
          fg: fg,
          title: fallbackTitle,
          badge: tr('Offline'),
          badgeColor: DeckTileColors.orange,
          message: tr('Sem resposta do PC'),
        );
      }
      return _StatusTileLayout(
        icon: CupertinoIcons.exclamationmark_triangle_fill,
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
    final title = (customLabel?.isNotEmpty ?? false)
        ? customLabel!
        : acct.providerLabel;
    final subtitleParts = <String>[
      if (acct.alias.isNotEmpty &&
          acct.alias.toLowerCase() != title.toLowerCase())
        acct.alias,
      if (acct.plan != null && acct.plan!.isNotEmpty) acct.plan!,
    ];
    final subtitle = subtitleParts.join(' · ');

    // Separate connection health dot from quota freshness.
    final Color dotColor = _connectionDotColor(acct, dark);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite ? constraints.maxWidth : 140.0;
        final maxH = constraints.maxHeight.isFinite ? constraints.maxHeight : 140.0;
        final isWide = maxW >= maxH * 1.32 && maxW >= 180;
        final isTall = maxH >= 175 && maxW >= 180;
        final compact = config.isCompact || (!isWide && maxW < 150);

        final maxWindows = isTall ? 3 : 2;
        final windows = acct.selectWindows(
          config.preferredWindowKinds,
          maxCount: maxWindows,
          pool: config.pool,
        );
        final headerPill = _headerPillFor(acct, config, windows, dark, fg);

        final rawTextScale =
            (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.0);
        final clampedScale = math.min(rawTextScale, 1.22);
        final minTargetW = isWide ? 220.0 : 132.0;
        final contentWidth = math.max(maxW, minTargetW * clampedScale);

        final padH = isWide ? 10.0 : 6.0;
        final padV = isWide ? 8.0 : 5.0;

        final body = MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.22,
          child: SizedBox(
            width: contentWidth,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: padH, vertical: padV),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TileHeader(
                    icon: style.icon,
                    accent: accent,
                    dark: dark,
                    fg: fg,
                    title: title,
                    subtitle: subtitle,
                    dotColor: dotColor,
                    pill: isWide ? headerPill : null,
                    compact: compact,
                  ),
                  if (!isWide && headerPill != null) ...[
                    const SizedBox(height: 3),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _CompactBadge(
                        text: headerPill.text,
                        color: headerPill.color,
                        dark: dark,
                      ),
                    ),
                  ],
                  SizedBox(height: isWide ? 8 : 6),
                  if (!acct.enabled)
                    _InlineNote(
                      text: tr('Conta desativada'),
                      color: fg.withValues(alpha: 0.56),
                    )
                  else if (acct.isAuthRequired)
                    _InlineNote(
                      text: tr('Autenticação necessária'),
                      color: DeckTileColors.red,
                    )
                  else if (acct.isRateLimited)
                    _InlineNote(
                      text: tr('Limite de taxa (429)'),
                      color: dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309),
                    )
                  else if (acct.isOffline && windows.every((w) => !w.hasPercent))
                    _InlineNote(
                      text: tr('Não conectado'),
                      color: fg.withValues(alpha: 0.58),
                    )
                  else if (windows.isEmpty)
                    _InlineNote(
                      text: acct.quotaStatus == 'manual_only'
                          ? tr('Somente painel oficial')
                          : acct.quotaStatus == 'awaiting_data'
                              ? tr('Aguardando dados')
                              : tr('Uso indisponível'),
                      color: fg.withValues(alpha: 0.60),
                    )
                  else
                    for (var i = 0; i < windows.length; i++) ...[
                      if (i > 0) SizedBox(height: isWide ? 7 : 5),
                      _LiveWindowRow(
                        window: windows[i],
                        showRemaining: config.showRemaining,
                        showResetInline: config.showReset && (isWide || isTall),
                        accountStale: acct.isStale,
                        accent: accent,
                        dark: dark,
                        fg: fg,
                        barHeight: isWide ? 6.0 : 4.5,
                      ),
                    ],
                  if (isTall && acct.observedAt != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      tr('Atualizado {quando}', {
                        'quando': formatObservedAge(acct.observedAt) ?? '',
                      }),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9.0,
                        fontWeight: FontWeight.w500,
                        color: fg.withValues(alpha: 0.48),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );

        return SizedBox(
          width: maxW,
          height: maxH,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: body,
          ),
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
          color: fg.withValues(alpha: 0.76),
          icon: CupertinoIcons.clock,
        );
      }
    }
    return null;
  }
}

class _TileHeader extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final bool dark;
  final Color fg;
  final String title;
  final String subtitle;
  final Color dotColor;
  final ({String text, Color color, IconData? icon})? pill;
  final bool compact;

  const _TileHeader({
    required this.icon,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.title,
    required this.subtitle,
    required this.dotColor,
    required this.pill,
    required this.compact,
  });

  @override
  Widget build(BuildContext context) {
    final badgeSize = compact ? 20.0 : 26.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: badgeSize,
          height: badgeSize,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: dark ? 0.22 : 0.14),
            borderRadius: BorderRadius.circular(compact ? 5.5 : 7.5),
            border: Border.all(
              color: accent.withValues(alpha: dark ? 0.34 : 0.24),
              width: 0.8,
            ),
          ),
          child: Icon(icon, size: compact ? 11.5 : 14.5, color: accent),
        ),
        SizedBox(width: compact ? 5 : 7),
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
                        fontSize: compact ? 11.0 : 12.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        height: 1.1,
                        color: fg,
                      ),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: dotColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              if (subtitle.isNotEmpty) ...[
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 8.8 : 9.8,
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
          const SizedBox(width: 6),
          _HeaderPill(
            text: pill!.text,
            color: pill!.color,
            icon: pill!.icon,
            dark: dark,
          ),
        ],
      ],
    );
  }
}

class _HeaderPill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  final bool dark;

  const _HeaderPill({
    required this.text,
    required this.color,
    required this.icon,
    required this.dark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6.5, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: color.withValues(alpha: dark ? 0.24 : 0.18),
          width: 0.75,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 9.5, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            text,
            maxLines: 1,
            style: TextStyle(
              fontSize: 8.8,
              fontWeight: FontWeight.w600,
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
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.16 : 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          fontSize: 8.0,
          fontWeight: FontWeight.w700,
          height: 1.05,
          fontFeatures: const [FontFeature.tabularFigures()],
          color: color,
        ),
      ),
    );
  }
}

class _LiveWindowRow extends StatelessWidget {
  final AiLimitsWindow window;
  final bool showRemaining;
  final bool showResetInline;
  final bool accountStale;
  final Color accent;
  final bool dark;
  final Color fg;
  final double barHeight;

  const _LiveWindowRow({
    required this.window,
    required this.showRemaining,
    required this.showResetInline,
    required this.accountStale,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.barHeight,
  });

  @override
  Widget build(BuildContext context) {
    final amber = dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309);
    final stale = accountStale || window.isEffectivelyStale();
    final label = _windowLabelWithPool(window, _windowShortLabel(window));

    final String valueText;
    final Color valueColor;
    double? barFill;
    Color barColor = accent;

    if (window.hasPercent) {
      final used = window.effectiveUsedPercent!;
      final shown = showRemaining ? window.effectiveRemainingPercent! : used;
      final rounded = shown.round();
      valueText = showRemaining
          ? tr('{p}% livre', {'p': '$rounded'})
          : tr('{p}% usado', {'p': '$rounded'});
      barFill = (shown / 100.0).clamp(0.0, 1.0);
      if (stale) {
        valueColor = amber;
        barColor = DeckTileColors.orange.withValues(alpha: 0.65);
      } else if (used > 85) {
        valueColor = DeckTileColors.red;
        barColor = DeckTileColors.red;
      } else if (used > 65) {
        valueColor = fg;
        barColor = accent;
      } else {
        valueColor = fg;
        barColor = accent;
      }
    } else if (window.hasNativeCount) {
      valueText = _formatNativeMetric(window);
      valueColor = dark ? const Color(0xFF60A5FA) : const Color(0xFF0369A1);
      barFill = null;
    } else if (window.isNotApplicable) {
      valueText = window.kind == 'five_hour'
          ? tr('Sem limite 5h')
          : tr('Não aplicável');
      valueColor = fg.withValues(alpha: 0.46);
    } else if (window.isRateLimited) {
      valueText = tr('429');
      valueColor = amber;
    } else if (window.isAuthRequired) {
      valueText = tr('Auth');
      valueColor = DeckTileColors.red;
    } else if (window.isNotConnected) {
      valueText = tr('Não conectado');
      valueColor = fg.withValues(alpha: 0.50);
    } else {
      valueText = tr('Indisponível');
      valueColor = dark ? const Color(0xFFD6A86E) : const Color(0xFF9A6700);
    }

    // A reset time that already passed isn't a countdown: the row is marked stale instead.
    final resetInline = showResetInline && window.hasPercent && !window.isPastReset()
        ? formatAiResetTime(window.resetsAt, compact: true)
        : null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Flexible(
              flex: 2,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 9.8,
                  fontWeight: FontWeight.w600,
                  height: 1.1,
                  color: fg.withValues(alpha: 0.72),
                ),
              ),
            ),
            if (resetInline != null) ...[
              const SizedBox(width: 5),
              Text(
                resetInline,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w500,
                  height: 1.1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: fg.withValues(alpha: 0.46),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Expanded(
              flex: 3,
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    valueText,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: barFill != null ? 10.5 : 9.2,
                      fontWeight: barFill != null ? FontWeight.w700 : FontWeight.w600,
                      height: 1.1,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: valueColor,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 3.5),
        if (barFill != null)
          CapsuleBar(
            value: barFill,
            color: barColor,
            height: barHeight,
          )
        else
          Container(
            height: 1.5,
            decoration: BoxDecoration(
              color: fg.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
            ),
          ),
      ],
    );
  }
}

class _StatusTileLayout extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final bool dark;
  final Color fg;
  final String title;
  final String badge;
  final Color badgeColor;
  final String message;

  const _StatusTileLayout({
    required this.icon,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.title,
    required this.badge,
    required this.badgeColor,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth.isFinite ? c.maxWidth : 140.0;
        final h = c.maxHeight.isFinite ? c.maxHeight : 120.0;
        return SizedBox(
          width: w,
          height: h,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.22,
              child: SizedBox(
                width: math.max(w, 136.0),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              color: accent.withValues(alpha: dark ? 0.22 : 0.14),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Icon(icon, size: 12.5, color: accent),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: fg,
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          _CompactBadge(text: badge, color: badgeColor, dark: dark),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 10.0,
                          fontWeight: FontWeight.w500,
                          color: fg.withValues(alpha: 0.68),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _LoadingTileLayout extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final bool dark;
  final Color fg;
  final String title;

  const _LoadingTileLayout({
    required this.icon,
    required this.accent,
    required this.dark,
    required this.fg,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: accent),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: fg,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const CupertinoActivityIndicator(radius: 8),
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
        fontSize: 10.0,
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
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: dark ? 0.22 : 0.14),
                            borderRadius: BorderRadius.circular(AppleRadii.sm),
                          ),
                          child: Icon(style.icon, size: 19, color: accent),
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
      } else if (used > 85) {
        rightColor = c.red;
        barColor = c.red;
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
              height: 6,
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
