/// Original DeckOS-styled Subscription & Google Play Billing screen.
///
/// Follows DeckOS's Settings visual language (`SettingsScaffold`,
/// `InsetGroupedSection`, `ListRow`, `PrimaryButton`, `SecondaryButton`,
/// `AppleColors`, `AppleTextStyles`, `AppleSpacing`), supports large
/// accessibility text scales, landscape/narrow layouts, and Google Play
/// Payments disclosure & cancellation requirements without preselected dark
/// patterns or fabricated prices.
library;

import 'package:deckos/core/core.dart';
import 'package:deckos/src/config/settings_kit.dart';
import 'package:flutter/material.dart';

import 'billing_models.dart';
import 'billing_strings.dart';
import 'subscription_controller.dart';

class SubscriptionPage extends StatefulWidget {
  const SubscriptionPage({
    super.key,
    this.controller,
    this.autoInitialize = true,
  });

  /// Injectable controller for app wiring or widget tests. When omitted, uses
  /// a safe [SubscriptionController.unconfigured] instance.
  final SubscriptionController? controller;
  final bool autoInitialize;

  @override
  State<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends State<SubscriptionPage>
    with WidgetsBindingObserver {
  late final SubscriptionController _controller;
  late final bool _ownsController;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.controller != null) {
      _controller = widget.controller!;
      _ownsController = false;
    } else {
      _controller = SubscriptionController.unconfigured();
      _ownsController = true;
    }
    _controller.addListener(_onControllerChanged);
    if (widget.autoInitialize) {
      _controller.initialize();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _controller.onAppResumed();
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = _controller.snapshot;
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);

    return SettingsScaffold(
      title: BillingStrings.t('pageTitle'),
      children: [
        _StatusHeroCard(snapshot: snap),
        if (snap.feedback.isVisible) _FeedbackBanner(feedback: snap.feedback),
        if (snap.usingOfflineCache && snap.activeGrant != null)
          _OfflineCacheBanner(grant: snap.activeGrant!),
        _PlansSection(
          snapshot: snap,
          onSelect: _controller.selectOffer,
          onSubscribe: _controller.purchaseSelectedPlan,
        ),
        _ManageSection(
          snapshot: snap,
          onRestore: _controller.restorePurchases,
          onRefresh: () => _controller.refreshEntitlement(silent: false),
          onManage: _controller.openManageSubscription,
        ),
        _TermsSection(colors: c, type: type),
      ],
    );
  }
}

class _StatusHeroCard extends StatelessWidget {
  const _StatusHeroCard({required this.snapshot});

  final SubscriptionSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final statusInfo = _resolveStatus(c, snapshot);

