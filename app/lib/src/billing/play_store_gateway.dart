/// Concrete Google Play Billing adapter built on Flutter's official
/// `in_app_purchase: ^3.3.1` and `in_app_purchase_android: ^0.5.5`
/// (Google Play Billing Library 9.1+, compliant with Play's PBL 8.0+ mandate).
///
/// Android-only: non-Android platforms return honest unsupported results and
/// never invoke Google Play Billing APIs.
library;

import 'dart:async';

import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'billing_config.dart';
import 'billing_gateways.dart';
import 'billing_models.dart';

/// Android Google Play implementation of [BillingStoreGateway].
class PlayStoreBillingGateway implements BillingStoreGateway {
  PlayStoreBillingGateway({
    required BillingConfig config,
    InAppPurchase? inAppPurchase,
    BillingStorePlatform? platformOverride,
  }) : _config = config,
       _iap = inAppPurchase ?? InAppPurchase.instance,
       platform = platformOverride ?? detectBillingStorePlatform() {
    if (isSupportedPlatform) {
      _sub = _iap.purchaseStream.listen((purchases) {
        final normalized = <StorePurchaseUpdate>[];
        for (final purchase in purchases) {
          final token = purchase.verificationData.serverVerificationData;
          if (token.isNotEmpty) {
            _rawByToken[token] = purchase;
          }
          normalized.add(_mapPurchase(purchase));
        }
        _updates.add(normalized);
      }, onError: _updates.addError);
    }
  }

  final BillingConfig _config;
  final InAppPurchase _iap;
  final StreamController<List<StorePurchaseUpdate>> _updates =
      StreamController<List<StorePurchaseUpdate>>.broadcast();
  final Map<String, ProductDetails> _productDetailsByKey =
      <String, ProductDetails>{};
  final Map<String, PurchaseDetails> _rawByToken = <String, PurchaseDetails>{};
  StreamSubscription<List<PurchaseDetails>>? _sub;

  @override
  final BillingStorePlatform platform;

  @override
  bool get isSupportedPlatform =>
      platform == BillingStorePlatform.androidGooglePlay;

  @override
  Stream<List<StorePurchaseUpdate>> get purchaseUpdates => _updates.stream;

  @override
  Future<bool> isStoreAvailable() async {
    if (!isSupportedPlatform) return false;
    return _iap.isAvailable();
  }

  @override
  Future<StoreProductQueryResult> querySubscriptionOffers(
    Set<String> productIds,
  ) async {
    if (!isSupportedPlatform || productIds.isEmpty) {
      return StoreProductQueryResult(
        offers: const <SubscriptionPlanOffer>[],
        notFoundIds: productIds,
      );
    }

    final response = await _iap.queryProductDetails(productIds);
    final offers = <SubscriptionPlanOffer>[];
    _productDetailsByKey.clear();

    for (final details in response.productDetails) {
      final offer = _mapProductDetails(details);
      if (offer == null) continue;
      _productDetailsByKey[offer.selectionKey] = details;
      offers.add(offer);
    }

    // Present monthly first, yearly second for consistent neutral layout.
    offers.sort((a, b) => a.interval.index.compareTo(b.interval.index));

    return StoreProductQueryResult(
      offers: offers,
      notFoundIds: response.notFoundIDs.toSet(),
      errorMessage: response.error?.message,
    );
  }

  @override
  Future<PurchaseLaunchResult> launchSubscriptionPurchase({
    required SubscriptionPlanOffer offer,
    required String obfuscatedAccountId,
  }) async {
    if (!isSupportedPlatform) {
      return const PurchaseLaunchResult(
        PurchaseLaunchStatus.unsupportedPlatform,
      );
    }
    final details = _productDetailsByKey[offer.selectionKey];
    if (details == null) {
      return const PurchaseLaunchResult(
        PurchaseLaunchStatus.notConfigured,
        message: 'ProductDetails not loaded from Google Play.',
      );
    }

    final param = GooglePlayPurchaseParam(
      productDetails: details,
      applicationUserName: obfuscatedAccountId,
    );

    try {
      final launched = await _iap.buyNonConsumable(purchaseParam: param);
      return PurchaseLaunchResult(
        launched ? PurchaseLaunchStatus.launched : PurchaseLaunchStatus.failed,
      );
    } catch (e) {
      final text = e.toString().toLowerCase();
      if (text.contains('item_already_owned') ||
          text.contains('already_owned')) {
        return const PurchaseLaunchResult(PurchaseLaunchStatus.alreadyOwned);
      }
      if (text.contains('user_canceled')) {
        return const PurchaseLaunchResult(PurchaseLaunchStatus.canceled);
      }
      return PurchaseLaunchResult(
        PurchaseLaunchStatus.failed,
        message: BillingPrivacy.sanitizeDiagnostic(e.toString()),
      );
    }
  }

