import 'dart:math' as math;

import 'package:deckos/core/core.dart';
import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';

import '../buttons/colors.dart';
import 'info_deck_button.dart' show usageColor;
import 'usage_bars.dart' show CapsuleBar;

/// Tipo dinâmico isolado para os cartões ilustrativos de limites de assinaturas de IA.
/// Nunca aciona o backend (AiUsageService / InfoService) nem substitui medições reais.
const aiLimitsDemoDynamicType = 'ai_limits_demo';

/// Identificador estável da página extra de demonstração no deck.
const aiLimitsDemoProfileId = 'ai_limits_demo';

/// Título padrão da página extra de demonstração.
const aiLimitsDemoProfileName = 'AI Limits Demo';

/// Convenção de exibição da página demo: falso = "% usado", verdadeiro = "% livre".
final aiLimitsDemoShowRemaining = signal<bool>(false);

enum AiLimitWindowStatus { percent, notApplicable, unavailable }

enum AiLimitFreshness { fresh, stale, localOnly, spendOnly, manualOnly }

@immutable
class AiLimitWindow {
  final AiLimitWindowStatus status;

  /// Porcentagem já usada (0–100). Sempre nula quando [status] não for [AiLimitWindowStatus.percent].
  final double? usedPercent;

  /// Texto curto de reinício ou observação da janela (ex.: "2h 41m", "Thu 18:00").
  final String? resetLabel;

  const AiLimitWindow.percent(double this.usedPercent, {this.resetLabel})
      : status = AiLimitWindowStatus.percent;

  const AiLimitWindow.notApplicable({this.resetLabel})
      : status = AiLimitWindowStatus.notApplicable,
        usedPercent = null;

  const AiLimitWindow.unavailable({this.resetLabel})
      : status = AiLimitWindowStatus.unavailable,
        usedPercent = null;
}

@immutable
class AiLimitDemoSample {
  final String id;
  final String provider;
  final String alias;
  final String plan;
  final Color accentColor;
  final IconData icon;
  final String iconName;
  final AiLimitWindow fiveHour;
  final AiLimitWindow weekly;
  final AiLimitFreshness freshness;

  /// Linha compacta para provedores sem janela 5h/semanal ou sem API oficial.
  final String? nativeSummary;

  /// Rodapé curto com reinícios quando há porcentagens.
  final String? compactFooter;

  /// Origem ilustrativa (exibida só na folha de detalhes ao tocar no cartão).
  final String sourceLabel;

  /// Nota curta e honesta para a folha de detalhes.
  final String detailNote;

  const AiLimitDemoSample({
    required this.id,
    required this.provider,
    required this.alias,
    required this.plan,
    required this.accentColor,
    required this.icon,
    required this.iconName,
    required this.fiveHour,
    required this.weekly,
    required this.freshness,
    this.nativeSummary,
    this.compactFooter,
    required this.sourceLabel,
    required this.detailNote,
  });

  String get displayTitle => '$provider · $alias';
}

