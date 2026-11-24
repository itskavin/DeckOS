import 'dart:convert';
import 'dart:typed_data';

import 'package:deckos/src/billing/billing.dart';
import 'package:flutter_test/flutter_test.dart';

import 'billing_test_fixtures.dart';

Uint8List _hex(String s) {
  final clean = s.replaceAll(RegExp(r'\s+'), '');
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

void main() {
  group('Ed25519Verifier (RFC 8032 & Node.js cross-language parity)', () {
    test(
      'verifies RFC 8032 Section 7.1 Test Vector 1 (empty message)',
      () async {
        final pub = _hex(
          'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
        );
        final sig = _hex(
          'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e06522490155'
          '5fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
        );
        expect(
          await Ed25519Verifier.verify(
            message: Uint8List(0),
            signature: sig,
            publicKey: pub,
          ),
          isTrue,
        );
        // Flip one bit in signature -> must reject
        final badSig = Uint8List.fromList(sig)..[0] ^= 0x01;
        expect(
          await Ed25519Verifier.verify(
            message: Uint8List(0),
            signature: badSig,
            publicKey: pub,
          ),
          isFalse,
        );
      },
    );

    test(
      'verifies RFC 8032 Section 7.1 Test Vector 2 (1-byte message 0x72)',
      () async {
        final pub = _hex(
          '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c',
        );
        final sig = _hex(
          '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da'
          '085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00',
        );
        expect(
          await Ed25519Verifier.verify(
            message: Uint8List.fromList(<int>[0x72]),
            signature: sig,
            publicKey: pub,
          ),
          isTrue,
        );
        expect(
          await Ed25519Verifier.verify(
            message: Uint8List.fromList(<int>[0x73]),
            signature: sig,
            publicKey: pub,
          ),
          isFalse,
        );
      },
    );

    test(
      'verifies real entitlement envelope signed by Node.js billing-verifier',
      () async {
        const nodePubKey = 'tBgE4J2c9AJAcuk2F6hrNot5dmnFEbtXa5zHEFl-RRU';
        const envelopeJson = <String, dynamic>{
          'kid': 'k1',
          'payload':
              'eyJ2IjoxLCJwa2ciOiJpby5naXRodWIuaXRza2F2aW4uZGVja29zIiwiZWlkIjoiZW50X2ZpeHR1cmVfMDAxIiwicGlkIjoiZGVja29zX3Byb19tb250aGx5Iiwic3RhdGUiOiJhY3RpdmUiLCJpYXQiOjE3OTU1MjE2MDAwMDAsImV4cCI6MTc5ODExMzYwMDAwMCwib3Z1IjoxNzk1NzgwODAwMDAwLCJhciI6dHJ1ZSwiYWNrIjp0cnVlLCJhaWQiOiJkb3NfMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWYifQ',
          'sig':
              'ZNPYh70AeyEbhpMfc26N2DcQNA8dHpyZE1YfBHgJHAHrsBG8IXi4IiAosdZvdcl7FY1MBgCYKzCzohzQdqA0Dg',
        };

        final envelope = SignedEntitlementEnvelope.tryParseJson(envelopeJson);
        expect(envelope, isNotNull);
        expect(
          await HttpPurchaseVerificationClient.verifyEnvelopeSignature(
            envelope!,
            publicKeys: const <String, String>{'k1': nodePubKey},
            expectedPackageName: BillingConfig.defaultPackageName,
          ),
          isTrue,
        );
        // Wrong package name must be rejected
        expect(
          await HttpPurchaseVerificationClient.verifyEnvelopeSignature(
            envelope,
            publicKeys: const <String, String>{'k1': nodePubKey},
            expectedPackageName: 'com.other.app',
          ),
          isFalse,
        );
        // Unknown keyId must be rejected
        expect(
          await HttpPurchaseVerificationClient.verifyEnvelopeSignature(
            envelope,
            publicKeys: const <String, String>{'k2': nodePubKey},
            expectedPackageName: BillingConfig.defaultPackageName,
          ),
          isFalse,
        );
      },
    );

    test('rejects non-canonical S >= L and malformed key lengths', () async {
      final kp = TestEd25519KeyPair.fromSeed(Uint8List(32)..[0] = 7);
      final sig = kp.sign(Uint8List.fromList(utf8.encode('hello')));
      expect(
        await Ed25519Verifier.verify(
          message: Uint8List.fromList(utf8.encode('hello')),
          signature: sig,
          publicKey: kp.publicKey,
        ),
        isTrue,
      );
      // Set S bytes all to 0xFF (guaranteed >= L)
      final badS = Uint8List.fromList(sig);
      for (var i = 32; i < 64; i++) {
        badS[i] = 0xff;
      }
      expect(
        await Ed25519Verifier.verify(
          message: Uint8List.fromList(utf8.encode('hello')),
          signature: badS,
          publicKey: kp.publicKey,
        ),
        isFalse,
      );
      expect(
        await Ed25519Verifier.verify(
          message: Uint8List.fromList(utf8.encode('hello')),
          signature: Uint8List(63),
          publicKey: kp.publicKey,
        ),
        isFalse,
      );
    });
  });

  group('BillingConfig, Pricing Calculation & FeatureEntitlementPolicy', () {
    test(
      'verification endpoint rejects HTTP, localhost, LAN IPs, and .local',
      () async {
        expect(
          BillingConfig.isValidVerificationEndpoint(
            Uri.parse('https://billing.bytetrix.example'),
          ),
          isTrue,
        );
        for (final bad in <String>[
          'http://billing.bytetrix.example',
          'https://localhost:4788',
          'https://127.0.0.1:4788',
          'https://192.168.1.50:4788',
          'https://10.0.0.2:4788',
          'https://172.16.0.5:4788',
          'https://mypc.local:4788',
        ]) {
          expect(
            BillingConfig.isValidVerificationEndpoint(Uri.parse(bad)),
            isFalse,
            reason:
                'Expected $bad to be rejected as a trusted billing authority',
          );
        }
      },
    );

    test(
      'manageSubscriptionsUri targets official Google Play package & SKU',
      () async {
        const cfg = BillingConfig.unconfigured();
        expect(
          cfg.manageSubscriptionsUri().toString(),
          'https://play.google.com/store/account/subscriptions?package=io.github.itskavin.deckos',
        );
        final withSku = cfg.manageSubscriptionsUri(
          activeProductId: 'deckos_pro_monthly',
        );
        expect(withSku.host, 'play.google.com');
        expect(withSku.path, '/store/account/subscriptions');
        expect(withSku.queryParameters['package'], 'io.github.itskavin.deckos');
        expect(withSku.queryParameters['sku'], 'deckos_pro_monthly');
      },
    );

    test(
      'annual savings computed ONLY from real same-currency Play prices',
      () async {
        final offers = sampleFakePlayOffers();
        // 4.99 * 12 = 59.88; 49.99 saves 16%
        expect(
          SubscriptionPlanOffer.computeAnnualSavingsPercent(
            monthly: offers[0],
            yearly: offers[1],
          ),
          16,
        );
        // Different currency -> must not fabricate savings
        const eurYearly = SubscriptionPlanOffer(
          productId: 'deckos_pro_yearly',
          interval: BillingInterval.yearly,
          title: 'Yearly',
          description: '',
          formattedPrice: '€49.99',
          priceAmountMicros: 49990000,
          currencyCode: 'EUR',
          billingPeriodIso: 'P1Y',
        );
        expect(
          SubscriptionPlanOffer.computeAnnualSavingsPercent(
            monthly: offers[0],
            yearly: eurYearly,
          ),
          isNull,
        );
        // More expensive yearly -> no negative/fake savings
        const pricierYearly = SubscriptionPlanOffer(
          productId: 'deckos_pro_yearly',
          interval: BillingInterval.yearly,
          title: 'Yearly',
          description: '',
          formattedPrice: r'$65.00',
          priceAmountMicros: 65000000,
          currencyCode: 'USD',
          billingPeriodIso: 'P1Y',
        );
        expect(
          SubscriptionPlanOffer.computeAnnualSavingsPercent(
            monthly: offers[0],
            yearly: pricierYearly,
          ),
          isNull,
        );
        expect(
          SubscriptionPlanOffer.computeAnnualSavingsPercent(
            monthly: offers[0],
            yearly: null,
          ),
          isNull,
        );
      },
    );

    test(
      'FeatureEntitlementPolicy never gates security/privacy and preserves existing features until gates approved',
      () async {
        // Default policy (no enforced gates yet) keeps candidate features working
        const defaultPolicy = FeatureEntitlementPolicy();
        expect(
          defaultPolicy
              .evaluate(
                BillingFeature.aiLimitsOverview,
                hasVerifiedProEntitlement: false,
              )
              .allowed,
          isTrue,
        );
        expect(
          defaultPolicy
              .evaluate(
                BillingFeature.aiLimitsOverview,
                hasVerifiedProEntitlement: false,
              )
              .reason,
          FeatureAccessReason.gateNotEnabled,
        );

        // Even if all features are mistakenly passed into enforcedGates,
        // security, privacy, name-masking, disconnect, data-deletion remain FREE!
        final strictPolicy = FeatureEntitlementPolicy(
          enforcedGates: BillingFeature.values.toSet(),
        );
        for (final alwaysFree in FeatureEntitlementPolicy.neverGateable) {
          final d = strictPolicy.evaluate(
            alwaysFree,
            hasVerifiedProEntitlement: false,
          );
          expect(d.allowed, isTrue, reason: '$alwaysFree must never be gated');
          expect(d.reason, FeatureAccessReason.alwaysFree);
        }

        // Candidate Pro features respect verified entitlement when gated
        final denied = strictPolicy.evaluate(
          BillingFeature.aiLimitsOverview,
          hasVerifiedProEntitlement: false,
        );
        expect(denied.allowed, isFalse);
        expect(denied.reason, FeatureAccessReason.requiresProSubscription);

        final allowed = strictPolicy.evaluate(
          BillingFeature.aiLimitsOverview,
          hasVerifiedProEntitlement: true,
        );
        expect(allowed.allowed, isTrue);
        expect(allowed.reason, FeatureAccessReason.proEntitled);
      },
    );
  });
}