  @override
  Future<void> restorePurchases() async {
    if (!isSupportedPlatform) return;
    await _iap.restorePurchases();
  }

  @override
  Future<void> completePurchase(StorePurchaseUpdate purchase) async {
    if (!isSupportedPlatform) return;
    final token = purchase.purchaseToken;
    if (token == null || token.isEmpty) return;
    final raw = _rawByToken[token];
    if (raw != null && raw.pendingCompletePurchase) {
      await _iap.completePurchase(raw);
    }
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    _sub = null;
    await _updates.close();
  }

  SubscriptionPlanOffer? _mapProductDetails(ProductDetails details) {
    if (details is GooglePlayProductDetails) {
      final subOffer = _selectOfferDetails(details);
      final phases = subOffer?.pricingPhases ?? const <PricingPhaseWrapper>[];
      PricingPhaseWrapper? recurringPhase;
      PricingPhaseWrapper? freeTrialPhase;
      PricingPhaseWrapper? introPhase;

      for (final phase in phases) {
        if (phase.priceAmountMicros == 0 && freeTrialPhase == null) {
          freeTrialPhase = phase;
        } else if (phase.recurrenceMode == RecurrenceMode.infiniteRecurring) {
          recurringPhase = phase;
        } else {
          introPhase ??= phase;
        }
      }
      recurringPhase ??= phases.isNotEmpty ? phases.last : null;

      final periodIso =
          recurringPhase?.billingPeriod ??
          (details.id == _config.yearlyProductId ? 'P1Y' : 'P1M');
      final interval = _resolveInterval(details.id, periodIso);

      return SubscriptionPlanOffer(
        productId: details.id,
        basePlanId: subOffer?.basePlanId,
        offerId: subOffer?.offerId,
        offerToken: subOffer?.offerIdToken,
        interval: interval,
        title: details.title,
        description: details.description,
        formattedPrice: recurringPhase?.formattedPrice ?? details.price,
        priceAmountMicros:
            recurringPhase?.priceAmountMicros ??
            (details.rawPrice * 1000000).round(),
        currencyCode: recurringPhase?.priceCurrencyCode ?? details.currencyCode,
        billingPeriodIso: periodIso,
        freeTrialPeriodIso: freeTrialPhase?.billingPeriod,
        introductoryPriceFormatted: introPhase?.formattedPrice,
        introductoryPeriodIso: introPhase?.billingPeriod,
      );
    }

    final interval = details.id == _config.yearlyProductId
        ? BillingInterval.yearly
        : BillingInterval.monthly;
    return SubscriptionPlanOffer(
      productId: details.id,
      interval: interval,
      title: details.title,
      description: details.description,
      formattedPrice: details.price,
      priceAmountMicros: (details.rawPrice * 1000000).round(),
      currencyCode: details.currencyCode,
      billingPeriodIso: interval == BillingInterval.yearly ? 'P1Y' : 'P1M',
    );
  }

  SubscriptionOfferDetailsWrapper? _selectOfferDetails(
    GooglePlayProductDetails details,
  ) {
    final offers = details.productDetails.subscriptionOfferDetails;
    if (offers == null || offers.isEmpty) return null;
    final idx = details.subscriptionIndex;
    if (idx != null && idx >= 0 && idx < offers.length) {
      return offers[idx];
    }
    return offers.first;
  }

  BillingInterval _resolveInterval(String productId, String billingPeriodIso) {
    final upper = billingPeriodIso.toUpperCase();
    if (upper.contains('Y') || productId == _config.yearlyProductId) {
      return BillingInterval.yearly;
    }
    return BillingInterval.monthly;
  }

  StorePurchaseUpdate _mapPurchase(PurchaseDetails purchase) {
    final status = switch (purchase.status) {
      PurchaseStatus.pending => StorePurchaseStatus.pending,
      PurchaseStatus.purchased => StorePurchaseStatus.purchased,
      PurchaseStatus.restored => StorePurchaseStatus.restored,
      PurchaseStatus.canceled => StorePurchaseStatus.canceled,
      PurchaseStatus.error => StorePurchaseStatus.error,
    };
    return StorePurchaseUpdate(
      productId: purchase.productID,
      status: status,
      purchaseId: purchase.purchaseID,
      purchaseToken: purchase.verificationData.serverVerificationData,
      pendingCompletePurchase: purchase.pendingCompletePurchase,
      errorCode: purchase.error?.code,
      errorMessage: BillingPrivacy.sanitizeDiagnostic(purchase.error?.message),
      transactionDateMs: int.tryParse(purchase.transactionDate ?? ''),
    );
  }
}