/// Amostras ilustrativas isoladas (8 contas = grade exata 4×2 deitada / 2×4 em pé).
/// Apelidos genéricos sem e-mails, tokens ou credenciais reais.
const List<AiLimitDemoSample> aiLimitsDemoSamples = [
  AiLimitDemoSample(
    id: 'claude_personal',
    provider: 'Claude',
    alias: 'Personal',
    plan: 'Pro',
    accentColor: Color(0xFFD97757),
    icon: CupertinoIcons.sparkles,
    iconName: 'auto_awesome',
    fiveHour: AiLimitWindow.percent(42, resetLabel: '2h 41m'),
    weekly: AiLimitWindow.percent(61, resetLabel: 'Thu 18:00'),
    freshness: AiLimitFreshness.fresh,
    compactFooter: '5h 2h 41m · Wk Thu 18:00',
    sourceLabel: 'Demo fixture · Claude Code statusLine',
    detailNote:
        'Illustrative sample. Consumer Claude plans expose rolling 5h and 7d percentages through local CLI hooks without extra API probes.',
  ),
  AiLimitDemoSample(
    id: 'claude_work',
    provider: 'Claude',
    alias: 'Work',
    plan: 'Max',
    accentColor: Color(0xFFE08B6C),
    icon: CupertinoIcons.briefcase_fill,
    iconName: 'work',
    fiveHour: AiLimitWindow.percent(78, resetLabel: 'Past reset'),
    weekly: AiLimitWindow.percent(52, resetLabel: 'Sat 09:00'),
    freshness: AiLimitFreshness.stale,
    compactFooter: 'Stale · Wk Sat 09:00',
    sourceLabel: 'Demo fixture · Stale snapshot state',
    detailNote:
        'Illustrative sample showing a stale 5h reading past its reset window. DeckOS keeps the last observed figure marked stale instead of auto-zeroing to 0%.',
  ),
  AiLimitDemoSample(
    id: 'codex_personal',
    provider: 'Codex',
    alias: 'Personal',
    plan: 'Pro',
    accentColor: Color(0xFF10A37F),
    icon: CupertinoIcons.chevron_left_slash_chevron_right,
    iconName: 'code',
    fiveHour: AiLimitWindow.notApplicable(resetLabel: 'No 5h cap on Pro'),
    weekly: AiLimitWindow.percent(38, resetLabel: 'Fri 00:00'),
    freshness: AiLimitFreshness.fresh,
    compactFooter: 'Weekly resets Fri 00:00',
    sourceLabel: 'Demo fixture · codex app-server',
    detailNote:
        'Illustrative sample. Codex Pro plans have no 5-hour cap and retain only a weekly pool, so the 5h window is shown honestly as Not applicable.',
  ),
  AiLimitDemoSample(
    id: 'codex_secondary',
    provider: 'Codex',
    alias: 'Secondary',
    plan: 'Plus',
    accentColor: Color(0xFF14B8A6),
    icon: CupertinoIcons.chevron_right_square_fill,
    iconName: 'terminal',
    fiveHour: AiLimitWindow.percent(64, resetLabel: '1h 18m'),
    weekly: AiLimitWindow.percent(29, resetLabel: 'Sun 12:00'),
    freshness: AiLimitFreshness.fresh,
    compactFooter: '5h 1h 18m · Wk Sun 12:00',
    sourceLabel: 'Demo fixture · Separate CODEX_HOME',
    detailNote:
        'Illustrative sample for a secondary Plus account. Percentages are kept strictly per account and never summed across subscriptions.',
  ),
  AiLimitDemoSample(
    id: 'gemini_cli',
    provider: 'Gemini CLI',
    alias: 'Personal',
    plan: 'AI Pro',
    accentColor: Color(0xFF4285F4),
    icon: CupertinoIcons.bolt_fill,
    iconName: 'bolt',
    fiveHour: AiLimitWindow.notApplicable(resetLabel: 'Daily RPD model'),
    weekly: AiLimitWindow.notApplicable(resetLabel: 'Daily RPD model'),
    freshness: AiLimitFreshness.localOnly,
    nativeSummary: 'Today: 340 req (local)',
    sourceLabel: 'Demo fixture · Local OpenTelemetry',
    detailNote:
        'Illustrative sample. Gemini CLI uses daily requests per user (RPD) rather than 5h/weekly caps, and local telemetry reflects this device only.',
  ),
  AiLimitDemoSample(
    id: 'google_antigravity',
    provider: 'Antigravity',
    alias: 'Personal',
    plan: 'AI Pro',
    accentColor: Color(0xFF8B5CF6),
    icon: CupertinoIcons.rocket_fill,
    iconName: 'launch',
    fiveHour: AiLimitWindow.unavailable(resetLabel: 'No official API'),
    weekly: AiLimitWindow.unavailable(resetLabel: 'No official API'),
    freshness: AiLimitFreshness.manualOnly,
    nativeSummary: 'Check /quota in app',
    sourceLabel: 'Demo fixture · Manual dashboard check',
    detailNote:
        'Illustrative sample. Google Antigravity has 5h and weekly pools in-app, but offers no documented public quota API, so both windows stay Unavailable.',
  ),
  AiLimitDemoSample(
    id: 'github_copilot',
    provider: 'Copilot',
    alias: 'Personal',
    plan: 'Indiv.',
    accentColor: Color(0xFF6366F1),
    icon: CupertinoIcons.circle_grid_hex_fill,
    iconName: 'hub',
    fiveHour: AiLimitWindow.notApplicable(resetLabel: 'Monthly AI Credits'),
    weekly: AiLimitWindow.notApplicable(resetLabel: 'Monthly AI Credits'),
    freshness: AiLimitFreshness.spendOnly,
    nativeSummary: 'Month: 412 credits',
    sourceLabel: 'Demo fixture · Billing usage REST',
    detailNote:
        'Illustrative sample. GitHub Copilot uses monthly AI Credits and official personal billing endpoints report consumed units rather than 5h/weekly percentages.',
  ),
  AiLimitDemoSample(
    id: 'cursor_personal',
    provider: 'Cursor',
    alias: 'Personal',
    plan: 'The X Sub',
    accentColor: Color(0xFF38BDF8),
    icon: CupertinoIcons.cube_fill,
    iconName: 'extension',
    fiveHour: AiLimitWindow.notApplicable(resetLabel: 'No 5h window'),
    weekly: AiLimitWindow.unavailable(resetLabel: 'Teams/Enterprise API only'),
    freshness: AiLimitFreshness.manualOnly,
    nativeSummary: 'Dashboard only',
    sourceLabel: 'Demo fixture · Official dashboard link',
    detailNote:
        'Illustrative sample. Personal Cursor plans have a weekly pool plus prepaid credits with no personal quota API, so Weekly remains Unavailable.',
  ),
];

