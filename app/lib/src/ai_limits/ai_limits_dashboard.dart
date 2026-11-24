import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../stream_deck/widgets/usage_bars.dart';
import 'ai_limits_models.dart';
import 'ai_limits_tile.dart';
import 'ai_provider_icon.dart';
import 'ai_provider_style.dart';

/// Visual building blocks of Settings → AI Limits: a glanceable overview, one usage card per
/// account (rings for the main windows, rows for everything else) and section titles.
/// Every number comes from the backend reading; nothing is summed across accounts or pools.

/// Usage colour: the provider's colour while comfortable, orange when high, red near the cap.
Color aiUsageColor(AppleColors c, double usedPercent, Color accent, {bool stale = false}) {
  if (stale) return c.orange;
  if (usedPercent >= 90) return c.red;
  if (usedPercent >= 70) return c.orange;
  return accent;
}

/// "Resets in 42m" for the next 24 h, "Resets Thu 14:00" after that.
String? aiResetPhrase(AiLimitsWindow w, {DateTime? now}) {
  final r = w.resetsAt;
  if (r == null || w.isPastReset(now: now)) return null;
  final diff = r.toUtc().difference((now ?? DateTime.now()).toUtc());
  final t = formatAiResetTime(r, now: now, compact: true);
  if (t == null) return null;
  return diff.inHours < 24 ? tr('Reinicia em {t}', {'t': t}) : tr('Reinicia {t}', {'t': t});
}

/// Main-pool windows with a real percentage, best first (5h, weekly, then the rest), max 2.
List<AiLimitsWindow> aiRingWindows(AiLimitsAccount a) {
  final pct = a.windows.where((w) => w.isMainPool && w.hasPercent).toList();
  int rank(AiLimitsWindow w) => switch (w.kind) {
    'five_hour' => 0,
    'weekly' => 1,
    'daily' => 2,
    'monthly' => 3,
    _ => 4,
  };
  pct.sort((x, y) => rank(x).compareTo(rank(y)));
  final seen = <String>{};
  return [
    for (final w in pct)
      if (seen.add(w.kind)) w,
  ].take(2).toList();
}

