import 'dart:typed_data';

import 'package:deckos/core/core.dart';
import 'package:deckos/src/billing/billing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'billing_test_fixtures.dart';

Widget _wrapPage(
  Widget child, {
  double textScale = 1.0,
  EdgeInsets viewInsets = EdgeInsets.zero,
}) {
  return MaterialApp(
    theme: ThemeData.dark().copyWith(
      extensions: <ThemeExtension<dynamic>>[AppleColors.dark()],
    ),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(390, 844),
        textScaler: TextScaler.linear(textScale),
        viewInsets: viewInsets,
      ),
      child: child,
    ),
  );
}

void main() {
  final keyPair = TestEd25519KeyPair.fromSeed(
    Uint8List.fromList(List<int>.generate(32, (i) => i + 31)),
  );
  final baseNow = DateTime.utc(2026, 11, 24, 12, 0, 0);

  setUp(() {
    AppLanguage.choice.value = 'en';
  });

  tearDown(() {
    AppLanguage.choice.value = 'pt';
  });

  testWidgets(
    'unconfigured page shows honest unavailable state, zero fabricated prices/trials, and recurring/cancel terms',
    (tester) async {
      final launchedUris = <Uri>[];
      final ctrl = SubscriptionController(
        config: const BillingConfig.unconfigured(),
        storeGateway: UnconfiguredBillingStoreGateway(
          platform: BillingStorePlatform.androidGooglePlay,
        ),
        verificationClient: const UnconfiguredPurchaseVerificationClient(),
        cacheRepository: BillingCacheRepository(MemoryBillingStorage()),
        urlLauncher: (uri) async {
          launchedUris.add(uri);
          return true;
        },
      );
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(_wrapPage(SubscriptionPage(controller: ctrl)));
      await tester.pumpAndSettle();

      expect(find.text('Not available yet'), findsOneWidget);
      expect(find.text('Plans are not available yet'), findsOneWidget);
      expect(find.text('Subscriptions unavailable'), findsOneWidget);
      // Must never invent prices or fake free trial badges
      expect(find.textContaining(r'$'), findsNothing);
      expect(find.textContaining('free trial'), findsNothing);

      // Scroll to Manage & Terms and verify Google Play management deep link
      await tester.scrollUntilVisible(
        find.text('Manage or cancel in Google Play'),
        200,
      );
      await tester.ensureVisible(find.text('Manage or cancel in Google Play'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Manage or cancel in Google Play'));
      await tester.pump();
      expect(launchedUris, hasLength(1));
      expect(
        launchedUris.single.toString(),
        'https://play.google.com/store/account/subscriptions?package=io.github.itskavin.deckos',
      );

      await tester.scrollUntilVisible(
        find.textContaining('Published by Bytetrix'),
        200,
      );
      expect(find.textContaining('contact@kavin.sh'), findsOneWidget);
      expect(find.textContaining('renewed automatically'), findsOneWidget);
    },
  );

  testWidgets(
    'non-Android platform shows Android-only state and disables Play purchase',
    (tester) async {
      final ctrl = SubscriptionController(
        config: makeConfiguredTestBillingConfig(keyPair),
        storeGateway: FakeBillingStoreGateway(
          platform: BillingStorePlatform.web,
          offers: sampleFakePlayOffers(),
        ),
        verificationClient: const UnconfiguredPurchaseVerificationClient(),
        cacheRepository: BillingCacheRepository(MemoryBillingStorage()),
      );
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(_wrapPage(SubscriptionPage(controller: ctrl)));
      await tester.pumpAndSettle();

      expect(find.text('Android only'), findsOneWidget);
      expect(find.text('Subscriptions unavailable'), findsOneWidget);
      expect(find.text(r'$4.99 · per month'), findsNothing);
    },
  );

  testWidgets(
    'configured fake-Play catalog shows localized prices, no preselected dark pattern, computed savings, and verifies purchase',
    (tester) async {
      final gateway = FakeBillingStoreGateway(
        offers: sampleFakePlayOffers(includeTrial: true),
      );
      final verifier = FakePurchaseVerificationClient(
        verifyHandler:
            ({
              required packageName,
              required productId,
              required purchaseToken,
              required obfuscatedAccountId,
            }) async {
              final grant = SignedEntitlementGrant(
                version: 1,
                packageName: packageName,
                entitlementId: 'ent_ui_01',
                productId: productId,
                state: EntitlementState.active,
                issuedAt: baseNow,
                expiresAt: baseNow.add(const Duration(days: 30)),
                offlineValidUntil: baseNow.add(const Duration(hours: 72)),
                autoRenewing: true,
                acknowledged: true,
                obfuscatedAccountId: obfuscatedAccountId,
              );
              return VerificationResult(
                status: VerificationStatus.verified,
                envelope: keyPair.signGrant(grant),
              );
            },
      );

      final ctrl = SubscriptionController(
        config: makeConfiguredTestBillingConfig(keyPair),
        storeGateway: gateway,
        verificationClient: verifier,
        cacheRepository: BillingCacheRepository(MemoryBillingStorage()),
        clock: () => baseNow,
      );
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(_wrapPage(SubscriptionPage(controller: ctrl)));
      await tester.pumpAndSettle();

      expect(find.text(r'$4.99 · per month'), findsOneWidget);
      expect(find.text(r'$49.99 · per year'), findsOneWidget);
      expect(find.text('Save 16%'), findsOneWidget);
      expect(find.text('Includes 7 days free trial'), findsOneWidget);
      // Nothing preselected initially
      expect(find.text('Select a plan to continue'), findsOneWidget);

      await tester.tap(find.text('Monthly'));
      await tester.pumpAndSettle();
      expect(find.text('Subscribe via Google Play'), findsOneWidget);

      await tester.tap(find.text('Subscribe via Google Play'));
      await tester.pump();
      expect(gateway.launchedOffers, hasLength(1));

      gateway.emitPurchases(const <StorePurchaseUpdate>[
        StorePurchaseUpdate(
          productId: BillingConfig.recommendedMonthlyProductId,
          status: StorePurchaseStatus.purchased,
          purchaseToken: 'gkp_fake_ui_token_abcdefghijklmnopqrstuvwxyz1234',
          pendingCompletePurchase: true,
        ),
      ]);
      await ctrl.flushPendingEvents();
      await tester.pumpAndSettle();

      expect(find.text('Active'), findsOneWidget);
      expect(find.text('Subscription verified and active.'), findsOneWidget);
    },
  );

  testWidgets(
    'renders grace period, account hold, pending, and canceled-active states cleanly',
    (tester) async {
      final gateway = FakeBillingStoreGateway(offers: sampleFakePlayOffers());
      var nextState = EntitlementState.inGracePeriod;
      final verifier = FakePurchaseVerificationClient(
        verifyHandler:
            ({
              required packageName,
              required productId,
              required purchaseToken,
              required obfuscatedAccountId,
            }) async {
              final grant = SignedEntitlementGrant(
                version: 1,
                packageName: packageName,
                entitlementId: 'ent_ui_state',
                productId: productId,
                state: nextState,
                issuedAt: baseNow,
                expiresAt: baseNow.add(const Duration(days: 20)),
                offlineValidUntil: baseNow.add(const Duration(hours: 72)),
                autoRenewing: nextState != EntitlementState.canceledActive,
                acknowledged: true,
                obfuscatedAccountId: obfuscatedAccountId,
              );
              return VerificationResult(
                status: VerificationStatus.verified,
                envelope: keyPair.signGrant(grant),
              );
            },
        refreshHandler:
            ({
              required packageName,
              required entitlementId,
              required obfuscatedAccountId,
            }) async {
              final grant = SignedEntitlementGrant(
                version: 1,
                packageName: packageName,
                entitlementId: entitlementId,
                productId: BillingConfig.recommendedMonthlyProductId,
                state: nextState,
                issuedAt: baseNow,
                expiresAt: baseNow.add(const Duration(days: 20)),
                offlineValidUntil: baseNow.add(const Duration(hours: 72)),
                autoRenewing: nextState != EntitlementState.canceledActive,
                acknowledged: true,
                obfuscatedAccountId: obfuscatedAccountId,
              );
              return VerificationResult(
                status: VerificationStatus.verified,
                envelope: keyPair.signGrant(grant),
              );
            },
      );

      final ctrl = SubscriptionController(
        config: makeConfiguredTestBillingConfig(keyPair),
        storeGateway: gateway,
        verificationClient: verifier,
        cacheRepository: BillingCacheRepository(MemoryBillingStorage()),
        clock: () => baseNow,
      );
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(_wrapPage(SubscriptionPage(controller: ctrl)));
      await tester.pumpAndSettle();

      // Pending
      gateway.emitPurchases(const <StorePurchaseUpdate>[
        StorePurchaseUpdate(
          productId: BillingConfig.recommendedMonthlyProductId,
          status: StorePurchaseStatus.pending,
        ),
      ]);
      await ctrl.flushPendingEvents();
      await tester.pumpAndSettle();
      expect(find.text('Payment pending'), findsOneWidget);

      // Grace period
      gateway.emitPurchases(const <StorePurchaseUpdate>[
        StorePurchaseUpdate(
          productId: BillingConfig.recommendedMonthlyProductId,
          status: StorePurchaseStatus.purchased,
          purchaseToken: 'gkp_fake_ui_grace_token_1234567890abcdef',
        ),
      ]);
      await ctrl.flushPendingEvents();
      await tester.pumpAndSettle();
      expect(find.text('Payment issue (grace period)'), findsOneWidget);

      // Account hold
      nextState = EntitlementState.onHold;
      await ctrl.refreshEntitlement();
      await tester.pumpAndSettle();
      expect(find.text('Account hold'), findsOneWidget);

      // Canceled but active until expiry
      nextState = EntitlementState.canceledActive;
      await ctrl.refreshEntitlement();
      await tester.pumpAndSettle();
      expect(find.textContaining('Canceled · active until'), findsOneWidget);
    },
  );

  testWidgets(
    'handles 2.0x large accessibility font scale and landscape keyboard constraints without overflow',
    (tester) async {
      final gateway = FakeBillingStoreGateway(offers: sampleFakePlayOffers());
      final ctrl = SubscriptionController(
        config: makeConfiguredTestBillingConfig(keyPair),
        storeGateway: gateway,
        verificationClient: const UnconfiguredPurchaseVerificationClient(),
        cacheRepository: BillingCacheRepository(MemoryBillingStorage()),
        clock: () => baseNow,
      );
      addTearDown(ctrl.dispose);

      // Narrow portrait + 2.0x text scaling
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        _wrapPage(SubscriptionPage(controller: ctrl), textScale: 2.0),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Landscape + simulated soft keyboard height
      tester.view.physicalSize = const Size(720, 360);
      await tester.pumpWidget(
        _wrapPage(
          SubscriptionPage(controller: ctrl),
          textScale: 1.5,
          viewInsets: const EdgeInsets.only(bottom: 180),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