/// Resolve a amostra de demonstração associada a [button].
AiLimitDemoSample aiLimitDemoSampleFor(DeckButton button) {
  final sampleId = button.dynamicParameters?['sample'];
  if (sampleId != null && sampleId.isNotEmpty) {
    for (final s in aiLimitsDemoSamples) {
      if (s.id == sampleId) return s;
    }
  }
  return aiLimitsDemoSamples.first;
}

/// Constrói o perfil completo e reproduzível "AI Limits Demo" (4×2 = 8 cartões).
DeckProfile buildAiLimitsDemoProfile() => DeckProfile(
      id: aiLimitsDemoProfileId,
      name: aiLimitsDemoProfileName,
      rows: 2,
      columns: 4,
      buttons: [
        for (var i = 0; i < aiLimitsDemoSamples.length; i++)
          DeckButton(
            id: 'ai_demo_${aiLimitsDemoSamples[i].id}',
            row: i ~/ 4,
            column: i % 4,
            label: aiLimitsDemoSamples[i].displayTitle,
            iconName: aiLimitsDemoSamples[i].iconName,
            dynamicType: aiLimitsDemoDynamicType,
            dynamicParameters: {'sample': aiLimitsDemoSamples[i].id},
          ),
      ],
    );

/// Cartão de limites de assinatura de IA (dados ilustrativos) desenhado sobre o [DeckTile]
/// nativo para preservar squircle, vidro, borda, sombras, fonte e animação de toque.
class AiLimitsDemoTile extends StatelessWidget {
  final DeckButton button;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const AiLimitsDemoTile({
    super.key,
    required this.button,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final sample = aiLimitDemoSampleFor(button);
    return DeckTile(
      color: parseHexColor(button.backgroundColor),
      onTap: onTap,
      onLongPress: onLongPress,
      child: Watch((context) {
        final showRemaining = aiLimitsDemoShowRemaining.value;
        return _AiLimitsTileBody(
          sample: sample,
          showRemaining: showRemaining,
        );
      }),
    );
  }
}

class _AiLimitsTileBody extends StatelessWidget {
  final AiLimitDemoSample sample;
  final bool showRemaining;

  const _AiLimitsTileBody({
    required this.sample,
    required this.showRemaining,
  });

  @override
  Widget build(BuildContext context) {
    final fg = DeckTile.foregroundOf(context);
    final deck = DeckTheme.of(context);
    final dark = deck.background.computeLuminance() < 0.3;
    final stale = sample.freshness == AiLimitFreshness.stale;
    final demoBg = DeckTileColors.orange.withValues(alpha: dark ? 0.22 : 0.16);
    final demoFg = dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309);
    final accentTint = _legibleAccent(sample.accentColor, dark);

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth.isFinite ? constraints.maxWidth : 140.0;
        final maxH = constraints.maxHeight.isFinite ? constraints.maxHeight : 140.0;
        final rawTextScale =
            (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 2.0);
        final clampedScale = math.min(rawTextScale, 1.22);
        final contentWidth = math.max(maxW, 134.0 * clampedScale);
        final footer = sample.nativeSummary ?? sample.compactFooter;

