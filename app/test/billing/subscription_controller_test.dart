import 'dart:convert';
import 'dart:typed_data';

import 'package:deckos/src/billing/billing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'billing_test_fixtures.dart';

void main() {
  final keyPair = TestEd25519KeyPair.fromSeed(
    Uint8List.fromList(List<int>.generate(32, (i) => i + 11)),
  );
  final baseNow = DateTime.utc(2026, 11, 24, 12, 0, 0);
  const sensitiveToken =
      'gkp_sensitive_fake_purchase_token_9f8a7b6c5d4e3f2a1b0c9d8e7f6a';

  SignedEntitlementEnvelope makeSignedEnvelope({
    required EntitlementState state,
    required String accountId,
    DateTime? now,
    DateTime? expiresAt,
    DateTime? offlineValidUntil,
    bool autoRenewing = true,
    bool acknowledged = true,
    String packageName = BillingConfig.defaultPackageName,
    String keyId = 'test-k1',
    TestEd25519KeyPair? signer,
  }) {
    final t = now ?? baseNow;
    final grant = SignedEntitlementGrant(
      version: SignedEntitlementGrant.currentVersion,
      packageName: packageName,
      entitlementId: 'ent_fake_001',
      productId: BillingConfig.recommendedMonthlyProductId,
      state: state,
      issuedAt: t,
      expiresAt: expiresAt ?? t.add(const Duration(days: 30)),
      offlineValidUntil: offlineValidUntil ?? t.add(const Duration(hours: 72)),
      autoRenewing: autoRenewing,
      acknowledged: acknowledged,
      obfuscatedAccountId: accountId,
    );
    return (signer ?? keyPair).signGrant(grant, keyId: keyId);
  }

  group('SubscriptionController lifecycle, security & privacy', () {
    test(
      'signed cache rejects wrong installation and overlong offline grants',
      () async {
        for (final badAccount in [true, false]) {
          final storage = MemoryBillingStorage();
          final cache = BillingCacheRepository(storage);
          final accountId = await cache.getOrCreateObfuscatedAccountId();
          await cache.saveEnvelope(
            makeSignedEnvelope(
              state: EntitlementState.active,
              accountId: badAccount
                  ? 'dos_different_installation_0123456789'
                  : accountId,
              offlineValidUntil: badAccount
                  ? null
                  : baseNow.add(const Duration(days: 8)),
            ),
          );
          final controller = SubscriptionController(
            config: makeConfiguredTestBillingConfig(keyPair),
            storeGateway: FakeBillingStoreGateway(
              offers: sampleFakePlayOffers(),
            ),
            verificationClient: const UnconfiguredPurchaseVerificationClient(),
            cacheRepository: cache,
            clock: () => baseNow,
          );
          await controller.initialize();
          expect(controller.isProEntitled, false);
          expect(controller.snapshot.activeGrant, null);
          expect(await cache.readEnvelope(), null);
          controller.dispose();
        }
      },
    );

    test(
      'unconfigured state honestly disables purchases and never claims Pro',
      () async {
        final storage = MemoryBillingStorage();
        final ctrl = SubscriptionController.unconfigured(
          platform: BillingStorePlatform.androidGooglePlay,
          storage: storage,
        );
        addTearDown(ctrl.dispose);

        await ctrl.initialize();
        expect(ctrl.snapshot.isConfigured, isFalse);
        expect(ctrl.snapshot.entitlementState, EntitlementState.unconfigured);
        expect(ctrl.isProEntitled, isFalse);
        expect(ctrl.snapshot.canSubscribe, isFalse);
        expect(ctrl.snapshot.offers, isEmpty);
      },
    );

    test('non-Android platforms disable Play Billing gracefully', () async {
      for (final platform in <BillingStorePlatform>[
        BillingStorePlatform.web,
        BillingStorePlatform.ios,
        BillingStorePlatform.desktop,
      ]) {
        final gateway = FakeBillingStoreGateway(
          platform: platform,
          offers: sampleFakePlayOffers(),
        );
        final ctrl = SubscriptionController(
          config: makeConfiguredTestBillingConfig(keyPair),
          storeGateway: gateway,
          verificationClient: const UnconfiguredPurchaseVerificationClient(),
          cacheRepository: BillingCacheRepository(MemoryBillingStorage()),
        );
        await ctrl.initialize();
        expect(
          ctrl.snapshot.entitlementState,
          EntitlementState.unsupportedPlatform,
        );
        expect(ctrl.snapshot.canSubscribe, isFalse);
        expect(ctrl.isProEntitled, isFalse);
        await ctrl.purchaseSelectedPlan();
        expect(gateway.launchedOffers, isEmpty);
        ctrl.dispose();
      }
    });

    test(
      'store unavailable and missing SKU states report honestly without inventing prices',
      () async {
        final unavailableGateway = FakeBillingStoreGateway(
          storeAvailable: false,
        );
        final ctrl1 = SubscriptionController(
          config: makeConfiguredTestBillingConfig(keyPair),
          storeGateway: unavailableGateway,
          verificationClient: const UnconfiguredPurchaseVerificationClient(),
          cacheRepository: BillingCacheRepository(MemoryBillingStorage()),
        );
        await ctrl1.initialize();
        expect(ctrl1.snapshot.storeAvailable, isFalse);
        expect(
          ctrl1.snapshot.feedback.code,
          BillingFeedbackCode.storeUnavailable,
        );
        expect(ctrl1.snapshot.offers, isEmpty);
        ctrl1.dispose();

        final missingSkuGateway = FakeBillingStoreGateway(
          storeAvailable: true,
          offers: const <SubscriptionPlanOffer>[],
          notFoundIds: const <String>{
            BillingConfig.recommendedMonthlyProductId,
            BillingConfig.recommendedYearlyProductId,
          },
        );
        final ctrl2 = SubscriptionController(
          config: makeConfiguredTestBillingConfig(keyPair),
          storeGateway: missingSkuGateway,
          verificationClient: const UnconfiguredPurchaseVerificationClient(),
          cacheRepository: BillingCacheRepository(MemoryBillingStorage()),
        );
        await ctrl2.initialize();
        expect(ctrl2.snapshot.offers, isEmpty);
        expect(
          ctrl2.snapshot.feedback.code,
          BillingFeedbackCode.missingProducts,
        );
        expect(ctrl2.snapshot.canSubscribe, isFalse);
        ctrl2.dispose();
      },
    );

    test(
      'serialized & idempotent purchase stream verifies once, never completes early, and redacts purchaseToken',
      () async {
        final logs = <String>[];
        final storage = MemoryBillingStorage();
        final gateway = FakeBillingStoreGateway(offers: sampleFakePlayOffers());
        final verifier = FakePurchaseVerificationClient(
          verifyHandler:
              ({
                required packageName,
                required productId,
                required purchaseToken,
                required obfuscatedAccountId,
              }) async {
                // Verify completePurchase has NOT been called yet while verifying!
                expect(gateway.completedPurchases, isEmpty);
                return VerificationResult(
                  status: VerificationStatus.verified,
                  envelope: makeSignedEnvelope(
                    state: EntitlementState.active,
                    accountId: obfuscatedAccountId,
                  ),
                );
              },
        );

        final ctrl = SubscriptionController(
          config: makeConfiguredTestBillingConfig(keyPair),
          storeGateway: gateway,
          verificationClient: verifier,
          cacheRepository: BillingCacheRepository(storage),
          clock: () => baseNow,
          logSink: logs.add,
        );
        addTearDown(ctrl.dispose);

        await ctrl.initialize();
        // Nothing preselected by default
        expect(ctrl.snapshot.selectedOffer, isNull);
        expect(ctrl.snapshot.canSubscribe, isFalse);

        ctrl.selectOffer(ctrl.snapshot.offers.first);
        expect(ctrl.snapshot.canSubscribe, isTrue);
        await ctrl.purchaseSelectedPlan();
        expect(gateway.launchedOffers, hasLength(1));

        // Emit duplicate burst of the exact same purchase update
        const update = StorePurchaseUpdate(
          productId: BillingConfig.recommendedMonthlyProductId,
          status: StorePurchaseStatus.purchased,
          purchaseId: 'GPA.0000-0000-0000-00001',
          purchaseToken: sensitiveToken,
          pendingCompletePurchase: true,
        );
        gateway.emitPurchases(const <StorePurchaseUpdate>[update, update]);
        gateway.emitPurchases(const <StorePurchaseUpdate>[update]);
        await ctrl.flushPendingEvents();

        expect(verifier.verifyCalls, 1);
        expect(gateway.completedPurchases, hasLength(1));
        expect(ctrl.isProEntitled, isTrue);
        expect(ctrl.snapshot.entitlementState, EntitlementState.active);
        expect(
          ctrl.snapshot.feedback.code,
          BillingFeedbackCode.purchaseVerified,
        );

        // Privacy check: raw purchaseToken NEVER appears in logs or toString
        expect(logs.join('\n'), isNot(contains(sensitiveToken)));
        expect(update.toString(), isNot(contains(sensitiveToken)));
      },
    );

    test(
      'never completes purchase or grants Pro when backend rejects, is offline, returns invalid signature, or unacknowledged',
      () async {
        final wrongKey = TestEd25519KeyPair.fromSeed(Uint8List(32)..[0] = 99);
        final scenarios =
            <
              ({
                String name,
                VerificationResult Function(String accountId) resultBuilder,
                BillingFeedbackCode expectedFeedback,
              })
            >[
              (
                name: 'backend offline',
                resultBuilder: (_) => const VerificationResult(
                  status: VerificationStatus.offline,
                ),
                expectedFeedback: BillingFeedbackCode.offline,
              ),
              (
                name: 'backend rejected',
                resultBuilder: (_) => const VerificationResult(
                  status: VerificationStatus.rejected,
                ),
                expectedFeedback: BillingFeedbackCode.verificationFailed,
              ),
              (
                name: 'forged signature from wrong key',
                resultBuilder: (aid) => VerificationResult(
                  status: VerificationStatus.verified,
                  envelope: makeSignedEnvelope(
                    state: EntitlementState.active,
                    accountId: aid,
                    signer: wrongKey,
                  ),
                ),
                expectedFeedback: BillingFeedbackCode.invalidSignature,
              ),
              (
                name: 'unacknowledged grant',
                resultBuilder: (aid) => VerificationResult(
                  status: VerificationStatus.verified,
                  envelope: makeSignedEnvelope(
                    state: EntitlementState.active,
                    accountId: aid,
                    acknowledged: false,
                  ),
                ),
                expectedFeedback: BillingFeedbackCode.none,
              ),
            ];

        for (final scenario in scenarios) {
          final gateway = FakeBillingStoreGateway(
            offers: sampleFakePlayOffers(),
          );
          final verifier = FakePurchaseVerificationClient(
            verifyHandler:
                ({
                  required packageName,
                  required productId,
                  required purchaseToken,
                  required obfuscatedAccountId,
                }) async => scenario.resultBuilder(obfuscatedAccountId),
          );
          final ctrl = SubscriptionController(
            config: makeConfiguredTestBillingConfig(keyPair),
            storeGateway: gateway,
            verificationClient: verifier,
            cacheRepository: BillingCacheRepository(MemoryBillingStorage()),
            clock: () => baseNow,
          );
          await ctrl.initialize();
          gateway.emitPurchases(const <StorePurchaseUpdate>[
            StorePurchaseUpdate(
              productId: BillingConfig.recommendedMonthlyProductId,
              status: StorePurchaseStatus.purchased,
              purchaseToken: sensitiveToken,
              pendingCompletePurchase: true,
            ),
          ]);
          await ctrl.flushPendingEvents();

          expect(ctrl.isProEntitled, isFalse, reason: scenario.name);
          expect(gateway.completedPurchases, isEmpty, reason: scenario.name);
          expect(
            ctrl.snapshot.feedback.code,
            scenario.expectedFeedback,
            reason: scenario.name,
          );
          ctrl.dispose();
        }
      },
    );

    test(
      'handles pending, canceled, alreadyOwned, grace, onHold, paused, canceledActive, expired, revoked, and restore',
      () async {
        final gateway = FakeBillingStoreGateway(offers: sampleFakePlayOffers());
        var nextState = EntitlementState.inGracePeriod;
        var nextAutoRenew = true;
        DateTime now = baseNow;

        final verifier = FakePurchaseVerificationClient(
          verifyHandler:
              ({
                required packageName,
                required productId,
                required purchaseToken,
                required obfuscatedAccountId,
              }) async {
                return VerificationResult(
                  status: VerificationStatus.verified,
                  envelope: makeSignedEnvelope(
                    state: nextState,
                    accountId: obfuscatedAccountId,
                    now: now,
                    autoRenewing: nextAutoRenew,
                  ),
                );
              },
          refreshHandler:
              ({
                required packageName,
                required entitlementId,
                required obfuscatedAccountId,
              }) async {
                return VerificationResult(
                  status: VerificationStatus.verified,
                  envelope: makeSignedEnvelope(
                    state: nextState,
                    accountId: obfuscatedAccountId,
                    now: now,
                    autoRenewing: nextAutoRenew,
                  ),
                );
              },
        );

        final ctrl = SubscriptionController(
          config: makeConfiguredTestBillingConfig(keyPair),
          storeGateway: gateway,
          verificationClient: verifier,
          cacheRepository: BillingCacheRepository(MemoryBillingStorage()),
          clock: () => now,
        );
        addTearDown(ctrl.dispose);
        await ctrl.initialize();

        // Pending payment: NOT entitled, NOT completed
        gateway.emitPurchases(const <StorePurchaseUpdate>[
          StorePurchaseUpdate(
            productId: BillingConfig.recommendedMonthlyProductId,
            status: StorePurchaseStatus.pending,
            pendingCompletePurchase: true,
          ),
        ]);
        await ctrl.flushPendingEvents();
        expect(ctrl.snapshot.entitlementState, EntitlementState.pending);
        expect(ctrl.isProEntitled, isFalse);
        expect(gateway.completedPurchases, isEmpty);

        // User canceled
        gateway.emitPurchases(const <StorePurchaseUpdate>[
          StorePurchaseUpdate(
            productId: BillingConfig.recommendedMonthlyProductId,
            status: StorePurchaseStatus.canceled,
          ),
        ]);
        await ctrl.flushPendingEvents();
        expect(ctrl.snapshot.feedback.code, BillingFeedbackCode.userCanceled);

        // Already owned error
        gateway.emitPurchases(const <StorePurchaseUpdate>[
          StorePurchaseUpdate(
            productId: BillingConfig.recommendedMonthlyProductId,
            status: StorePurchaseStatus.error,
            errorCode: 'billing_item_already_owned',
          ),
        ]);
        await ctrl.flushPendingEvents();
        expect(ctrl.snapshot.feedback.code, BillingFeedbackCode.alreadyOwned);

        // Restore finds nothing initially
        await ctrl.restorePurchases();
        expect(ctrl.snapshot.feedback.code, BillingFeedbackCode.restoreEmpty);

        // Restore finds subscription in grace period -> temporarily entitled
        nextState = EntitlementState.inGracePeriod;
        gateway.restoreUpdatesToEmit = const <StorePurchaseUpdate>[
          StorePurchaseUpdate(
            productId: BillingConfig.recommendedMonthlyProductId,
            status: StorePurchaseStatus.restored,
            purchaseToken: sensitiveToken,
            pendingCompletePurchase: false,
          ),
        ];
        await ctrl.restorePurchases();
        expect(ctrl.snapshot.entitlementState, EntitlementState.inGracePeriod);
        expect(ctrl.isProEntitled, isTrue);
        expect(
          ctrl.snapshot.feedback.code,
          BillingFeedbackCode.restoreSucceeded,
        );

        // Account hold on resume -> Pro suspended
        nextState = EntitlementState.onHold;
        await ctrl.onAppResumed();
        expect(ctrl.snapshot.entitlementState, EntitlementState.onHold);
        expect(ctrl.isProEntitled, isFalse);

        // Paused -> Pro suspended
        nextState = EntitlementState.paused;
        await ctrl.refreshEntitlement();
        expect(ctrl.snapshot.entitlementState, EntitlementState.paused);
        expect(ctrl.isProEntitled, isFalse);

        // Canceled but still within paid period -> active until expiry
        nextState = EntitlementState.canceledActive;
        nextAutoRenew = false;
        await ctrl.refreshEntitlement();
        expect(ctrl.snapshot.entitlementState, EntitlementState.canceledActive);
        expect(ctrl.isProEntitled, isTrue);

        // Revoked / refunded -> immediately revoked
        nextState = EntitlementState.revoked;
        await ctrl.refreshEntitlement();
        expect(ctrl.snapshot.entitlementState, EntitlementState.revoked);
        expect(ctrl.isProEntitled, isFalse);
      },
    );

    test(
      'bounded offline cache works within 72h, expires past window, and rejects tampered storage',
      () async {
        final storage = MemoryBillingStorage();
        final repo = BillingCacheRepository(storage);
        final accountId = await repo.getOrCreateObfuscatedAccountId();

        // Seed valid signed grant into encrypted storage
        final signed = makeSignedEnvelope(
          state: EntitlementState.active,
          accountId: accountId,
          now: baseNow,
          expiresAt: baseNow.add(const Duration(days: 30)),
          offlineValidUntil: baseNow.add(const Duration(hours: 72)),
        );
        await repo.saveEnvelope(signed);

        var now = baseNow.add(const Duration(hours: 12));
        final ctrl = SubscriptionController(
          config: makeConfiguredTestBillingConfig(keyPair),
          storeGateway: FakeBillingStoreGateway(offers: sampleFakePlayOffers()),
          verificationClient: FakePurchaseVerificationClient(
            verifyHandler:
                ({
                  required packageName,
                  required productId,
                  required purchaseToken,
                  required obfuscatedAccountId,
                }) async => const VerificationResult(
                  status: VerificationStatus.offline,
                ),
            refreshHandler:
                ({
                  required packageName,
                  required entitlementId,
                  required obfuscatedAccountId,
                }) async => const VerificationResult(
                  status: VerificationStatus.offline,
                ),
          ),
          cacheRepository: repo,
          clock: () => now,
        );

        await ctrl.initialize();
        // Within 72h offline grace window -> still entitled offline
        expect(ctrl.isProEntitled, isTrue);
        expect(ctrl.snapshot.usingOfflineCache, isTrue);

        // Advance past 72h offline window -> access revoked until online refresh!
        now = baseNow.add(const Duration(hours: 73));
        await ctrl.onAppResumed();
        expect(ctrl.isProEntitled, isFalse);
        expect(
          ctrl.snapshot.feedback.code,
          BillingFeedbackCode.offlineCacheExpired,
        );
        ctrl.dispose();

        // Tamper cached envelope payload in storage -> rejected on reload!
        final tamperedMap = Map<String, dynamic>.from(signed.toJson());
        final forgedGrant = SignedEntitlementGrant(
          version: 1,
          packageName: BillingConfig.defaultPackageName,
          entitlementId: 'ent_forged',
          productId: BillingConfig.recommendedYearlyProductId,
          state: EntitlementState.active,
          issuedAt: baseNow,
          expiresAt: baseNow.add(const Duration(days: 3650)),
          offlineValidUntil: baseNow.add(const Duration(days: 3650)),
          autoRenewing: true,
          acknowledged: true,
          obfuscatedAccountId: accountId,
        );
        tamperedMap['payload'] = base64Url
            .encode(utf8.encode(jsonEncode(forgedGrant.toJson())))
            .replaceAll('=', '');
        await storage.write(
          'deckos_billing_signed_entitlement_v1',
          jsonEncode(tamperedMap),
        );

        final ctrl2 = SubscriptionController(
          config: makeConfiguredTestBillingConfig(keyPair),
          storeGateway: FakeBillingStoreGateway(offers: sampleFakePlayOffers()),
          verificationClient: const UnconfiguredPurchaseVerificationClient(),
          cacheRepository: repo,
          clock: () => baseNow.add(const Duration(hours: 1)),
        );
        await ctrl2.initialize();
        expect(ctrl2.isProEntitled, isFalse);
        expect(
          ctrl2.snapshot.feedback.code,
          BillingFeedbackCode.invalidSignature,
        );
        ctrl2.dispose();
      },
    );

    test(
      'HttpPurchaseVerificationClient sends purchaseToken only in HTTPS POST body and verifies Ed25519',
      () async {
        Uri? capturedUri;
        String? capturedMethod;
        Map<String, dynamic>? capturedBody;

        final mockHttp = MockClient((request) async {
          capturedUri = request.url;
          capturedMethod = request.method;
          capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
          final envelope = makeSignedEnvelope(
            state: EntitlementState.active,
            accountId: capturedBody!['obfuscatedAccountId'] as String,
          );
          return http.Response(
            jsonEncode(<String, Object?>{'entitlement': envelope.toJson()}),
            200,
            headers: const <String, String>{'content-type': 'application/json'},
          );
        });

        final client = HttpPurchaseVerificationClient(
          config: makeConfiguredTestBillingConfig(keyPair),
          httpClient: mockHttp,
        );
        final res = await client.verifyPurchase(
          packageName: BillingConfig.defaultPackageName,
          productId: BillingConfig.recommendedMonthlyProductId,
          purchaseToken: sensitiveToken,
          obfuscatedAccountId: 'dos_0123456789abcdef0123456789abcdef',
        );

        expect(res.isVerified, isTrue);
        expect(capturedMethod, 'POST');
        expect(capturedUri!.scheme, 'https');
        expect(capturedUri!.hasQuery, isFalse);
        expect(capturedUri.toString(), isNot(contains(sensitiveToken)));
        expect(capturedBody!['purchaseToken'], sensitiveToken);
      },
    );
  });
}
