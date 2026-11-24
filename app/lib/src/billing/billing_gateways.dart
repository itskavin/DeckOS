/// Store and server-verification gateway interfaces for DeckOS Google Play
/// subscriptions.
///
/// Design invariants:
/// - Google Play Billing is Android-only; non-Android platforms return an
///   honest unsupported state and never claim Play purchase capability.
/// - Purchase verification MUST go to a trusted HTTPS billing backend (never
///   the user's local PC companion, never reusing PC API keys or LAN TLS pins).
/// - Purchase tokens are sent ONLY in HTTPS POST request bodies, never in query
///   strings, logs, or UI error text.
/// - Every returned entitlement envelope MUST pass Ed25519 signature validation
///   against [BillingConfig.entitlementPublicKeys] before being trusted.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:http/http.dart' as http;

import 'billing_config.dart';
import 'billing_http_client.dart';
import 'billing_models.dart';
import 'ed25519_verifier.dart';

/// Detects the current runtime [BillingStorePlatform].
BillingStorePlatform detectBillingStorePlatform() {
  if (kIsWeb) return BillingStorePlatform.web;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => BillingStorePlatform.androidGooglePlay,
    TargetPlatform.iOS => BillingStorePlatform.ios,
    TargetPlatform.windows ||
    TargetPlatform.macOS ||
    TargetPlatform.linux => BillingStorePlatform.desktop,
    TargetPlatform.fuchsia => BillingStorePlatform.unsupported,
  };
}

/// Store-level adapter abstracting Google Play Billing (`in_app_purchase`).
abstract class BillingStoreGateway {
  BillingStorePlatform get platform;

  bool get isSupportedPlatform =>
      platform == BillingStorePlatform.androidGooglePlay;

  /// Stream of normalized purchase updates emitted by Google Play.
  Stream<List<StorePurchaseUpdate>> get purchaseUpdates;

  Future<bool> isStoreAvailable();

  Future<StoreProductQueryResult> querySubscriptionOffers(
    Set<String> productIds,
  );

  Future<PurchaseLaunchResult> launchSubscriptionPurchase({
    required SubscriptionPlanOffer offer,
    required String obfuscatedAccountId,
  });

  Future<void> restorePurchases();

  /// Completes/acknowledges on-device ONLY after trusted server verification
  /// succeeds (or when Play requires client completion post-verification).
  Future<void> completePurchase(StorePurchaseUpdate purchase);

  Future<void> dispose();
}

/// Honest no-op gateway used when Google Play products/adapter are not yet
/// configured or when running on non-Android platforms.
class UnconfiguredBillingStoreGateway implements BillingStoreGateway {
  UnconfiguredBillingStoreGateway({BillingStorePlatform? platform})
    : platform = platform ?? detectBillingStorePlatform();

  final StreamController<List<StorePurchaseUpdate>> _controller =
      StreamController<List<StorePurchaseUpdate>>.broadcast();

  @override
  final BillingStorePlatform platform;

  @override
  bool get isSupportedPlatform =>
      platform == BillingStorePlatform.androidGooglePlay;

  @override
  Stream<List<StorePurchaseUpdate>> get purchaseUpdates => _controller.stream;

  @override
  Future<bool> isStoreAvailable() async => false;

  @override
  Future<StoreProductQueryResult> querySubscriptionOffers(
    Set<String> productIds,
  ) async {
    return StoreProductQueryResult(
      offers: const <SubscriptionPlanOffer>[],
      notFoundIds: productIds,
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
    return const PurchaseLaunchResult(PurchaseLaunchStatus.notConfigured);
  }

  @override
  Future<void> restorePurchases() async {}

  @override
  Future<void> completePurchase(StorePurchaseUpdate purchase) async {}

  @override
  Future<void> dispose() async {
    await _controller.close();
  }
}

/// Outcome of contacting the trusted billing verification backend.
enum VerificationStatus {
  verified,
  notConfigured,
  offline,
  invalidSignature,
  rejected,
  serverError,
}

class VerificationResult {
  const VerificationResult({
    required this.status,
    this.envelope,
    this.errorCode,
    this.sanitizedMessage,
  });