        final content = MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.22,
          child: SizedBox(
            width: contentWidth,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: accentTint.withValues(alpha: dark ? 0.22 : 0.14),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Icon(sample.icon, size: 11, color: accentTint),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      sample.provider,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        height: 1.1,
                        color: fg,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4.5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: demoBg,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      tr('DEMO'),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 7.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.35,
                        height: 1.0,
                        color: demoFg,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${sample.alias} · ${sample.plan}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w500,
                        height: 1.1,
                        color: fg.withValues(alpha: 0.62),
                      ),
                    ),
                  ),
                  if (stale) ...[
                    const SizedBox(width: 4),
                    Text(
                      tr('Antigo'),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w700,
                        height: 1.1,
                        color: demoFg,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 7),
              _WindowMeterRow(
                label: tr('5h'),
                window: sample.fiveHour,
                showRemaining: showRemaining,
                stale: stale,
                dark: dark,
                fg: fg,
              ),
              const SizedBox(height: 6),
              _WindowMeterRow(
                label: tr('Semanal'),
                window: sample.weekly,
                showRemaining: showRemaining,
                stale: false,
                dark: dark,
                fg: fg,
              ),
              if (footer != null && footer.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  footer,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 8.5,
                    fontWeight: FontWeight.w600,
                    height: 1.15,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    color: _footerColor(sample.freshness, fg, dark),
                  ),
                ),
              ],
            ],
          ),
        ),
        );

        // Em 1.0x num cartão normal a caixa cabe sem reduzir; com texto 1.8x ou cartão
        // compacto o FittedBox reduz proporcionalmente sem cortar nem gerar overflow.
        return SizedBox(
          width: maxW,
          height: maxH,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: content,
          ),
        );
      },
    );
  }

  static Color _footerColor(AiLimitFreshness freshness, Color fg, bool dark) =>
      switch (freshness) {
        AiLimitFreshness.stale => dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309),
        AiLimitFreshness.localOnly ||
        AiLimitFreshness.spendOnly =>
          dark ? const Color(0xFF60A5FA) : const Color(0xFF0369A1),
        _ => fg.withValues(alpha: 0.56),
      };

  static Color _legibleAccent(Color c, bool dark) {
    final hsl = HSLColor.fromColor(c);
    if (dark && hsl.lightness < 0.58) return hsl.withLightness(0.62).toColor();
    if (!dark && hsl.lightness > 0.45) return hsl.withLightness(0.42).toColor();
    return c;
  }
}

class _WindowMeterRow extends StatelessWidget {
  final String label;
  final AiLimitWindow window;
  final bool showRemaining;
  final bool stale;
  final bool dark;
  final Color fg;

  const _WindowMeterRow({
    required this.label,
    required this.window,
    required this.showRemaining,
    required this.stale,
    required this.dark,
    required this.fg,
  });

  @override
  Widget build(BuildContext context) {
    final isPct = window.status == AiLimitWindowStatus.percent && window.usedPercent != null;
    final used = (window.usedPercent ?? 0).clamp(0.0, 100.0);
    final shownPct = showRemaining ? (100.0 - used).clamp(0.0, 100.0) : used;

    final String valueText;
    final Color valueColor;
    switch (window.status) {
      case AiLimitWindowStatus.percent:
        final rounded = shownPct.round();
        valueText = showRemaining
            ? tr('{p}% livre', {'p': '$rounded'})
            : tr('{p}% usado', {'p': '$rounded'});
        if (stale) {
          valueColor = dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309);
        } else if (used > 85) {
          valueColor = DeckTileColors.red;
        } else {
          valueColor = fg;
        }
      case AiLimitWindowStatus.notApplicable:
        valueText = tr('Não aplicável');
        valueColor = fg.withValues(alpha: 0.46);
      case AiLimitWindowStatus.unavailable:
        valueText = tr('Indisponível');
        valueColor = dark ? const Color(0xFFD6A86E) : const Color(0xFF9A6700);
    }

    final barColor = stale
        ? DeckTileColors.orange.withValues(alpha: 0.65)
        : usageColor(used);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              label,
              maxLines: 1,
              style: TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                height: 1.1,
                color: fg.withValues(alpha: 0.70),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    valueText,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: isPct ? 10.0 : 9.0,
                      fontWeight: isPct ? FontWeight.w700 : FontWeight.w600,
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
        const SizedBox(height: 3),
        if (isPct)
          CapsuleBar(
            value: shownPct / 100.0,
            color: barColor,
            height: 4.5,
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

/// Folha de detalhes ao tocar num cartão demo: deixa explícito que os números são
/// ilustrativos, mostra reinícios/origem e permite alternar "% usado" / "% livre".
Future<void> showAiLimitsDemoSheet(BuildContext context, DeckButton button) {
  final sample = aiLimitDemoSampleFor(button);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _AiLimitsDemoSheet(sample: sample),
  );
}

class _AiLimitsDemoSheet extends StatelessWidget {
  final AiLimitDemoSample sample;

  const _AiLimitsDemoSheet({required this.sample});

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final dark = c.isDark;
    final demoBg = c.orange.withValues(alpha: dark ? 0.18 : 0.13);
    final demoFg = dark ? const Color(0xFFFFB84D) : const Color(0xFFB45309);

