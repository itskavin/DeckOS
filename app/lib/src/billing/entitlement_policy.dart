/// Feature-entitlement policy decoupling monetization gates from existing app
/// functionality.
///
/// Key invariants:
/// 1. Security, privacy, account-name masking, PC disconnect/forgetting, and
///    data-deletion controls are ALWAYS free and cannot be paywalled.
/// 2. While the owner has not approved Free vs Pro gates (`enforcedGates` is
///    empty), existing features continue to work normally without claiming a
///    Pro entitlement or shipping a universal beta-bypass flag.
library;

/// Logical DeckOS feature capabilities evaluated against [FeatureEntitlementPolicy].
enum BillingFeature {
  // --- Permanently free / never gateable ---
  securityAndPairing,
  privacyNoticeAndControls,
  accountNameMasking,
  basicDisconnectAndForgetPc,
  dataDeletion,
  basicDeckRemote,
  basicAudioMixer,

  // --- Candidate Pro features (deferred until owner approves gates) ---
  unlimitedPagesAndProfiles,
  advancedDeckCustomization,
  aiLimitsOverview,
  automationsAndTriggers,
  multiPcManagement,
  profileBackupAndShare,
}

enum FeatureAccessReason {
  alwaysFree,
  gateNotEnabled,
  proEntitled,
  requiresProSubscription,
}

class FeatureAccessDecision {
  const FeatureAccessDecision({
    required this.feature,
    required this.allowed,
    required this.reason,
  });

  final BillingFeature feature;
  final bool allowed;
  final FeatureAccessReason reason;
}

/// Evaluates whether a given [BillingFeature] is accessible for the current
/// entitlement state and configured gate set.
class FeatureEntitlementPolicy {
  const FeatureEntitlementPolicy({
    this.enforcedGates = const <BillingFeature>{},
  });

  /// Security, privacy, name-masking, disconnect, data-deletion, and core
  /// remote controls can NEVER be paywalled.
  static const Set<BillingFeature> neverGateable = <BillingFeature>{
    BillingFeature.securityAndPairing,
    BillingFeature.privacyNoticeAndControls,
    BillingFeature.accountNameMasking,
    BillingFeature.basicDisconnectAndForgetPc,
    BillingFeature.dataDeletion,
    BillingFeature.basicDeckRemote,
    BillingFeature.basicAudioMixer,
  };

  /// Candidate features that MAY be gated later once the owner finalizes
  /// Free vs Pro packaging and pricing.
  static const Set<BillingFeature> candidateProFeatures = <BillingFeature>{
    BillingFeature.unlimitedPagesAndProfiles,
    BillingFeature.advancedDeckCustomization,
    BillingFeature.aiLimitsOverview,
    BillingFeature.automationsAndTriggers,
    BillingFeature.multiPcManagement,
    BillingFeature.profileBackupAndShare,
  };

  final Set<BillingFeature> enforcedGates;

  /// Effective active gates after stripping any [neverGateable] features.
  Set<BillingFeature> get activeGates =>
      enforcedGates.difference(neverGateable);

  static bool isNeverGateable(BillingFeature feature) =>
      neverGateable.contains(feature);

  FeatureAccessDecision evaluate(
    BillingFeature feature, {
    required bool hasVerifiedProEntitlement,
  }) {
    if (isNeverGateable(feature)) {
      return FeatureAccessDecision(
        feature: feature,
        allowed: true,
        reason: FeatureAccessReason.alwaysFree,
      );
    }
    if (!enforcedGates.contains(feature)) {
      return FeatureAccessDecision(
        feature: feature,
        allowed: true,
        reason: FeatureAccessReason.gateNotEnabled,
      );
    }
    if (hasVerifiedProEntitlement) {
      return FeatureAccessDecision(
        feature: feature,
        allowed: true,
        reason: FeatureAccessReason.proEntitled,
      );
    }
    return FeatureAccessDecision(
      feature: feature,
      allowed: false,
      reason: FeatureAccessReason.requiresProSubscription,
    );
  }
}
