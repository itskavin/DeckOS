/// Domain models for DeckOS Google Play subscription billing, signed server
/// entitlements, purchase events, and user-facing feedback.
///
/// Privacy invariant: raw Google Play `purchaseToken` values must NEVER appear
/// in `toString()`, logs, error messages, or UI text.
library;

import 'dart:convert';

/// Supported billing intervals for renewable DeckOS subscriptions.
enum BillingInterval { monthly, yearly }

/// Runtime platform capability for Google Play Billing.
enum BillingStorePlatform { androidGooglePlay, ios, web, desktop, unsupported }

/// Verified lifecycle state of a DeckOS subscription entitlement.
enum EntitlementState {
  /// Play products or trusted verification backend are not configured yet.
  unconfigured,

  /// Current platform does not support Google Play Billing (e.g. Web, iOS, desktop).
  unsupportedPlatform,

  /// No active subscription found.
  free,

  /// Google Play reported a pending payment (e.g. delayed cash/bank method).
  /// Paid access MUST NOT be granted while pending.
  pending,

  /// Verified, acknowledged active auto-renewing subscription.
  active,

  /// Payment failed but Google Play granted a grace period; access remains
  /// temporarily active while Play retries payment.
  inGracePeriod,

  /// Subscription is in Google Play Account Hold; paid access MUST be suspended.
  onHold,

  /// Subscription is paused by the user; paid access MUST be suspended.
  paused,

  /// Auto-renewal was canceled, but the paid period has not ended yet.
  canceledActive,

  /// Subscription expired; paid access MUST NOT be granted.
  expired,

  /// Subscription was refunded or revoked; paid access MUST be revoked immediately.
  revoked,
}

/// Structured offer returned directly from Google Play `ProductDetails`.
///
/// Prices, currencies, billing periods, and optional trial/intro offers MUST
/// originate from Google Play and never be fabricated locally.
class SubscriptionPlanOffer {
  const SubscriptionPlanOffer({
    required this.productId,
    required this.interval,
    required this.title,
    required this.description,
    required this.formattedPrice,
    required this.priceAmountMicros,
    required this.currencyCode,
    required this.billingPeriodIso,
    this.basePlanId,
    this.offerId,
    this.offerToken,
    this.freeTrialPeriodIso,
    this.introductoryPriceFormatted,
    this.introductoryPeriodIso,
  });

  final String productId;
  final BillingInterval interval;
  final String title;
  final String description;

  /// Localized formatted price string directly from Google Play (e.g. "$4.99").
  final String formattedPrice;

  /// Price in micro-units (1,000,000 = 1 unit of [currencyCode]) directly from
  /// Google Play `PricingPhase.priceAmountMicros`.
  final int priceAmountMicros;

  /// ISO-4217 currency code directly from Google Play (e.g. "USD", "INR").
  final String currencyCode;

  /// ISO-8601 billing period (e.g. "P1M", "P1Y").
  final String billingPeriodIso;

  final String? basePlanId;
  final String? offerId;
  final String? offerToken;

  /// Present ONLY when Google Play actually returns a zero-cost trial phase.
  final String? freeTrialPeriodIso;

  /// Present ONLY when Google Play actually returns an introductory pricing phase.
  final String? introductoryPriceFormatted;
  final String? introductoryPeriodIso;

  bool get hasFreeTrial =>
      freeTrialPeriodIso != null && freeTrialPeriodIso!.trim().isNotEmpty;

  bool get hasIntroductoryOffer =>
      introductoryPriceFormatted != null &&
      introductoryPriceFormatted!.trim().isNotEmpty;

  /// Unique selection key distinguishing offers/base plans.
  String get selectionKey => '$productId:${basePlanId ?? ''}:${offerId ?? ''}';

  /// Computes integer percentage savings of [yearly] versus 12x [monthly]
  /// ONLY when both offers came from Play with positive prices in the exact
  /// same currency and yearly is strictly cheaper. Returns `null` otherwise so
  /// savings badges are never fabricated.
  static int? computeAnnualSavingsPercent({
    required SubscriptionPlanOffer? monthly,
    required SubscriptionPlanOffer? yearly,
  }) {
    if (monthly == null || yearly == null) return null;
    if (monthly.priceAmountMicros <= 0 || yearly.priceAmountMicros <= 0) {
      return null;
    }
    if (monthly.currencyCode.toUpperCase() !=
        yearly.currencyCode.toUpperCase()) {
      return null;
    }
    final annualizedMonthly = monthly.priceAmountMicros * 12;
    if (yearly.priceAmountMicros >= annualizedMonthly) return null;
    final savings =
        ((annualizedMonthly - yearly.priceAmountMicros) * 100) ~/
        annualizedMonthly;
    return savings > 0 ? savings : null;
  }
}

/// Result of querying Google Play `ProductDetails` for configured product IDs.
class StoreProductQueryResult {
  const StoreProductQueryResult({
    required this.offers,
    this.notFoundIds = const <String>{},
    this.errorMessage,
  });