    return SafeArea(
      top: false,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
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
                final showRemaining = aiLimitsDemoShowRemaining.value;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: sample.accentColor.withValues(alpha: dark ? 0.22 : 0.14),
                            borderRadius: BorderRadius.circular(AppleRadii.sm),
                          ),
                          child: Icon(sample.icon, size: 18, color: sample.accentColor),
                        ),
                        const SizedBox(width: AppleSpacing.sm),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                sample.displayTitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: type.headline.copyWith(color: c.label),
                              ),
                              Text(
                                sample.plan,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: type.caption1.copyWith(color: c.secondaryLabel),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: demoBg,
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            tr('Dados de demonstração'),
                            style: type.caption2.copyWith(
                              color: demoFg,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppleSpacing.sm),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppleSpacing.sm,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: demoBg,
                        borderRadius: BorderRadius.circular(AppleRadii.md),
                      ),
                      child: Text(
                        tr('Valores ilustrativos apenas para revisão visual. Nenhuma conta real, token ou API está conectada.'),
                        style: type.caption1.copyWith(color: demoFg),
                      ),
                    ),
                    const SizedBox(height: AppleSpacing.sm),
                    SegmentedButton<bool>(
                      segments: [
                        ButtonSegment(value: false, label: Text(tr('% usado'))),
                        ButtonSegment(value: true, label: Text(tr('% livre'))),
                      ],
                      selected: {showRemaining},
                      onSelectionChanged: (v) => aiLimitsDemoShowRemaining.value = v.first,
                    ),
                    const SizedBox(height: AppleSpacing.sm),
                    _SheetWindowCard(
                      title: tr('Limite de 5 horas'),
                      window: sample.fiveHour,
                      showRemaining: showRemaining,
                      stale: sample.freshness == AiLimitFreshness.stale,
                    ),
                    const SizedBox(height: AppleSpacing.xs),
                    _SheetWindowCard(
                      title: tr('Limite semanal'),
                      window: sample.weekly,
                      showRemaining: showRemaining,
                      stale: false,
                    ),
                    if (sample.nativeSummary != null) ...[
                      const SizedBox(height: AppleSpacing.xs),
                      Container(
                        padding: const EdgeInsets.all(AppleSpacing.sm),
                        decoration: BoxDecoration(
                          color: c.tertiaryGroupedBackground,
                          borderRadius: BorderRadius.circular(AppleRadii.md),
                          border: Border.all(color: c.separator, width: 0.75),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                tr('Medida nativa (amostra)'),
                                style: type.caption1.copyWith(color: c.secondaryLabel),
                              ),
                            ),
                            Text(
                              sample.nativeSummary!,
                              style: type.footnote.copyWith(
                                color: c.label,
                                fontWeight: FontWeight.w600,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: AppleSpacing.sm),
                    Text(
                      sample.sourceLabel,
                      style: type.caption1.copyWith(
                        color: c.label,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      sample.detailNote,
                      style: type.caption1.copyWith(color: c.secondaryLabel),
                    ),
                    const SizedBox(height: AppleSpacing.md),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: Text(tr('Fechar')),
                      ),
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
}

class _SheetWindowCard extends StatelessWidget {
  final String title;
  final AiLimitWindow window;
  final bool showRemaining;
  final bool stale;

  const _SheetWindowCard({
    required this.title,
    required this.window,
    required this.showRemaining,
    required this.stale,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final isPct = window.status == AiLimitWindowStatus.percent && window.usedPercent != null;
    final used = (window.usedPercent ?? 0).clamp(0.0, 100.0);
    final left = (100.0 - used).clamp(0.0, 100.0);
    final shown = showRemaining ? left : used;

    final String statusText = switch (window.status) {
      AiLimitWindowStatus.percent => showRemaining
          ? tr('{p}% livre', {'p': '${left.round()}'})
          : tr('{p}% usado', {'p': '${used.round()}'}),
      AiLimitWindowStatus.notApplicable => tr('Não aplicável'),
      AiLimitWindowStatus.unavailable => tr('Indisponível'),
    };

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
                  title,
                  style: type.footnote.copyWith(
                    color: c.secondaryLabel,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                statusText,
                style: type.footnote.copyWith(
                  color: c.label,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          if (isPct) ...[
            const SizedBox(height: 6),
            CapsuleBar(
              value: shown / 100.0,
              color: stale ? DeckTileColors.orange.withValues(alpha: 0.65) : usageColor(used),
              height: 6,
              track: c.fill,
            ),
          ],
          if (window.resetLabel != null) ...[
            const SizedBox(height: 4),
            Text(
              isPct
                  ? '${tr('{p}% usado', {'p': '${used.round()}'})} · ${tr('{p}% livre', {'p': '${left.round()}'})} · ${window.resetLabel!}'
                  : window.resetLabel!,
              style: type.caption2.copyWith(color: c.secondaryLabel),
            ),
          ],
        ],
      ),
    );
  }
}
