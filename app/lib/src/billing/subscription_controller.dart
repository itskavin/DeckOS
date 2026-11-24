/// Subscription state controller managing Play product queries, serialized &
/// idempotent purchase processing, trusted backend verification, bounded
/// offline entitlement caching, lifecycle refresh, and Play management links.
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import 'billing_config.dart';
import 'billing_gateways.dart';
import 'billing_models.dart';
import 'billing_storage.dart';
import 'entitlement_policy.dart';

typedef Clock = DateTime Function();
typedef ExternalUrlLauncher = Future<bool> Function(Uri uri);
typedef BillingLogSink = void Function(String message);

/// Immutable view-model snapshot exposed by [SubscriptionController].
class SubscriptionSnapshot {
  const SubscriptionSnapshot({
    required this.platform,
    required this.isConfigured,
    required this.storeAvailable,
    required this.entitlementState,
    required this.isProEntitled,
    required this.usingOfflineCache,
    required this.isLoadingProducts,
    required this.isPurchaseInProgress,
    required this.isRestoring,
    required this.isRefreshing,
    required this.offers,
    required this.missingProductIds,
    required this.selectedOfferKey,
    required this.feedback,
    this.activeGrant,
  });

  final BillingStorePlatform platform;
  final bool isConfigured;
  final bool storeAvailable;
  final EntitlementState entitlementState;

  /// True ONLY when a cryptographically verified, acknowledged, non-expired,
  /// offline-window-valid grant exists. Never `true` when unconfigured!
  final bool isProEntitled;
  final bool usingOfflineCache;
  final bool isLoadingProducts;
  final bool isPurchaseInProgress;
  final bool isRestoring;
  final bool isRefreshing;
  final List<SubscriptionPlanOffer> offers;
  final Set<String> missingProductIds;

  /// Explicitly chosen plan key; defaults to `null` (no preselected dark pattern).
  final String? selectedOfferKey;
  final BillingFeedback feedback;
  final SignedEntitlementGrant? activeGrant;

  bool get isSupportedPlatform =>
      platform == BillingStorePlatform.androidGooglePlay;

  bool get isBusy =>
      isLoadingProducts || isPurchaseInProgress || isRestoring || isRefreshing;

  SubscriptionPlanOffer? get selectedOffer {
    if (selectedOfferKey == null) return null;
    for (final offer in offers) {
      if (offer.selectionKey == selectedOfferKey) return offer;
    }
    return null;
  }

  bool get canSubscribe =>
      isSupportedPlatform &&
      isConfigured &&
      storeAvailable &&
      offers.isNotEmpty &&
      selectedOffer != null &&
      !isBusy;

  int? get computedAnnualSavingsPercent {
    SubscriptionPlanOffer? monthly;
    SubscriptionPlanOffer? yearly;
    for (final offer in offers) {
      if (offer.interval == BillingInterval.monthly && monthly == null) {
        monthly = offer;
      } else if (offer.interval == BillingInterval.yearly && yearly == null) {
        yearly = offer;
      }
    }
    return SubscriptionPlanOffer.computeAnnualSavingsPercent(
      monthly: monthly,
      yearly: yearly,
    );
  }
}

/// Manages the complete client-side subscription lifecycle for DeckOS.
class SubscriptionController extends ChangeNotifier {
  SubscriptionController({
    required this.config,
    required BillingStoreGateway storeGateway,
    required PurchaseVerificationClient verificationClient,
    required BillingCacheRepository cacheRepository,
    Clock? clock,
    ExternalUrlLauncher? urlLauncher,
    BillingLogSink? logSink,
  }) : _storeGateway = storeGateway,
       _verificationClient = verificationClient,
       _cacheRepository = cacheRepository,
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _urlLauncher = urlLauncher ?? _defaultLaunchExternalUrl,
       _logSink = logSink,
       policy = FeatureEntitlementPolicy(enforcedGates: config.enforcedGates) {
    _entitlementState = _initialBaselineState();
  }

  /// Safe default shipping controller when Google Play products and the
  /// verification backend have not been configured yet.
  factory SubscriptionController.unconfigured({
    BillingStorePlatform? platform,
    BillingStorage? storage,
  }) {
    const cfg = BillingConfig.unconfigured();
    return SubscriptionController(
      config: cfg,
      storeGateway: UnconfiguredBillingStoreGateway(platform: platform),
      verificationClient: const UnconfiguredPurchaseVerificationClient(),
      cacheRepository: BillingCacheRepository(
        storage ?? const SecureBillingStorage(),
      ),
    );
  }

