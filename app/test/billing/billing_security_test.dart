import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:deckos/src/billing/billing.dart';
import 'package:deckos/src/billing/billing_http_client_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'billing_test_fixtures.dart';

void main() {
  test(
    'rejects all small-order encodings, noncanonical points and malformed base64',
    () async {
      for (final hex in [
        '0000000000000000000000000000000000000000000000000000000000000000',
        '0100000000000000000000000000000000000000000000000000000000000000',
        'ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
        '26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05',
        'c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a',
        'edffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
      ]) {
        final key = Uint8List.fromList([
          for (var i = 0; i < 64; i += 2)
            int.parse(hex.substring(i, i + 2), radix: 16),
        ]);
        for (final sign in [0, 128]) {
          final signed = Uint8List.fromList(key)..[31] |= sign;
          final sig = Uint8List(64)..[0] = 1;
          expect(
            await Ed25519Verifier.verify(
              message: Uint8List(0),
              signature: sig,
              publicKey: signed,
            ),
            false,
          );
        }
      }
      expect(
        await Ed25519Verifier.verifyBase64(
          payload: 'hello',
          signatureBase64: '!broken!',
          publicKeyBase64: '!broken!',
        ),
        false,
      );
    },
  );

  test(
    'verification endpoint rejects credentials, redirect hints, numeric and private hosts',
    () {
      for (final url in [
        'https://user:secret@billing.example',
        'https://billing.example?token=x',
        'https://billing.example#fragment',
        'https://billing.example:4788',
        'https://[::1]',
        'https://[::ffff:127.0.0.1]',
        'https://2130706433',
        'https://127.1',
        'https://metadata.internal',
        'https://device.lan',
      ]) {
        expect(
          BillingConfig.isValidVerificationEndpoint(Uri.parse(url)),
          false,
          reason: url,
        );
      }
      for (final ip in [
        '0.0.0.0',
        '127.0.0.1',
        '100.64.0.1',
        '169.254.169.254',
        '192.168.1.1',
        '198.18.0.1',
        '224.0.0.1',
        '255.255.255.255',
        '::1',
        '::ffff:127.0.0.1',
        'fc00::1',
        'fe80::1',
        '2001:db8::1',
        '2002:7f00:1::',
      ]) {
        expect(isPublicBillingAddress(InternetAddress(ip)), false, reason: ip);
      }
      expect(isPublicBillingAddress(InternetAddress('8.8.8.8')), true);
      expect(
        isPublicBillingAddress(InternetAddress('2606:4700:4700::1111')),
        true,
      );
    },
  );

  test('native DNS transport refuses loopback without connecting', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var connections = 0;
    final subscription = listener.listen((socket) {
      connections++;
      socket.destroy();
    });
    final client = createBillingHttpClient();
    try {
      await expectLater(
        client.get(Uri.parse('https://localhost:${listener.port}/verify')),
        throwsA(isA<http.ClientException>()),
      );
      expect(connections, 0);
    } finally {
      client.close();
      await subscription.cancel();
      await listener.close();
    }
  });

  test(
    'unconfigured and half-configured clients make no verification calls or identifiers',
    () async {
      final storage = MemoryBillingStorage();
      final controller = SubscriptionController.unconfigured(
        platform: BillingStorePlatform.androidGooglePlay,
        storage: storage,
      );
      await controller.initialize();
      expect(storage.debugSnapshot, isEmpty);
      expect(controller.isProEntitled, false);
      controller.dispose();
      final key = TestEd25519KeyPair.fromSeed(Uint8List(32)..[0] = 19);
      final full = makeConfiguredTestBillingConfig(key);
      var requests = 0;
      final client = HttpPurchaseVerificationClient(
        config: BillingConfig(
          verificationEndpoint: full.verificationEndpoint,
          entitlementPublicKeys: full.entitlementPublicKeys,
        ),
        httpClient: MockClient((_) async {
          requests++;
          throw StateError('must not call');
        }),
      );
      final result = await client.verifyPurchase(
        packageName: BillingConfig.defaultPackageName,
        productId: 'fixture',
        purchaseToken: 'private-fixture-token',
        obfuscatedAccountId: 'fixture-account',
      );
      expect(result.status, VerificationStatus.notConfigured);
      expect(requests, 0);
    },
  );

  test(
    'verification refuses redirects and bounds responses without leaking tokens',
    () async {
      final key = TestEd25519KeyPair.fromSeed(Uint8List(32)..[0] = 19);
      for (final response in [
        http.Response(
          '',
          307,
          headers: {'location': 'http://192.168.1.1/steal'},
        ),
        http.Response('x' * 65537, 200),
      ]) {
        var requests = 0;
        final client = HttpPurchaseVerificationClient(
          config: makeConfiguredTestBillingConfig(key),
          httpClient: MockClient((request) async {
            requests++;
            expect(request.followRedirects, false);
            expect(request.url.scheme, 'https');
            expect(request.url.query, isEmpty);
            expect(
              jsonDecode(request.body)['purchaseToken'],
              'private-fixture-token',
            );
            return response;
          }),
        );
        final result = await client.verifyPurchase(
          packageName: BillingConfig.defaultPackageName,
          productId: BillingConfig.recommendedMonthlyProductId,
          purchaseToken: 'private-fixture-token',
          obfuscatedAccountId: 'fixture-account',
        );
        expect(result.isVerified, false);
        expect(requests, 1);
        expect(
          result.sanitizedMessage ?? '',
          isNot(contains('private-fixture-token')),
        );
      }
    },
  );
}