/// Section title with an optional trailing control.
class AiSectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  const AiSectionTitle(
    this.title, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(
      AppleSpacing.screen + AppleSpacing.xxs,
      AppleSpacing.xs,
      AppleSpacing.screen,
      AppleSpacing.sm,
    ),
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: type.title3.copyWith(color: c.label, fontWeight: FontWeight.w700),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Three glanceable numbers above the cards: accounts, highest use and the next reset.
class AiLimitsOverview extends StatelessWidget {
  final List<AiLimitsAccount> accounts;

  const AiLimitsOverview({super.key, required this.accounts});

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final dark = c.isDark;
    final now = DateTime.now();

    AiLimitsAccount? hiAcct;
    AiLimitsWindow? hiWin;
    AiLimitsAccount? nextAcct;
    AiLimitsWindow? nextWin;
    for (final a in accounts.where(
      (a) => a.enabled && a.isConnectionHealthy && !a.isAuthRequired && !a.isRateLimited,
    )) {
      for (final w in a.windows) {
        if (!w.hasPercent || !w.isMainPool) continue;
        if (!(a.isStale || w.isEffectivelyStale(now: now)) &&
            (hiWin == null || w.effectiveUsedPercent! > hiWin.effectiveUsedPercent!)) {
          hiAcct = a;
          hiWin = w;
        }
        final r = w.resetsAt;
        if (!a.isStale &&
            !w.isEffectivelyStale(now: now) &&
            r != null &&
            r.toUtc().isAfter(now.toUtc()) &&
            (nextWin == null || r.isBefore(nextWin.resetsAt!))) {
          nextAcct = a;
          nextWin = w;
        }
      }
    }

    final live = accounts
        .where(
          (a) =>
              a.enabled &&
              a.isConnectionHealthy &&
              !a.isAuthRequired &&
              !a.isRateLimited &&
              !a.isStale &&
              a.windows.any((w) => w.hasPercent && !w.isEffectivelyStale(now: now)),
        )
        .length;
    final attention = accounts
        .where(
          (a) =>
              a.isAuthRequired || a.isRateLimited || a.isOffline || a.isStale || a.isUsageBlocked,
        )
        .length;

    String who(AiLimitsAccount a, AiLimitsWindow w) {
      return '${a.displayTitle} · ${aiWindowShortLabel(w)}';
    }

    final hiColor = hiWin == null
        ? c.secondaryLabel
        : aiUsageColor(
            c,
            hiWin.effectiveUsedPercent!,
            AiProviderStyle.resolve(
              hiAcct!.provider,
              fallbackLabel: hiAcct.providerLabel,
            ).legibleOn(dark: dark),
          );

    final tiles = [
      _StatTile(
        icon: CupertinoIcons.person_2_fill,
        tint: c.accent,
        label: tr('Contas'),
        value: '${accounts.length}',
        detail: attention > 0
            ? tr('{n} precisam de atenção', {'n': '$attention'})
            : tr('{n} ao vivo', {'n': '$live'}),
        detailColor: attention > 0 ? c.orange : null,
      ),
      _StatTile(
        icon: CupertinoIcons.speedometer,
        tint: hiColor,
        label: tr('Maior uso'),
        value: hiWin == null ? '—' : '${hiWin.effectiveUsedPercent!.round()}%',
        valueColor: hiWin == null ? null : hiColor,
        detail: hiWin == null ? tr('Sem leituras') : who(hiAcct!, hiWin),
      ),
      _StatTile(
        icon: CupertinoIcons.timer,
        tint: c.teal,
        label: tr('Próximo reinício'),
        value: nextWin == null
            ? '—'
            : (formatAiResetTime(nextWin.resetsAt, now: now, compact: true) ?? '—'),
        detail: nextWin == null ? tr('Sem horário') : who(nextAcct!, nextWin),
      ),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpacing.screen,
        0,
        AppleSpacing.screen,
        AppleSpacing.lg,
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final stacked = box.maxWidth < 320 || MediaQuery.textScalerOf(context).scale(14) > 19;
          if (stacked)
            return Column(
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(height: 8),
                  SizedBox(width: double.infinity, child: tiles[i]),
                ],
              ],
            );
          return IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < tiles.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: tiles[i]),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final Color tint;
  final String label;
  final String value;
  final Color? valueColor;
  final String detail;
  final Color? detailColor;

  const _StatTile({
    required this.icon,
    required this.tint,
    required this.label,
    required this.value,
    required this.detail,
    this.valueColor,
    this.detailColor,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Semantics(
      container: true,
      label: '$label: $value. $detail',
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          decoration: BoxDecoration(
            color: c.secondaryGroupedBackground,
            borderRadius: BorderRadius.circular(AppleRadii.xl),
            border: Border.all(color: c.separator),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(icon, size: 14, color: tint),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      label,
                      style: type.caption1.copyWith(
                        color: c.secondaryLabel,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  value,
                  maxLines: 1,
                  style: type.title2.copyWith(
                    color: valueColor ?? c.label,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Text(
                detail,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: type.caption2.copyWith(color: detailColor ?? c.secondaryLabel),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One account: header, rings for the main 5h/weekly windows and rows for the rest.
class AiAccountUsageCard extends StatelessWidget {
  final AiLimitsAccount account;
  final bool showRemaining;
  final double width;
  final VoidCallback onOpen;

  const AiAccountUsageCard({
    super.key,
    required this.account,
    required this.showRemaining,
    required this.width,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final dark = c.isDark;
    final style = AiProviderStyle.resolve(account.provider, fallbackLabel: account.providerLabel);
    final accent = style.legibleOn(dark: dark);
    final readingStale = account.isStale || !account.isConnectionHealthy || account.isAuthRequired || account.isRateLimited;
    final rings = aiRingWindows(account);
    final rest = account.windows.where((w) => !rings.contains(w)).toList();
    final status = _status(c);
    final age = formatObservedAge(account.observedAt);
    final subtitle = [
      if (age != null) tr('Atualizado {quando}', {'quando': age}),
    ].join(' · ');

    const pad = AppleSpacing.md;
    final inner = width - pad * 2 - 2;
    final perRing = rings.isEmpty ? inner : inner / rings.length;
    final ringSize = (perRing - 16).clamp(76.0, 118.0);

    return Semantics(
      button: true,
      label: account.displayTitle,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(20),
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: c.separator),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: const Alignment(0.6, 0.4),
                colors: [
                  Color.alphaBlend(
                    accent.withValues(alpha: dark ? 0.16 : 0.09),
                    c.secondaryGroupedBackground,
                  ),
                  c.secondaryGroupedBackground,
                ],
              ),
            ),
            padding: const EdgeInsets.fromLTRB(pad, 14, 6, pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Row(
                  children: [
                    AiProviderBadge(
                      style: style,
                      size: 40,
                      iconSize: 21,
                      dark: dark,
                      borderRadius: 12,
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
                          Text(account.displayTitle, style: type.headline.copyWith(color: c.label)),
                          if (account.plan != null && account.plan!.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            _Pill(text: account.plan!, color: accent),
                          ],
                          const SizedBox(height: 2),
                          Wrap(
                            spacing: 6,
                            runSpacing: 2,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (status != null)
                                Text(
                                  status.$1,
                                  style: type.caption1.copyWith(
                                    color: status.$2,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              if (subtitle.isNotEmpty)
                                Text(
                                  subtitle,
                                  style: type.caption1.copyWith(color: c.secondaryLabel),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: tr('Opções da conta'),
                      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                      icon: Icon(Icons.more_horiz_rounded, size: 22, color: c.secondaryLabel),
                      onPressed: onOpen,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(right: pad - 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (account.isUsageBlocked) ...[
                        const SizedBox(height: AppleSpacing.sm),
                        _Callout(
                          icon: CupertinoIcons.hand_raised_fill,
                          color: c.red,
                          text: tr(
                            'Uso comum bloqueado pelo provedor nesta conta até a liberação da janela.',
                          ),
                        ),
                      ],
                      if (account.statusMessage != null && account.statusMessage!.isNotEmpty) ...[
                        const SizedBox(height: AppleSpacing.sm),
                        _Callout(
                          icon: CupertinoIcons.exclamationmark_triangle_fill,
                          color: account.isAuthRequired ? c.red : c.orange,
                          text: account.statusMessage!,
                        ),
                      ],
                      if (rings.isNotEmpty) ...[
                        const SizedBox(height: AppleSpacing.md),
                        if (MediaQuery.textScalerOf(context).scale(14) > 19)
                          Column(
                            children: [
                              for (final w in rings)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: _WindowLine(
                                    window: w,
                                    accent: accent,
                                    showRemaining: showRemaining,
                                    accountStale: readingStale,
                                  ),
                                ),
                            ],
                          )
                        else
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final w in rings)
                                Expanded(
                                  child: _RingGauge(
                                    window: w,
                                    size: ringSize,
                                    accent: accent,
                                    showRemaining: showRemaining,
                                    accountStale: readingStale,
                                  ),
                                ),
                            ],
                          ),
                      ],
                      if (rest.isNotEmpty) ...[
                        SizedBox(height: rings.isEmpty ? AppleSpacing.md : AppleSpacing.sm),
                        for (var i = 0; i < rest.length; i++) ...[
                          if (i > 0) const SizedBox(height: 6),
                          _WindowLine(
                            window: rest[i],
                            accent: accent,
                            showRemaining: showRemaining,
                            accountStale: readingStale,
                          ),
                        ],
                      ],
                      if (account.windows.isEmpty) ...[
                        const SizedBox(height: AppleSpacing.md),
                        _Callout(
                          icon: CupertinoIcons.info_circle_fill,
                          color: c.secondaryLabel,
                          text: switch (account.quotaStatus) {
                            'manual_only' => tr(
                              'Este serviço não oferece API oficial de limite restante. Abra o painel oficial abaixo.',
                            ),
                            'awaiting_data' => tr('Aguardando dados'),
                            _ => tr('Ainda não há janelas de uso disponíveis para esta conta.'),
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  (String, Color)? _status(AppleColors c) {
    final a = account;
    if (!a.enabled) return (tr('Desativado'), c.secondaryLabel);
    if (a.isAuthRequired) return (tr('Autenticação necessária'), c.red);
    if (a.isUsageBlocked) return (tr('Bloqueado'), c.red);
    if (a.isOffline) return (tr('Offline'), c.red);
    if (a.isRateLimited) return (tr('Em espera (429)'), c.orange);
    if (a.isStale || a.windows.any((w) => w.isEffectivelyStale())) return (tr('Antigo'), c.orange);
    if (a.freshness == 'local_only' || a.quotaStatus == 'local_only') {
      return (tr('Estimativa local'), c.teal);
    }
    if (a.isConnectionHealthy && a.hasLivePercentReading) return (tr('Ao vivo'), c.green);
    if (a.quotaStatus == 'awaiting_data') return (tr('Aguardando dados'), c.secondaryLabel);
    return (tr('Uso indisponível'), c.secondaryLabel);
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;

  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: c.isDark ? 0.20 : 0.13),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: type.caption2.copyWith(color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _Callout extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _Callout({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: c.isDark ? 0.14 : 0.09),
        borderRadius: BorderRadius.circular(AppleRadii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 14, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: type.footnote.copyWith(color: c.label)),
          ),
        ],
      ),
    );
  }
}

/// Activity-style ring with the percentage in the middle and the reset time below.
class _RingGauge extends StatelessWidget {
  final AiLimitsWindow window;
  final double size;
  final Color accent;
  final bool showRemaining;
  final bool accountStale;

  const _RingGauge({
    required this.window,
    required this.size,
    required this.accent,
    required this.showRemaining,
    required this.accountStale,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final used = window.effectiveUsedPercent!;
    final shown = showRemaining ? window.effectiveRemainingPercent! : used;
    final stale = accountStale || window.isEffectivelyStale();
    final color = aiUsageColor(c, used, accent, stale: stale);
    final reset = aiResetPhrase(window);
    final label = aiWindowShortLabel(window);
    final stroke = (size * 0.095).clamp(7.0, 11.0);
    final under = window.isPastReset()
        ? tr('Aguardando nova leitura')
        : [if (stale) tr('Antigo'), reset ?? tr('Reinício não informado')].join(' · ');

    return Semantics(
      label: '$label: ${shown.round()}% ${showRemaining ? tr('livre') : tr('usado')}. $under',
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: (shown / 100).clamp(0.0, 1.0)),
              duration: AppleMotion.of(context, const Duration(milliseconds: 700)),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => CustomPaint(
                size: Size.square(size),
                painter: _RingPainter(
                  fraction: v,
                  color: color,
                  track: color.withValues(alpha: c.isDark ? 0.16 : 0.13),
                  stroke: stroke,
                ),
                child: SizedBox.square(
                  dimension: size,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text.rich(
                          TextSpan(
                            children: [
                              TextSpan(text: '${shown.round()}'),
                              TextSpan(
                                text: '%',
                                style: TextStyle(
                                  fontSize: size * 0.13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                          style: type.title1.copyWith(
                            fontSize: size * 0.24,
                            height: 1.0,
                            color: c.label,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          showRemaining ? tr('livre') : tr('usado'),
                          style: type.caption2.copyWith(color: c.secondaryLabel),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.subheadline.copyWith(color: c.label, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 1),
            Text(
              under,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: type.caption1.copyWith(
                color: stale ? c.orange : c.secondaryLabel,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double fraction;
  final Color color;
  final Color track;
  final double stroke;

  const _RingPainter({
    required this.fraction,
    required this.color,
    required this.track,
    required this.stroke,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(arcRect, 0, math.pi * 2, false, base..color = track);
    if (fraction <= 0) return;
    final sweep = math.max(fraction, 0.004) * math.pi * 2;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: math.pi * 2,
        colors: [color.withValues(alpha: 0.75), color],
        stops: [0, fraction.clamp(0.05, 1.0)],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(rect);
    canvas.drawArc(arcRect, -math.pi / 2, sweep, false, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.color != color || old.track != track || old.stroke != stroke;
}

/// A window that isn't a main-pool percentage: an extra pool, a native count or a status.
class _WindowLine extends StatelessWidget {
  final AiLimitsWindow window;
  final Color accent;
  final bool showRemaining;
  final bool accountStale;

  const _WindowLine({
    required this.window,
    required this.accent,
    required this.showRemaining,
    required this.accountStale,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final w = window;
    final stale = accountStale || w.isEffectivelyStale();
    final label = aiWindowLabelWithPool(w, aiWindowShortLabel(w));

    String value;
    Color valueColor;
    double? bar;
    Color barColor = accent;
    if (w.hasPercent) {
      final used = w.effectiveUsedPercent!;
      final shown = showRemaining ? w.effectiveRemainingPercent! : used;
      value = showRemaining
          ? tr('{p}% livre', {'p': '${shown.round()}'})
          : tr('{p}% usado', {'p': '${shown.round()}'});
      barColor = aiUsageColor(c, used, accent, stale: stale);
      valueColor = used >= 70 || stale ? barColor : c.label;
      bar = (shown / 100).clamp(0.0, 1.0);
    } else if (w.hasNativeCount) {
      value = aiFormatNativeMetric(w);
      valueColor = c.label;
      if (w.limit != null && w.limit! > 0) bar = (w.used! / w.limit!).clamp(0.0, 1.0);
    } else if (w.isNotApplicable) {
      value = w.kind == 'five_hour' ? tr('Sem limite 5h') : tr('Não aplicável');
      valueColor = c.secondaryLabel;
    } else if (w.isRateLimited) {
      value = tr('Limite de taxa (429)');
      valueColor = c.orange;
    } else if (w.isAuthRequired) {
      value = tr('Autenticação necessária');
      valueColor = c.red;
    } else if (w.isNotConnected) {
      value = tr('Não conectado');
      valueColor = c.secondaryLabel;
    } else {
      value = tr('Uso indisponível');
      valueColor = c.orange;
    }
    final reset = aiResetPhrase(w);

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: c.tertiaryFill,
        borderRadius: BorderRadius.circular(AppleRadii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                label,
                style: type.subheadline.copyWith(color: c.label, fontWeight: FontWeight.w600),
              ),
              Text(
                value,
                style: type.subheadline.copyWith(
                  color: valueColor,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (stale)
            Text(
              w.isPastReset() ? tr('Aguardando nova leitura') : tr('Antigo'),
              style: type.caption1.copyWith(color: c.orange),
            ),
          if (bar != null) ...[
            const SizedBox(height: 7),
            CapsuleBar(value: bar, color: barColor, height: 6, track: c.fill),
          ],
          if (reset != null || (w.note != null && w.note!.isNotEmpty)) ...[
            const SizedBox(height: 5),
            Text(
              [
                if (reset != null) reset,
                if (w.note != null && w.note!.isNotEmpty) w.note!,
              ].join(' · '),
              style: type.caption1.copyWith(color: c.secondaryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

/// Lays cards out in equal-height rows: one column on phones, two from ~600 px.
class AiCardGrid extends StatelessWidget {
  final int count;
  final Widget Function(BuildContext context, int index, double width) itemBuilder;

  const AiCardGrid({super.key, required this.count, required this.itemBuilder});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppleSpacing.screen),
      child: LayoutBuilder(
        builder: (context, box) {
          const gap = 12.0;
          final cols =
              count > 1 && box.maxWidth >= 680 && MediaQuery.textScalerOf(context).scale(14) <= 19
              ? 2
              : 1;
          final w = (box.maxWidth - gap * (cols - 1)) / cols;
          final rows = <Widget>[];
          for (var i = 0; i < count; i += cols) {
            if (rows.isNotEmpty) rows.add(const SizedBox(height: gap));
            final cells = <Widget>[];
            for (var j = 0; j < cols; j++) {
              if (j > 0) cells.add(const SizedBox(width: gap));
              cells.add(
                SizedBox(width: w, child: i + j < count ? itemBuilder(context, i + j, w) : null),
              );
            }
            rows.add(
              IntrinsicHeight(
                child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells),
              ),
            );
          }
          return Column(mainAxisSize: MainAxisSize.min, children: rows);
        },
      ),
    );
  }
}