  final List<SubscriptionPlanOffer> offers;
  final Set<String> notFoundIds;
  final String? errorMessage;

  bool get hasError => errorMessage != null && errorMessage!.isNotEmpty;
}

/// Status of an event delivered on the store purchase stream.
enum StorePurchaseStatus { pending, purchased, restored, canceled, error }

/// Normalized purchase event from Google Play Billing.
class StorePurchaseUpdate {
  const StorePurchaseUpdate({
    required this.productId,
    required this.status,
    this.purchaseId,
    this.purchaseToken,
    this.pendingCompletePurchase = false,
    this.errorCode,
    this.errorMessage,
    this.transactionDateMs,
  });

  final String productId;
  final StorePurchaseStatus status;
  final String? purchaseId;

  /// Sensitive Play purchase token. Never logged or displayed in plaintext.
  final String? purchaseToken;
  final bool pendingCompletePurchase;
  final String? errorCode;
  final String? errorMessage;
  final int? transactionDateMs;

  @override
  String toString() =>
      'StorePurchaseUpdate(productId: $productId, status: ${status.name}, '
      'purchaseId: ${purchaseId ?? 'none'}, '
      'token: ${BillingPrivacy.redactToken(purchaseToken)}, '
      'pendingComplete: $pendingCompletePurchase, '
      'errorCode: ${errorCode ?? 'none'})';
}

/// Result of attempting to launch the native Play Billing purchase sheet.
enum PurchaseLaunchStatus {
  launched,
  alreadyOwned,
  storeUnavailable,
  notConfigured,
  unsupportedPlatform,
  canceled,
  failed,
}

class PurchaseLaunchResult {
  const PurchaseLaunchResult(this.status, {this.message});

  final PurchaseLaunchStatus status;
  final String? message;
}

/// Cryptographically signed entitlement payload issued by the trusted billing
/// verification backend after querying Google Play Developer API
/// `purchases.subscriptionsv2.get`.
class SignedEntitlementGrant {
  const SignedEntitlementGrant({
    required this.version,
    required this.packageName,
    required this.entitlementId,
    required this.state,
    required this.issuedAt,
    required this.offlineValidUntil,
    required this.autoRenewing,
    required this.acknowledged,
    required this.obfuscatedAccountId,
    this.productId,
    this.expiresAt,
  });

  static const int currentVersion = 1;

  final int version;
  final String packageName;

  /// Opaque server-issued entitlement handle (NOT the raw Play purchaseToken).
  final String entitlementId;
  final String? productId;
  final EntitlementState state;
  final DateTime issuedAt;
  final DateTime? expiresAt;

  /// Hard upper bound for offline trust of this signed grant.
  final DateTime offlineValidUntil;
  final bool autoRenewing;
  final bool acknowledged;
  final String obfuscatedAccountId;

  /// Returns `true` ONLY when this grant authorizes Pro features at [now].
  ///
  /// Strictly enforces:
  /// - expected Android package name
  /// - server-acknowledged purchase
  /// - entitled lifecycle state (`active`, `inGracePeriod`, `canceledActive`)
  /// - non-expired subscription expiry timestamp
  /// - bounded offline validity window
  /// - basic clock-rollback guard (rejects > 10 minutes before `issuedAt`)
  bool isEntitledAt(
    DateTime now, {
    required String expectedPackageName,
    String? expectedAccountId,
  }) {
    if (version != currentVersion) return false;
    if (packageName != expectedPackageName) return false;
    if (expectedAccountId != null &&
        expectedAccountId.isNotEmpty &&
        obfuscatedAccountId != expectedAccountId) {
      return false;
    }
    if (!acknowledged) return false;
    final entitledState =
        state == EntitlementState.active ||
        state == EntitlementState.inGracePeriod ||
        state == EntitlementState.canceledActive;
    if (!entitledState) return false;
    if (expiresAt == null || !now.isBefore(expiresAt!)) return false;
    if (!now.isBefore(offlineValidUntil)) return false;
    final earliestAllowed = issuedAt.subtract(const Duration(minutes: 10));
    if (now.isBefore(earliestAllowed)) return false;
    return true;
  }

  /// Whether this grant was active but its bounded offline trust window has
  /// elapsed and requires a fresh server check.
  bool isOfflineWindowExpiredAt(DateTime now) {
    final entitledState =
        state == EntitlementState.active ||
        state == EntitlementState.inGracePeriod ||
        state == EntitlementState.canceledActive;
    if (!entitledState) return false;
    if (expiresAt != null && !now.isBefore(expiresAt!)) return false;
    return !now.isBefore(offlineValidUntil);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': version,
    'pkg': packageName,
    'eid': entitlementId,
    if (productId != null) 'pid': productId,
    'state': state.name,
    'iat': issuedAt.toUtc().millisecondsSinceEpoch,
    if (expiresAt != null) 'exp': expiresAt!.toUtc().millisecondsSinceEpoch,
    'ovu': offlineValidUntil.toUtc().millisecondsSinceEpoch,
    'ar': autoRenewing,
    'ack': acknowledged,
    'aid': obfuscatedAccountId,
  };