  final BillingConfig config;
  final FeatureEntitlementPolicy policy;

  final BillingStoreGateway _storeGateway;
  final PurchaseVerificationClient _verificationClient;
  final BillingCacheRepository _cacheRepository;
  final Clock _clock;
  final ExternalUrlLauncher _urlLauncher;
  final BillingLogSink? _logSink;

  StreamSubscription<List<StorePurchaseUpdate>>? _purchaseSub;
  Future<void> _serialQueue = Future<void>.value();
  bool _initialized = false;
  bool _disposed = false;

  /// Deduplicates recently verified/completed purchase events by hashed token
  /// so replayed stream bursts are strictly idempotent.
  final Map<String, StorePurchaseStatus> _processedEventDigests =
      <String, StorePurchaseStatus>{};

  /// Tracks in-flight purchase token hashes to prevent duplicate concurrent
  /// verification calls.
  final Set<String> _inFlightTokenHashes = <String>{};

  String? _obfuscatedAccountId;
  bool _storeAvailable = false;
  bool _isLoadingProducts = false;
  bool _isPurchaseInProgress = false;
  bool _isRestoring = false;
  bool _isRefreshing = false;
  bool _usingOfflineCache = false;
  bool _receivedRestoreUpdate = false;
  List<SubscriptionPlanOffer> _offers = const <SubscriptionPlanOffer>[];
  Set<String> _missingProductIds = const <String>{};
  String? _selectedOfferKey;
  SignedEntitlementEnvelope? _activeEnvelope;
  bool _signatureVerified = false;
  late EntitlementState _entitlementState;
  BillingFeedback _feedback = BillingFeedback.none;

  SubscriptionSnapshot get snapshot => SubscriptionSnapshot(
    platform: _storeGateway.platform,
    isConfigured: config.isFullyConfigured,
    storeAvailable: _storeAvailable,
    entitlementState: _effectiveEntitlementState(),
    isProEntitled: isProEntitled,
    usingOfflineCache: _usingOfflineCache,
    isLoadingProducts: _isLoadingProducts,
    isPurchaseInProgress: _isPurchaseInProgress,
    isRestoring: _isRestoring,
    isRefreshing: _isRefreshing,
    offers: _offers,
    missingProductIds: _missingProductIds,
    selectedOfferKey: _selectedOfferKey,
    feedback: _feedback,
    activeGrant: _activeEnvelope?.grant,
  );

  /// True ONLY when a cryptographically verified, non-expired, offline-bounded
  /// entitlement grant is present.
  bool get isProEntitled {
    if (!config.isFullyConfigured) return false;
    final envelope = _activeEnvelope;
    if (envelope == null) return false;
    if (!_signatureVerified || !_hasValidGrantBinding(envelope.grant))
      return false;
    return envelope.grant.isEntitledAt(
      _clock(),
      expectedPackageName: config.packageName,
      expectedAccountId: _obfuscatedAccountId,
    );
  }

  /// Evaluates access to a feature using [policy] and verified entitlement.
  FeatureAccessDecision accessFor(BillingFeature feature) =>
      policy.evaluate(feature, hasVerifiedProEntitlement: isProEntitled);

  /// Initializes secure cache, attaches the purchase stream listener, loads
  /// Play products (if Android + configured), and refreshes cached entitlement.
  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _initialized = true;

    if (!_storeGateway.isSupportedPlatform) {
      _entitlementState = EntitlementState.unsupportedPlatform;
      _feedback = const BillingFeedback(
        BillingFeedbackCode.unsupportedPlatform,
      );
      _emit();
      return;
    }

    if (!config.isFullyConfigured) {
      _entitlementState = EntitlementState.unconfigured;
      _feedback = const BillingFeedback(BillingFeedbackCode.notConfigured);
      _emit();
      return;
    }

    _obfuscatedAccountId = await _cacheRepository
        .getOrCreateObfuscatedAccountId();
    await _loadVerifiedCachedEntitlement();

    _purchaseSub = _storeGateway.purchaseUpdates.listen(
      (updates) {
        _enqueue(() => _processPurchaseBatch(updates));
      },
      onError: (Object error, StackTrace _) {
        _log(
          'Purchase stream error: '
          '${BillingPrivacy.sanitizeDiagnostic(error.toString())}',
        );
        _isPurchaseInProgress = false;
        _isRestoring = false;
        _feedback = const BillingFeedback(
          BillingFeedbackCode.unknownError,
          isError: true,
        );
        _emit();
      },
    );