    return InsetGroupedSection(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppleSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  BrandChip(
                    Icons.workspace_premium_rounded,
                    color: statusInfo.badgeColor,
                    size: 44,
                  ),
                  const SizedBox(width: AppleSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          BillingStrings.t('heroTitle'),
                          style: type.headline.copyWith(color: c.label),
                        ),
                        const SizedBox(height: AppleSpacing.xxs),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppleSpacing.sm - 2,
                            vertical: 3,
                          ),
                          decoration: ShapeDecoration(
                            color: statusInfo.badgeColor.withValues(
                              alpha: c.isDark ? 0.18 : 0.12,
                            ),
                            shape: const StadiumBorder(),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              StatusDot(
                                color: statusInfo.badgeColor,
                                glow:
                                    snapshot.entitlementState ==
                                    EntitlementState.active,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  statusInfo.label,
                                  style: type.caption1.copyWith(
                                    color: statusInfo.badgeColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppleSpacing.sm),
              Text(
                statusInfo.detail,
                style: type.subheadline.copyWith(color: c.secondaryLabel),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static ({String label, String detail, Color badgeColor}) _resolveStatus(
    AppleColors c,
    SubscriptionSnapshot s,
  ) {
    final expiry = s.activeGrant?.expiresAt != null
        ? _formatIsoDate(s.activeGrant!.expiresAt!)
        : '';

    return switch (s.entitlementState) {
      EntitlementState.unconfigured => (
        label: BillingStrings.t('statusUnconfigured'),
        detail: BillingStrings.t('detailUnconfigured'),
        badgeColor: c.gray,
      ),
      EntitlementState.unsupportedPlatform => (
        label: BillingStrings.t('statusUnsupportedPlatform'),
        detail: BillingStrings.t('detailUnsupportedPlatform'),
        badgeColor: c.gray,
      ),
      EntitlementState.free => (
        label: BillingStrings.t('statusFree'),
        detail: BillingStrings.t('detailFree'),
        badgeColor: c.blue,
      ),
      EntitlementState.pending => (
        label: BillingStrings.t('statusPending'),
        detail: BillingStrings.t('detailPending'),
        badgeColor: c.orange,
      ),
      EntitlementState.active => (
        label: BillingStrings.t('statusActive'),
        detail: expiry.isNotEmpty
            ? BillingStrings.t('detailActiveRenews', {'date': expiry})
            : BillingStrings.t('detailActive'),
        badgeColor: c.green,
      ),
      EntitlementState.inGracePeriod => (
        label: BillingStrings.t('statusGracePeriod'),
        detail: BillingStrings.t('detailGracePeriod'),
        badgeColor: c.orange,
      ),
      EntitlementState.onHold => (
        label: BillingStrings.t('statusOnHold'),
        detail: BillingStrings.t('detailOnHold'),
        badgeColor: c.red,
      ),
      EntitlementState.paused => (
        label: BillingStrings.t('statusPaused'),
        detail: BillingStrings.t('detailPaused'),
        badgeColor: c.orange,
      ),
      EntitlementState.canceledActive => (
        label: BillingStrings.t('statusCanceledActive', {'date': expiry}),
        detail: BillingStrings.t('detailCanceledActive', {'date': expiry}),
        badgeColor: c.orange,
      ),
      EntitlementState.expired => (
        label: BillingStrings.t('statusExpired'),
        detail: BillingStrings.t('detailExpired'),
        badgeColor: c.gray,
      ),
      EntitlementState.revoked => (
        label: BillingStrings.t('statusRevoked'),
        detail: BillingStrings.t('detailRevoked'),
        badgeColor: c.red,
      ),
    };
  }
}

class _FeedbackBanner extends StatelessWidget {
  const _FeedbackBanner({required this.feedback});

  final BillingFeedback feedback;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final tone = feedback.isError
        ? c.red
        : (feedback.code == BillingFeedbackCode.purchaseVerified ||
                  feedback.code == BillingFeedbackCode.restoreSucceeded
              ? c.green
              : c.blue);
    final message = _feedbackText(feedback.code);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpacing.screen,
        0,
        AppleSpacing.screen,
        AppleSpacing.lg,
      ),
      child: Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.all(AppleSpacing.sm),
          decoration: BoxDecoration(
            color: tone.withValues(alpha: c.isDark ? 0.14 : 0.08),
            borderRadius: BorderRadius.circular(AppleRadii.md),
            border: Border.all(
              color: tone.withValues(alpha: c.isDark ? 0.35 : 0.25),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                feedback.isError
                    ? Icons.error_outline_rounded
                    : Icons.info_outline_rounded,
                size: 20,
                color: tone,
              ),
              const SizedBox(width: AppleSpacing.xs),
              Expanded(
                child: Text(
                  message,
                  style: type.footnote.copyWith(color: c.label),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _feedbackText(BillingFeedbackCode code) => switch (code) {
    BillingFeedbackCode.none => '',
    BillingFeedbackCode.notConfigured => BillingStrings.t('fbNotConfigured'),
    BillingFeedbackCode.unsupportedPlatform => BillingStrings.t(
      'fbUnsupportedPlatform',
    ),
    BillingFeedbackCode.storeUnavailable => BillingStrings.t(
      'fbStoreUnavailable',
    ),
    BillingFeedbackCode.missingProducts => BillingStrings.t(
      'fbMissingProducts',
    ),
    BillingFeedbackCode.offline => BillingStrings.t('fbOffline'),
    BillingFeedbackCode.offlineCacheExpired => BillingStrings.t(
      'fbOfflineCacheExpired',
    ),
    BillingFeedbackCode.alreadyOwned => BillingStrings.t('fbAlreadyOwned'),
    BillingFeedbackCode.userCanceled => BillingStrings.t('fbUserCanceled'),
    BillingFeedbackCode.pendingPayment => BillingStrings.t('fbPendingPayment'),
    BillingFeedbackCode.verificationFailed => BillingStrings.t(
      'fbVerificationFailed',
    ),
    BillingFeedbackCode.invalidSignature => BillingStrings.t(
      'fbInvalidSignature',
    ),
    BillingFeedbackCode.restoreSucceeded => BillingStrings.t(
      'fbRestoreSucceeded',
    ),
    BillingFeedbackCode.restoreEmpty => BillingStrings.t('fbRestoreEmpty'),
    BillingFeedbackCode.purchaseVerified => BillingStrings.t(
      'fbPurchaseVerified',
    ),
    BillingFeedbackCode.manageLinkFailed => BillingStrings.t(
      'fbManageLinkFailed',
    ),
    BillingFeedbackCode.unknownError => BillingStrings.t('fbUnknownError'),
  };
}

class _OfflineCacheBanner extends StatelessWidget {
  const _OfflineCacheBanner({required this.grant});

  final SignedEntitlementGrant grant;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppleSpacing.screen,
        0,
        AppleSpacing.screen,
        AppleSpacing.lg,
      ),
      child: Container(
        padding: const EdgeInsets.all(AppleSpacing.sm),
        decoration: BoxDecoration(
          color: c.orange.withValues(alpha: c.isDark ? 0.14 : 0.08),
          borderRadius: BorderRadius.circular(AppleRadii.md),
          border: Border.all(
            color: c.orange.withValues(alpha: c.isDark ? 0.35 : 0.25),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.cloud_off_rounded, size: 18, color: c.orange),
            const SizedBox(width: AppleSpacing.xs),
            Expanded(
              child: Text(
                BillingStrings.t('offlineNotice', {
                  'date': _formatIsoDate(grant.offlineValidUntil),
                }),
                style: type.footnote.copyWith(color: c.label),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlansSection extends StatelessWidget {
  const _PlansSection({
    required this.snapshot,
    required this.onSelect,
    required this.onSubscribe,
  });

  final SubscriptionSnapshot snapshot;
  final ValueChanged<SubscriptionPlanOffer> onSelect;
  final VoidCallback onSubscribe;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);

    if (!snapshot.isSupportedPlatform || !snapshot.isConfigured) {
      return InsetGroupedSection(
        header: BillingStrings.t('plansHeader'),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppleSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  BillingStrings.t('plansUnavailableTitle'),
                  style: type.callout.copyWith(color: c.label),
                ),
                const SizedBox(height: AppleSpacing.xxs),
                Text(
                  snapshot.isSupportedPlatform
                      ? BillingStrings.t('plansUnavailableBody')
                      : BillingStrings.t('detailUnsupportedPlatform'),
                  style: type.footnote.copyWith(color: c.secondaryLabel),
                ),
                const SizedBox(height: AppleSpacing.md),
                PrimaryButton(
                  label: BillingStrings.t('subscribeUnavailableButton'),
                  icon: Icons.lock_outline_rounded,
                  expand: true,
                  onPressed: null,
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (snapshot.isLoadingProducts) {
      return InsetGroupedSection(
        header: BillingStrings.t('plansHeader'),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppleSpacing.md),
            child: Row(
              children: [
                SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: c.accent,
                  ),
                ),
                const SizedBox(width: AppleSpacing.sm),
                Expanded(
                  child: Text(
                    BillingStrings.t('plansLoading'),
                    style: type.subheadline.copyWith(color: c.secondaryLabel),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    if (snapshot.offers.isEmpty) {
      return InsetGroupedSection(
        header: BillingStrings.t('plansHeader'),
        children: [
          Padding(
            padding: const EdgeInsets.all(AppleSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  BillingStrings.t('plansUnavailableTitle'),
                  style: type.callout.copyWith(color: c.label),
                ),
                const SizedBox(height: AppleSpacing.xxs),
                Text(
                  BillingStrings.t('plansMissingSkuBody'),
                  style: type.footnote.copyWith(color: c.secondaryLabel),
                ),
                const SizedBox(height: AppleSpacing.md),
                PrimaryButton(
                  label: BillingStrings.t('subscribeUnavailableButton'),
                  expand: true,
                  onPressed: null,
                ),
              ],
            ),
          ),
        ],
      );
    }

    final savings = snapshot.computedAnnualSavingsPercent;
    final selected = snapshot.selectedOffer;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InsetGroupedSection(
          header: BillingStrings.t('plansHeader'),
          footer: BillingStrings.t('plansSelectPrompt'),
          children: [
            for (final offer in snapshot.offers)
              _PlanOfferRow(
                offer: offer,
                selected: offer.selectionKey == snapshot.selectedOfferKey,
                savingsPercent: offer.interval == BillingInterval.yearly
                    ? savings
                    : null,
                onTap: () => onSelect(offer),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppleSpacing.screen,
            0,
            AppleSpacing.screen,
            AppleSpacing.lg,
          ),
          child: PrimaryButton(
            label: selected == null
                ? BillingStrings.t('subscribeSelectFirst')
                : BillingStrings.t('subscribeButton'),
            icon: Icons.shopping_bag_outlined,
            expand: true,
            loading: snapshot.isPurchaseInProgress,
            onPressed: snapshot.canSubscribe ? onSubscribe : null,
          ),
        ),
      ],
    );
  }
}

class _PlanOfferRow extends StatelessWidget {
  const _PlanOfferRow({
    required this.offer,
    required this.selected,
    required this.savingsPercent,
    required this.onTap,
  });

  final SubscriptionPlanOffer offer;
  final bool selected;
  final int? savingsPercent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final type = AppleTextStyles.of(context);
    final intervalLabel = offer.interval == BillingInterval.yearly
        ? BillingStrings.t('intervalYearly')
        : BillingStrings.t('intervalMonthly');
    final periodLabel = offer.interval == BillingInterval.yearly
        ? BillingStrings.t('periodPerYear')
        : BillingStrings.t('periodPerMonth');

    return Semantics(
      button: true,
      selected: selected,
      label: '$intervalLabel, ${offer.formattedPrice} $periodLabel',
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(AppleSpacing.md),
          color: selected
              ? c.accent.withValues(alpha: c.isDark ? 0.14 : 0.08)
              : Colors.transparent,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: selected ? c.accent : c.tertiaryLabel,
                ),
              ),
              const SizedBox(width: AppleSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: AppleSpacing.xs,
                      runSpacing: AppleSpacing.xxs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          intervalLabel,
                          style: type.headline.copyWith(color: c.label),
                        ),
                        if (savingsPercent != null)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppleSpacing.xs,
                              vertical: 2,
                            ),
                            decoration: ShapeDecoration(
                              color: c.green.withValues(
                                alpha: c.isDark ? 0.20 : 0.12,
                              ),
                              shape: const StadiumBorder(),
                            ),
                            child: Text(
                              BillingStrings.t('savingsBadge', {
                                'percent': '$savingsPercent',
                              }),
                              style: type.caption2.copyWith(
                                color: c.green,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppleSpacing.xxs),
                    Text(
                      '${offer.formattedPrice} · $periodLabel',
                      style: type.callout.copyWith(
                        color: c.label,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (offer.description.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        offer.description,
                        style: type.footnote.copyWith(color: c.secondaryLabel),
                      ),
                    ],
                    if (offer.hasFreeTrial) ...[
                      const SizedBox(height: AppleSpacing.xxs),
                      Text(
                        BillingStrings.t('freeTrialBadge', {
                          'period': BillingStrings.formatIsoPeriod(
                            offer.freeTrialPeriodIso!,
                          ),
                        }),
                        style: type.footnote.copyWith(
                          color: c.green,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    if (offer.hasIntroductoryOffer) ...[
                      const SizedBox(height: AppleSpacing.xxs),
                      Text(
                        BillingStrings.t('introOfferBadge', {
                          'price': offer.introductoryPriceFormatted!,
                        }),
                        style: type.footnote.copyWith(color: c.blue),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ManageSection extends StatelessWidget {
  const _ManageSection({
    required this.snapshot,
    required this.onRestore,
    required this.onRefresh,
    required this.onManage,
  });

  final SubscriptionSnapshot snapshot;
  final VoidCallback onRestore;
  final VoidCallback onRefresh;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    final c = AppleColors.of(context);
    final canQueryStore =
        snapshot.isSupportedPlatform &&
        snapshot.isConfigured &&
        !snapshot.isBusy;

    return InsetGroupedSection(
      header: BillingStrings.t('actionsHeader'),
      children: [
        if (snapshot.isSupportedPlatform && snapshot.isConfigured)
          ListRow(
            leading: ListRowIcon(Icons.restore_rounded, color: c.blue),
            title: BillingStrings.t('restoreButton'),
            enabled: canQueryStore,
            onTap: canQueryStore ? onRestore : null,
          ),
        if (snapshot.isSupportedPlatform &&
            snapshot.isConfigured &&
            snapshot.activeGrant != null)
          ListRow(
            leading: ListRowIcon(Icons.refresh_rounded, color: c.teal),
            title: BillingStrings.t('refreshButton'),
            enabled: canQueryStore,
            onTap: canQueryStore ? onRefresh : null,
          ),
        ListRow(
          leading: ListRowIcon(Icons.open_in_new_rounded, color: c.indigo),
          title: BillingStrings.t('manageButton'),
          onTap: onManage,
        ),
      ],
    );
  }
}

class _TermsSection extends StatelessWidget {
  const _TermsSection({required this.colors, required this.type});

  final AppleColors colors;
  final AppleTextStyles type;

  @override
  Widget build(BuildContext context) {
    return InsetGroupedSection(
      header: BillingStrings.t('termsHeader'),
      children: [
        Padding(
          padding: const EdgeInsets.all(AppleSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                BillingStrings.t('termsRecurring'),
                style: type.footnote.copyWith(color: colors.secondaryLabel),
              ),
              const SizedBox(height: AppleSpacing.xs),
              Text(
                BillingStrings.t('termsCancel'),
                style: type.footnote.copyWith(color: colors.secondaryLabel),
              ),
              const SizedBox(height: AppleSpacing.xs),
              Text(
                BillingStrings.t('termsSecurity'),
                style: type.footnote.copyWith(color: colors.secondaryLabel),
              ),
              const SizedBox(height: AppleSpacing.sm),
              Text(
                BillingStrings.t('termsPublisher'),
                style: type.caption1.copyWith(color: colors.tertiaryLabel),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _formatIsoDate(DateTime dt) {
  final u = dt.toUtc();
  final y = u.year.toString().padLeft(4, '0');
  final m = u.month.toString().padLeft(2, '0');
  final d = u.day.toString().padLeft(2, '0');
  return '$y-$m-$d';
}