  final VerificationStatus status;
  final SignedEntitlementEnvelope? envelope;
  final String? errorCode;
  final String? sanitizedMessage;

  bool get isVerified =>
      status == VerificationStatus.verified && envelope != null;
}

/// Client interface for server-side Google Play subscription verification.
abstract class PurchaseVerificationClient {
  Future<VerificationResult> verifyPurchase({
    required String packageName,
    required String productId,
    required String purchaseToken,
    required String obfuscatedAccountId,
  });

  Future<VerificationResult> refreshEntitlement({
    required String packageName,
    required String entitlementId,
    required String obfuscatedAccountId,
  });
}

/// Fails closed when no verification backend is configured.
class UnconfiguredPurchaseVerificationClient
    implements PurchaseVerificationClient {
  const UnconfiguredPurchaseVerificationClient();

  @override
  Future<VerificationResult> verifyPurchase({
    required String packageName,
    required String productId,
    required String purchaseToken,
    required String obfuscatedAccountId,
  }) async {
    return const VerificationResult(status: VerificationStatus.notConfigured);
  }

  @override
  Future<VerificationResult> refreshEntitlement({
    required String packageName,
    required String entitlementId,
    required String obfuscatedAccountId,
  }) async {
    return const VerificationResult(status: VerificationStatus.notConfigured);
  }
}

/// HTTPS verification client targeting the trusted DeckOS billing backend.
///
/// Enforces:
/// 1. Public HTTPS endpoint only (refuses cleartext HTTP and local/LAN hosts).
/// 2. Purchase token transmitted solely in HTTPS POST JSON body.
/// 3. Ed25519 signature verification of every returned envelope against
///    [BillingConfig.entitlementPublicKeys].
/// 4. Strict redaction of any sensitive tokens in error diagnostics.
class HttpPurchaseVerificationClient implements PurchaseVerificationClient {
  HttpPurchaseVerificationClient({
    required BillingConfig config,
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 15),
  }) : _config = config,
       _httpClient = httpClient ?? createBillingHttpClient(),
       _ownsClient = httpClient == null,
       _timeout = timeout;

  final BillingConfig _config;
  final http.Client _httpClient;
  final bool _ownsClient;
  final Duration _timeout;

  @override
  Future<VerificationResult> verifyPurchase({
    required String packageName,
    required String productId,
    required String purchaseToken,
    required String obfuscatedAccountId,
  }) {
    if (!_config.isFullyConfigured) {
      return Future<VerificationResult>.value(
        const VerificationResult(status: VerificationStatus.notConfigured),
      );
    }
    return _postAndVerify(
      path: '/v1/billing/verify',
      body: <String, Object?>{
        'packageName': packageName,
        'productId': productId,
        'purchaseToken': purchaseToken,
        'obfuscatedAccountId': obfuscatedAccountId,
      },
    );
  }

  @override
  Future<VerificationResult> refreshEntitlement({
    required String packageName,
    required String entitlementId,
    required String obfuscatedAccountId,
  }) {
    if (!_config.isFullyConfigured) {
      return Future<VerificationResult>.value(
        const VerificationResult(status: VerificationStatus.notConfigured),
      );
    }
    return _postAndVerify(
      path: '/v1/billing/refresh',
      body: <String, Object?>{
        'packageName': packageName,
        'entitlementId': entitlementId,
        'obfuscatedAccountId': obfuscatedAccountId,
      },
    );
  }