  static SignedEntitlementGrant? tryParseJson(Map<String, dynamic> json) {
    try {
      final version = json['v'];
      final pkg = json['pkg'];
      final eid = json['eid'];
      final stateName = json['state'];
      final iat = json['iat'];
      final ovu = json['ovu'];
      final ar = json['ar'];
      final ack = json['ack'];
      final aid = json['aid'];
      if (version is! int ||
          pkg is! String ||
          eid is! String ||
          stateName is! String ||
          iat is! int ||
          ovu is! int ||
          ar is! bool ||
          ack is! bool ||
          aid is! String) {
        return null;
      }
      final state = EntitlementState.values.where((s) => s.name == stateName);
      if (state.isEmpty) return null;
      final exp = json['exp'];
      final pid = json['pid'];
      if (exp != null && exp is! int) return null;
      if (pid != null && pid is! String) return null;
      return SignedEntitlementGrant(
        version: version,
        packageName: pkg,
        entitlementId: eid,
        productId: pid as String?,
        state: state.first,
        issuedAt: DateTime.fromMillisecondsSinceEpoch(iat, isUtc: true),
        expiresAt: exp == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(exp as int, isUtc: true),
        offlineValidUntil: DateTime.fromMillisecondsSinceEpoch(
          ovu,
          isUtc: true,
        ),
        autoRenewing: ar,
        acknowledged: ack,
        obfuscatedAccountId: aid,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Wire and local-cache envelope pairing a canonical base64url JSON payload
/// with its Ed25519 signature and signing `keyId`.
class SignedEntitlementEnvelope {
  const SignedEntitlementEnvelope({
    required this.keyId,
    required this.payloadBase64Url,
    required this.signatureBase64Url,
    required this.grant,
  });

  final String keyId;
  final String payloadBase64Url;
  final String signatureBase64Url;
  final SignedEntitlementGrant grant;

  Map<String, Object?> toJson() => <String, Object?>{
    'kid': keyId,
    'payload': payloadBase64Url,
    'sig': signatureBase64Url,
  };

  static SignedEntitlementEnvelope? tryParseJson(Map<String, dynamic> json) {
    final kid = json['kid'];
    final payload = json['payload'];
    final sig = json['sig'];
    if (kid is! String ||
        kid.isEmpty ||
        payload is! String ||
        payload.isEmpty ||
        sig is! String ||
        sig.isEmpty) {
      return null;
    }
    try {
      final decodedBytes = base64Url.decode(base64Url.normalize(payload));
      final payloadMap =
          jsonDecode(utf8.decode(decodedBytes)) as Map<String, dynamic>;
      final grant = SignedEntitlementGrant.tryParseJson(payloadMap);
      if (grant == null) return null;
      return SignedEntitlementEnvelope(
        keyId: kid,
        payloadBase64Url: payload,
        signatureBase64Url: sig,
        grant: grant,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Structured feedback codes surfaced to the Subscription UI without leaking
/// sensitive purchase tokens or internal backend details.
enum BillingFeedbackCode {
  none,
  notConfigured,
  unsupportedPlatform,
  storeUnavailable,
  missingProducts,
  offline,
  offlineCacheExpired,
  alreadyOwned,
  userCanceled,
  pendingPayment,
  verificationFailed,
  invalidSignature,
  restoreSucceeded,
  restoreEmpty,
  purchaseVerified,
  manageLinkFailed,
  unknownError,
}

class BillingFeedback {
  const BillingFeedback(this.code, {this.isError = false, this.detail});

  static const none = BillingFeedback(BillingFeedbackCode.none);

  final BillingFeedbackCode code;
  final bool isError;
  final String? detail;

  bool get isVisible => code != BillingFeedbackCode.none;
}

/// Privacy helpers ensuring raw Play purchase tokens are never logged or
/// echoed into error messages.
abstract final class BillingPrivacy {
  static String redactToken(String? token) {
    if (token == null || token.isEmpty) return '<empty>';
    return '[redacted:${token.length}ch]';
  }

  /// Strips token-like substrings and query parameters before logging or
  /// displaying diagnostic details.
  static String sanitizeDiagnostic(
    String? raw, {
    Iterable<String> sensitiveValues = const <String>[],
  }) {
    if (raw == null || raw.isEmpty) return '';
    var sanitized = raw;
    for (final secret in sensitiveValues) {
      if (secret.isNotEmpty) {
        sanitized = sanitized.replaceAll(secret, '[redacted]');
      }
    }
    // Redact common Google Play purchase token patterns (long base64/alnum runs).
    sanitized = sanitized.replaceAll(
      RegExp(r'\b[A-Za-z0-9._-]{32,}\b'),
      '[redacted]',
    );
    return sanitized;
  }
}
