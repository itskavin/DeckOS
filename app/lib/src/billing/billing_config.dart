/// Configuration for DeckOS Google Play subscription billing and server-side
/// entitlement verification.
///
/// Shipping defaults are intentionally [BillingConfig.unconfigured] until the
/// owner creates Google Play subscription products and provisions the trusted
/// verification backend. Never hardcode fabricated prices, secrets, or local
/// PC companion URLs here.
library;

import 'entitlement_policy.dart';

/// Immutable configuration describing Play product IDs, the trusted HTTPS
/// verification backend, Ed25519 public verification keys, and offline cache
/// bounds.
class BillingConfig {
  const BillingConfig({
    this.packageName = defaultPackageName,
    this.monthlyProductId,
    this.yearlyProductId,
    this.verificationEndpoint,
    this.entitlementPublicKeys = const <String, String>{},
    this.offlineGraceWindow = defaultOfflineGraceWindow,
    this.enforcedGates = const <BillingFeature>{},
  });

  /// Production Android application ID for DeckOS (publisher: Bytetrix).
  static const String defaultPackageName = 'io.github.itskavin.deckos';

  /// Recommended Play Console subscription product IDs once created by owner.
  static const String recommendedMonthlyProductId = 'deckos_pro_monthly';
  static const String recommendedYearlyProductId = 'deckos_pro_yearly';

  /// Maximum offline validity window for a cryptographically signed grant.
  static const Duration defaultOfflineGraceWindow = Duration(hours: 72);

  /// Hard upper bound for offline caching so a cached token can never become a
  /// permanent unrevoked entitlement.
  static const Duration maxOfflineGraceWindow = Duration(days: 7);

  /// Default shipping configuration while Play products and the verification
  /// backend are not yet configured.
  const BillingConfig.unconfigured()
    : packageName = defaultPackageName,
      monthlyProductId = null,
      yearlyProductId = null,
      verificationEndpoint = null,
      entitlementPublicKeys = const <String, String>{},
      offlineGraceWindow = defaultOfflineGraceWindow,
      enforcedGates = const <BillingFeature>{};

  final String packageName;
  final String? monthlyProductId;
  final String? yearlyProductId;

  /// Trusted HTTPS verification backend origin (never the user's PC companion).
  final Uri? verificationEndpoint;

  /// Map of `keyId` -> base64url (or standard base64) 32-byte Ed25519 public
  /// key used to verify signed entitlement grants returned by the backend.
  final Map<String, String> entitlementPublicKeys;

  /// Bounded offline cache window applied to signed entitlement grants.
  final Duration offlineGraceWindow;

  /// Feature gates currently enforced. Empty until owner explicitly approves
  /// Free vs Pro boundaries. Security/privacy features can never be gated.
  final Set<BillingFeature> enforcedGates;

  /// All non-empty subscription product IDs configured for Play Store query.
  Set<String> get configuredProductIds => <String>{
    if (monthlyProductId != null && monthlyProductId!.trim().isNotEmpty)
      monthlyProductId!.trim(),
    if (yearlyProductId != null && yearlyProductId!.trim().isNotEmpty)
      yearlyProductId!.trim(),
  };

  bool get hasConfiguredProducts => configuredProductIds.isNotEmpty;

  /// Verification backend is only valid when using HTTPS on a non-loopback,
  /// non-empty host and paired with at least one Ed25519 public key.
  bool get hasTrustedVerificationBackend {
    final uri = verificationEndpoint;
    if (uri == null || entitlementPublicKeys.isEmpty) return false;
    return isValidVerificationEndpoint(uri);
  }

  /// True only when BOTH Play product IDs and the trusted HTTPS verification
  /// backend + public verification keys are configured.
  bool get isFullyConfigured =>
      hasConfiguredProducts && hasTrustedVerificationBackend;

  /// Effective offline grace window clamped to [maxOfflineGraceWindow].
  Duration get clampedOfflineGraceWindow {
    if (offlineGraceWindow <= Duration.zero) return Duration.zero;
    if (offlineGraceWindow > maxOfflineGraceWindow) {
      return maxOfflineGraceWindow;
    }
    return offlineGraceWindow;
  }

  /// Validates that [uri] is HTTPS and does not point to a local/LAN companion
  /// host. Local PC companions are user-controlled and never trusted license
  /// authorities.
  static bool isValidVerificationEndpoint(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https') return false;
    if (uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.port != 443)
      return false;
    final host = uri.host.toLowerCase();
    // Compile-time owner configuration only, never discovery/user-entered URLs.
    // Native transport also resolves DNS, rejects nonpublic addresses, uses
    // ordinary CA/hostname verification and refuses all redirects.
    if (!RegExp(
      r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$',
    ).hasMatch(host))
      return false;
    final suffix = host.split('.').last;
    return RegExp(r'^[a-z]{2,}$').hasMatch(suffix) &&
        !const {
          'local',
          'localhost',
          'internal',
          'lan',
          'home',
          'test',
          'invalid',
        }.contains(suffix);
  }

  /// Official Google Play Subscription Center deep link for managing or
  /// canceling a subscription.
  ///
  /// Primary doc:
  /// https://developer.android.com/google/play/billing/subscriptions#deep-link
  Uri manageSubscriptionsUri({String? activeProductId}) {
    final query = <String, String>{'package': packageName};
    final sku = activeProductId?.trim();
    if (sku != null && sku.isNotEmpty) {
      query['sku'] = sku;
    }
    return Uri.https('play.google.com', '/store/account/subscriptions', query);
  }
}