  Future<VerificationResult> _postAndVerify({
    required String path,
    required Map<String, Object?> body,
  }) async {
    final base = _config.verificationEndpoint;
    if (base == null || !BillingConfig.isValidVerificationEndpoint(base)) {
      return const VerificationResult(status: VerificationStatus.notConfigured);
    }
    final uri = base.replace(
      path: _joinPath(base.path, path),
      query: null,
      fragment: null,
    );
    final abort = Completer<void>();
    final timer = Timer(_timeout, () => abort.complete());
    try {
      final request =
          http.AbortableRequest('POST', uri, abortTrigger: abort.future)
            ..followRedirects = false
            ..headers.addAll(const {
              'content-type': 'application/json; charset=utf-8',
              'accept': 'application/json',
            })
            ..body = jsonEncode(body);
      final response = await (() async {
        final stream = await _httpClient.send(request);
        final bytes = <int>[];
        await for (final chunk in stream.stream) {
          if (bytes.length + chunk.length > 65536)
            throw const FormatException('Billing response too large');
          bytes.addAll(chunk);
        }
        return http.Response.bytes(bytes, stream.statusCode);
      })().timeout(_timeout);

      if (response.statusCode == 400 ||
          response.statusCode == 401 ||
          response.statusCode == 403 ||
          response.statusCode == 404 ||
          response.statusCode == 409) {
        return VerificationResult(
          status: VerificationStatus.rejected,
          errorCode: 'http_${response.statusCode}',
          sanitizedMessage: 'Billing verification failed',
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return VerificationResult(
          status: VerificationStatus.serverError,
          errorCode: 'http_${response.statusCode}',
          sanitizedMessage: 'Billing verification failed',
        );
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const VerificationResult(
          status: VerificationStatus.invalidSignature,
          errorCode: 'malformed_response',
        );
      }

      final envelopeMap = decoded['entitlement'] is Map<String, dynamic>
          ? decoded['entitlement'] as Map<String, dynamic>
          : decoded;
      final envelope = SignedEntitlementEnvelope.tryParseJson(envelopeMap);
      if (envelope == null) {
        return const VerificationResult(
          status: VerificationStatus.invalidSignature,
          errorCode: 'malformed_envelope',
        );
      }

      if (!await verifyEnvelopeSignature(
        envelope,
        publicKeys: _config.entitlementPublicKeys,
        expectedPackageName: _config.packageName,
      )) {
        return const VerificationResult(
          status: VerificationStatus.invalidSignature,
          errorCode: 'signature_invalid',
        );
      }

      return VerificationResult(
        status: VerificationStatus.verified,
        envelope: envelope,
      );
    } on TimeoutException {
      return const VerificationResult(
        status: VerificationStatus.offline,
        errorCode: 'timeout',
      );
    } catch (e) {
      return VerificationResult(
        status: VerificationStatus.offline,
        errorCode: 'network_error',
        sanitizedMessage: 'Billing service unavailable',
      );
    } finally {
      timer.cancel();
      if (!abort.isCompleted) abort.complete();
    }
  }

  /// Verifies the Ed25519 signature and package binding of [envelope].
  ///
  /// The signed message is canonical ASCII: `"${envelope.keyId}.${envelope.payloadBase64Url}"`,
  /// preventing key-ID substitution attacks.
  static Future<bool> verifyEnvelopeSignature(
    SignedEntitlementEnvelope envelope, {
    required Map<String, String> publicKeys,
    required String expectedPackageName,
  }) async {
    if (envelope.grant.packageName != expectedPackageName) return false;
    final publicKeyBase64 = publicKeys[envelope.keyId];
    if (publicKeyBase64 == null || publicKeyBase64.isEmpty) return false;
    final signingInput = '${envelope.keyId}.${envelope.payloadBase64Url}';
    return Ed25519Verifier.verifyBase64(
      payload: signingInput,
      signatureBase64: envelope.signatureBase64Url,
      publicKeyBase64: publicKeyBase64,
    );
  }

  static String _joinPath(String basePath, String leaf) {
    final a = basePath.endsWith('/')
        ? basePath.substring(0, basePath.length - 1)
        : basePath;
    final b = leaf.startsWith('/') ? leaf : '/$leaf';
    return '$a$b';
  }

  void dispose() {
    if (_ownsClient) {
      _httpClient.close();
    }
  }
}