    await loadCatalog();
    if (_activeEnvelope != null) {
      await refreshEntitlement(silent: true);
    }
  }

  /// Queries Google Play for configured subscription product details.
  Future<void> loadCatalog() async {
    if (_disposed) return;
    if (!_storeGateway.isSupportedPlatform) {
      _entitlementState = EntitlementState.unsupportedPlatform;
      _emit();
      return;
    }
    if (!config.isFullyConfigured) {
      _entitlementState = EntitlementState.unconfigured;
      _emit();
      return;
    }

    _isLoadingProducts = true;
    _emit();
    try {
      final available = await _storeGateway.isStoreAvailable();
      _storeAvailable = available;
      if (!available) {
        _offers = const <SubscriptionPlanOffer>[];
        _feedback = const BillingFeedback(
          BillingFeedbackCode.storeUnavailable,
          isError: true,
        );
        return;
      }

      final result = await _storeGateway.querySubscriptionOffers(
        config.configuredProductIds,
      );
      _offers = List<SubscriptionPlanOffer>.unmodifiable(result.offers);
      _missingProductIds = Set<String>.unmodifiable(result.notFoundIds);

      // Clear selection if previously selected offer disappeared; never auto-select.
      if (_selectedOfferKey != null &&
          !_offers.any((o) => o.selectionKey == _selectedOfferKey)) {
        _selectedOfferKey = null;
      }

      if (result.hasError) {
        _log(
          'Catalog query error: '
          '${BillingPrivacy.sanitizeDiagnostic(result.errorMessage)}',
        );
        _feedback = const BillingFeedback(
          BillingFeedbackCode.offline,
          isError: true,
        );
      } else if (_offers.isEmpty) {
        _feedback = const BillingFeedback(BillingFeedbackCode.missingProducts);
      }
    } catch (e) {
      _log(
        'Catalog query exception: '
        '${BillingPrivacy.sanitizeDiagnostic(e.toString())}',
      );
      _storeAvailable = false;
      _feedback = const BillingFeedback(
        BillingFeedbackCode.storeUnavailable,
        isError: true,
      );
    } finally {
      _isLoadingProducts = false;
      _emit();
    }
  }

  /// Explicitly selects a plan offer (no plan is preselected by default).
  void selectOffer(SubscriptionPlanOffer offer) {
    if (_disposed) return;
    if (!_offers.any((o) => o.selectionKey == offer.selectionKey)) return;
    _selectedOfferKey = offer.selectionKey;
    if (_feedback.code == BillingFeedbackCode.userCanceled ||
        _feedback.code == BillingFeedbackCode.restoreEmpty) {
      _feedback = BillingFeedback.none;
    }
    _emit();
  }

  /// Starts Google Play's native subscription checkout for the selected offer.
  Future<void> purchaseSelectedPlan() async {
    if (_disposed) return;
    if (!_storeGateway.isSupportedPlatform) {
      _feedback = const BillingFeedback(
        BillingFeedbackCode.unsupportedPlatform,
        isError: true,
      );
      _emit();
      return;
    }
    if (!config.isFullyConfigured) {
      _feedback = const BillingFeedback(
        BillingFeedbackCode.notConfigured,
        isError: true,
      );
      _emit();
      return;
    }
    if (!_storeAvailable) {
      _feedback = const BillingFeedback(
        BillingFeedbackCode.storeUnavailable,
        isError: true,
      );
      _emit();
      return;
    }
    final offer = snapshot.selectedOffer;
    if (offer == null || _isPurchaseInProgress) return;

    _isPurchaseInProgress = true;
    _feedback = BillingFeedback.none;
    _emit();

    try {
      final accountId =
          _obfuscatedAccountId ??
          await _cacheRepository.getOrCreateObfuscatedAccountId();
      _obfuscatedAccountId = accountId;

      final launch = await _storeGateway.launchSubscriptionPurchase(
        offer: offer,
        obfuscatedAccountId: accountId,
      );
      switch (launch.status) {
        case PurchaseLaunchStatus.launched:
          // Keep _isPurchaseInProgress true until the purchase stream emits
          // pending/purchased/canceled/error.
          break;
        case PurchaseLaunchStatus.alreadyOwned:
          _isPurchaseInProgress = false;
          _feedback = const BillingFeedback(BillingFeedbackCode.alreadyOwned);
          break;
        case PurchaseLaunchStatus.canceled:
          _isPurchaseInProgress = false;
          _feedback = const BillingFeedback(BillingFeedbackCode.userCanceled);
          break;
        case PurchaseLaunchStatus.storeUnavailable:
          _isPurchaseInProgress = false;
          _storeAvailable = false;
          _feedback = const BillingFeedback(
            BillingFeedbackCode.storeUnavailable,
            isError: true,
          );
          break;
        case PurchaseLaunchStatus.notConfigured:
          _isPurchaseInProgress = false;
          _feedback = const BillingFeedback(
            BillingFeedbackCode.notConfigured,
            isError: true,
          );
          break;
        case PurchaseLaunchStatus.unsupportedPlatform:
          _isPurchaseInProgress = false;
          _feedback = const BillingFeedback(
            BillingFeedbackCode.unsupportedPlatform,
            isError: true,
          );
          break;
        case PurchaseLaunchStatus.failed:
          _isPurchaseInProgress = false;
          _log(
            'Purchase launch failed: '
            '${BillingPrivacy.sanitizeDiagnostic(launch.message)}',
          );
          _feedback = const BillingFeedback(
            BillingFeedbackCode.unknownError,
            isError: true,
          );
          break;
      }
    } catch (e) {
      _isPurchaseInProgress = false;
      _log(
        'Purchase launch exception: '
        '${BillingPrivacy.sanitizeDiagnostic(e.toString())}',
      );
      _feedback = const BillingFeedback(
        BillingFeedbackCode.unknownError,
        isError: true,
      );
    }
    _emit();
  }

  /// Triggers Google Play purchase restoration and re-verifies any returned
  /// subscriptions against the trusted backend.
  Future<void> restorePurchases() async {
    if (_disposed || _isRestoring) return;
    if (!_storeGateway.isSupportedPlatform) {
      _feedback = const BillingFeedback(
        BillingFeedbackCode.unsupportedPlatform,
        isError: true,
      );
      _emit();
      return;
    }
    if (!config.isFullyConfigured) {
      _feedback = const BillingFeedback(
        BillingFeedbackCode.notConfigured,
        isError: true,
      );
      _emit();
      return;
    }

    _isRestoring = true;
    _receivedRestoreUpdate = false;
    _feedback = BillingFeedback.none;
    _emit();

    try {
      final available = await _storeGateway.isStoreAvailable();
      _storeAvailable = available;
      if (!available) {
        _feedback = const BillingFeedback(
          BillingFeedbackCode.storeUnavailable,
          isError: true,
        );
        return;
      }

      // Clear prior dedupe cache so restore explicitly re-verifies current Play
      // tokens with the backend.
      _processedEventDigests.clear();
      await _storeGateway.restorePurchases();
      // Yield once so broadcast stream events delivered during restore enter
      // the serial queue before settling.
      await flushPendingEvents();

      if (!_receivedRestoreUpdate) {
        if (_activeEnvelope != null) {
          await refreshEntitlement(silent: false);
        } else {
          _feedback = const BillingFeedback(BillingFeedbackCode.restoreEmpty);
        }
      }
    } catch (e) {
      _log(
        'Restore purchases error: '
        '${BillingPrivacy.sanitizeDiagnostic(e.toString())}',
      );
      _feedback = const BillingFeedback(
        BillingFeedbackCode.offline,
        isError: true,
      );
    } finally {
      _isRestoring = false;
      _emit();
    }
  }

  /// Refreshes the cached entitlement from the trusted verification backend
  /// (e.g. on app resume after managing/canceling in Google Play).
  Future<void> refreshEntitlement({bool silent = false}) async {
    if (_disposed || _isRefreshing) return;
    if (!_storeGateway.isSupportedPlatform || !config.isFullyConfigured) {
      return;
    }

    final envelope = _activeEnvelope;
    if (envelope == null) {
      _obfuscatedAccountId = await _cacheRepository
          .getOrCreateObfuscatedAccountId();
      await _loadVerifiedCachedEntitlement();
      _emit();
      return;
    }

    _isRefreshing = true;
    _emit();
    try {
      final accountId =
          _obfuscatedAccountId ??
          await _cacheRepository.getOrCreateObfuscatedAccountId();
      final result = await _verificationClient.refreshEntitlement(
        packageName: config.packageName,
        entitlementId: envelope.grant.entitlementId,
        obfuscatedAccountId: accountId,
      );
      await _applyVerificationResult(result, silent: silent, isRestore: false);
    } finally {
      _isRefreshing = false;
      _emit();
    }
  }

  /// Lifecycle hook called when the app returns to foreground (for example,
  /// after the user leaves Google Play Subscription Center).
  Future<void> onAppResumed() async {
    if (_disposed || !_initialized) return;
    if (!_storeGateway.isSupportedPlatform || !config.isFullyConfigured) return;

    // Re-evaluate local bounded offline window immediately even before network.
    _evaluateOfflineBound();
    _emit();

    if (_activeEnvelope != null) {
      await refreshEntitlement(silent: true);
    } else if (_offers.isEmpty) {
      await loadCatalog();
    }
  }

  /// Opens Google Play's official Subscription Center deep link targeting this
  /// app's package name (and active product SKU when available).
  Future<bool> openManageSubscription() async {
    final uri = config.manageSubscriptionsUri(
      activeProductId: _activeEnvelope?.grant.productId,
    );
    try {
      final launched = await _urlLauncher(uri);
      if (!launched) {
        _feedback = const BillingFeedback(
          BillingFeedbackCode.manageLinkFailed,
          isError: true,
        );
        _emit();
      }
      return launched;
    } catch (_) {
      _feedback = const BillingFeedback(
        BillingFeedbackCode.manageLinkFailed,
        isError: true,
      );
      _emit();
      return false;
    }
  }

  /// Waits for all queued purchase stream events to settle (useful in tests
  /// and clean shutdown). Uses microtask scheduling so it works identically in
  /// real async and Flutter widget `FakeAsync` zones without creating timers.
  Future<void> flushPendingEvents() async {
    await Future<void>.microtask(() {});
    await _serialQueue;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _purchaseSub?.cancel();
    _purchaseSub = null;
    unawaited(_storeGateway.dispose());
    super.dispose();
  }

  // ---- Internal serialized stream processing ----

  void _enqueue(Future<void> Function() task) {
    _serialQueue = _serialQueue.then((_) async {
      if (_disposed) return;
      await task();
    });
  }

  Future<void> _processPurchaseBatch(List<StorePurchaseUpdate> updates) async {
    for (final update in updates) {
      if (_disposed) return;
      await _handleSinglePurchaseUpdate(update);
    }
  }

  Future<void> _handleSinglePurchaseUpdate(StorePurchaseUpdate update) async {
    _log('Handling purchase event: $update');
    switch (update.status) {
      case StorePurchaseStatus.pending:
        _isPurchaseInProgress = false;
        _entitlementState = EntitlementState.pending;
        _feedback = const BillingFeedback(BillingFeedbackCode.pendingPayment);
        _emit();
        return;

      case StorePurchaseStatus.canceled:
        _isPurchaseInProgress = false;
        _feedback = const BillingFeedback(BillingFeedbackCode.userCanceled);
        _emit();
        return;

      case StorePurchaseStatus.error:
        _isPurchaseInProgress = false;
        final code = update.errorCode?.toLowerCase() ?? '';
        if (code.contains('already_owned') || code == '7') {
          _feedback = const BillingFeedback(BillingFeedbackCode.alreadyOwned);
        } else if (code.contains('unavailable') || code == '3') {
          _storeAvailable = false;
          _feedback = const BillingFeedback(
            BillingFeedbackCode.storeUnavailable,
            isError: true,
          );
        } else {
          _feedback = const BillingFeedback(
            BillingFeedbackCode.unknownError,
            isError: true,
          );
        }
        _emit();
        return;

      case StorePurchaseStatus.purchased:
      case StorePurchaseStatus.restored:
        final token = update.purchaseToken?.trim();
        if (token == null || token.isEmpty) {
          _isPurchaseInProgress = false;
          _feedback = const BillingFeedback(
            BillingFeedbackCode.verificationFailed,
            isError: true,
          );
          _emit();
          return;
        }

        final tokenHash = _hashToken(token);
        if (_inFlightTokenHashes.contains(tokenHash)) {
          _log('Skipping duplicate in-flight purchase token $tokenHash');
          return;
        }
        if (_processedEventDigests[tokenHash] == update.status) {
          _log('Skipping already processed purchase event $tokenHash');
          _isPurchaseInProgress = false;
          _emit();
          return;
        }

        _inFlightTokenHashes.add(tokenHash);
        if (update.status == StorePurchaseStatus.restored || _isRestoring) {
          _receivedRestoreUpdate = true;
        }

        try {
          final accountId =
              _obfuscatedAccountId ??
              await _cacheRepository.getOrCreateObfuscatedAccountId();
          _obfuscatedAccountId = accountId;

          final result = await _verificationClient.verifyPurchase(
            packageName: config.packageName,
            productId: update.productId,
            purchaseToken: token,
            obfuscatedAccountId: accountId,
          );

          final accepted = await _applyVerificationResult(
            result,
            silent: false,
            isRestore:
                update.status == StorePurchaseStatus.restored || _isRestoring,
          );

          // CRITICAL: Never complete/acknowledge on client unless trusted
          // backend verification AND local Ed25519 signature checks succeeded!
          if (accepted && result.isVerified) {
            _processedEventDigests[tokenHash] = update.status;
            if (update.pendingCompletePurchase &&
                result.envelope!.grant.acknowledged) {
              await _storeGateway.completePurchase(update);
            }
          }
        } finally {
          _inFlightTokenHashes.remove(tokenHash);
          _isPurchaseInProgress = false;
          _emit();
        }
    }
  }

  Future<bool> _applyVerificationResult(
    VerificationResult result, {
    required bool silent,
    required bool isRestore,
  }) async {
    switch (result.status) {
      case VerificationStatus.verified:
        final envelope = result.envelope!;
        if (!await HttpPurchaseVerificationClient.verifyEnvelopeSignature(
          envelope,
          publicKeys: config.entitlementPublicKeys,
          expectedPackageName: config.packageName,
        )) {
          await _invalidateCachedEntitlement();
          _feedback = const BillingFeedback(
            BillingFeedbackCode.invalidSignature,
            isError: true,
          );
          return false;
        }

        final now = _clock();
        final grant = envelope.grant;
        // Clamp client-side trust if server exceeded client's max offline bound.
        final maxOfflineUntil = now.add(config.clampedOfflineGraceWindow);
        if (grant.offlineValidUntil.isAfter(
          maxOfflineUntil.add(const Duration(minutes: 5)),
        )) {
          _log(
            'Rejecting entitlement whose offline window exceeds client maximum.',
          );
          await _invalidateCachedEntitlement();
          _feedback = const BillingFeedback(
            BillingFeedbackCode.invalidSignature,
            isError: true,
          );
          return false;
        }

        if (!_hasValidGrantBinding(grant)) {
          await _invalidateCachedEntitlement();
          _feedback = const BillingFeedback(
            BillingFeedbackCode.invalidSignature,
            isError: true,
          );
          return false;
        }
        _signatureVerified = true;
        _activeEnvelope = envelope;
        _usingOfflineCache = false;
        _entitlementState = grant.state;
        await _cacheRepository.saveEnvelope(envelope);

        if (!silent) {
          if (grant.state == EntitlementState.pending) {
            _feedback = const BillingFeedback(
              BillingFeedbackCode.pendingPayment,
            );
          } else if (isRestore) {
            _feedback = BillingFeedback(
              isProEntitled
                  ? BillingFeedbackCode.restoreSucceeded
                  : BillingFeedbackCode.restoreEmpty,
            );
          } else if (isProEntitled) {
            _feedback = const BillingFeedback(
              BillingFeedbackCode.purchaseVerified,
            );
          } else {
            _feedback = BillingFeedback.none;
          }
        }
        return true;

      case VerificationStatus.notConfigured:
        _entitlementState = EntitlementState.unconfigured;
        if (!silent) {
          _feedback = const BillingFeedback(BillingFeedbackCode.notConfigured);
        }
        return false;

      case VerificationStatus.offline:
        // Stay within bounded offline cache if currently valid; expire if not!
        _evaluateOfflineBound();
        if (!silent) {
          _feedback = BillingFeedback(
            _activeEnvelope != null &&
                    _activeEnvelope!.grant.isOfflineWindowExpiredAt(_clock())
                ? BillingFeedbackCode.offlineCacheExpired
                : BillingFeedbackCode.offline,
            isError: true,
          );
        }
        return false;

      case VerificationStatus.invalidSignature:
        await _invalidateCachedEntitlement();
        _feedback = const BillingFeedback(
          BillingFeedbackCode.invalidSignature,
          isError: true,
        );
        return false;

      case VerificationStatus.rejected:
        // Server explicitly rejected the purchase/entitlement (e.g. forged,
        // revoked, wrong account, or unknown). Never retain stale Pro access.
        await _invalidateCachedEntitlement();
        _entitlementState = EntitlementState.free;
        if (!silent) {
          _feedback = const BillingFeedback(
            BillingFeedbackCode.verificationFailed,
            isError: true,
          );
        }
        return false;

      case VerificationStatus.serverError:
        _evaluateOfflineBound();
        if (!silent) {
          _feedback = const BillingFeedback(
            BillingFeedbackCode.verificationFailed,
            isError: true,
          );
        }
        return false;
    }
  }

  Future<void> _loadVerifiedCachedEntitlement() async {
    final cached = await _cacheRepository.readEnvelope();
    if (cached == null) {
      _signatureVerified = false;
      _activeEnvelope = null;
      _usingOfflineCache = false;
      _entitlementState = EntitlementState.free;
      return;
    }

    if (!await HttpPurchaseVerificationClient.verifyEnvelopeSignature(
      cached,
      publicKeys: config.entitlementPublicKeys,
      expectedPackageName: config.packageName,
    )) {
      _log('Cached entitlement failed Ed25519 signature check; clearing.');
      await _invalidateCachedEntitlement();
      _feedback = const BillingFeedback(
        BillingFeedbackCode.invalidSignature,
        isError: true,
      );
      return;
    }

    if (!_hasValidGrantBinding(cached.grant)) {
      await _invalidateCachedEntitlement();
      return;
    }
    _signatureVerified = true;
    _activeEnvelope = cached;
    _usingOfflineCache = true;
    _evaluateOfflineBound();
  }

  bool _hasValidGrantBinding(SignedEntitlementGrant grant) =>
      grant.packageName == config.packageName &&
      _obfuscatedAccountId != null &&
      grant.obfuscatedAccountId == _obfuscatedAccountId &&
      config.configuredProductIds.contains(grant.productId) &&
      !grant.offlineValidUntil.isAfter(
        grant.issuedAt.add(config.clampedOfflineGraceWindow),
      );

  void _evaluateOfflineBound() {
    final envelope = _activeEnvelope;
    if (envelope == null) {
      _entitlementState = _initialBaselineState();
      _usingOfflineCache = false;
      return;
    }
    final now = _clock();
    final grant = envelope.grant;
    if (grant.expiresAt != null && !now.isBefore(grant.expiresAt!)) {
      _entitlementState = EntitlementState.expired;
      _usingOfflineCache = false;
      return;
    }
    if (grant.isOfflineWindowExpiredAt(now)) {
      _entitlementState = EntitlementState.free;
      _usingOfflineCache = false;
      _feedback = const BillingFeedback(
        BillingFeedbackCode.offlineCacheExpired,
        isError: true,
      );
      return;
    }
    _entitlementState = grant.state;
  }

  Future<void> _invalidateCachedEntitlement() async {
    _signatureVerified = false;
    _activeEnvelope = null;
    _usingOfflineCache = false;
    _entitlementState = _initialBaselineState();
    await _cacheRepository.clearEnvelope();
  }

  EntitlementState _initialBaselineState() {
    if (!_storeGateway.isSupportedPlatform) {
      return EntitlementState.unsupportedPlatform;
    }
    if (!config.isFullyConfigured) {
      return EntitlementState.unconfigured;
    }
    return EntitlementState.free;
  }

  EntitlementState _effectiveEntitlementState() {
    final envelope = _activeEnvelope;
    if (envelope != null) {
      final now = _clock();
      if (envelope.grant.expiresAt != null &&
          !now.isBefore(envelope.grant.expiresAt!) &&
          (envelope.grant.state == EntitlementState.active ||
              envelope.grant.state == EntitlementState.inGracePeriod ||
              envelope.grant.state == EntitlementState.canceledActive)) {
        return EntitlementState.expired;
      }
      if (envelope.grant.isOfflineWindowExpiredAt(now)) {
        return EntitlementState.free;
      }
    }
    return _entitlementState;
  }

  String _hashToken(String token) =>
      crypto.sha256.convert(utf8.encode(token)).toString().substring(0, 16);

  void _log(String message) {
    _logSink?.call(message);
  }

  void _emit() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  static Future<bool> _defaultLaunchExternalUrl(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);
}
