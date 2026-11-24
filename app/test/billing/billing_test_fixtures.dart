/// Clearly labeled FAKE test fixtures for DeckOS Google Play Billing unit and
/// widget tests. These fixtures NEVER contact Google Play or charge users and
/// must NEVER be treated as live Play Store proof.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:deckos/src/billing/billing.dart';

/// Test-only RFC 8032 Ed25519 signer used solely inside tests to mint real
/// cryptographic signatures verified by production [Ed25519Verifier].
class TestEd25519KeyPair {
  TestEd25519KeyPair._(this._seed, this._scalar, this._prefix, this.publicKey);

  factory TestEd25519KeyPair.fromSeed(Uint8List seed) {
    assert(seed.length == 32);
    final h = Uint8List.fromList(crypto.sha512.convert(seed).bytes);
    final clamped = Uint8List.fromList(h.sublist(0, 32));
    clamped[0] &= 248;
    clamped[31] &= 63;
    clamped[31] |= 64;
    final scalar = _decodeLE(clamped);
    final prefix = Uint8List.fromList(h.sublist(32, 64));
    final pubPoint = _scalarMul(_basePoint, scalar);
    final pubBytes = _encodePoint(pubPoint);
    return TestEd25519KeyPair._(seed, scalar, prefix, pubBytes);
  }

  // ignore: unused_field
  final Uint8List _seed;
  final BigInt _scalar;
  final Uint8List _prefix;
  final Uint8List publicKey;

  String get publicKeyBase64Url =>
      base64Url.encode(publicKey).replaceAll('=', '');

  Uint8List sign(Uint8List message) {
    final rInput = Uint8List(_prefix.length + message.length)
      ..setRange(0, _prefix.length, _prefix)
      ..setRange(_prefix.length, _prefix.length + message.length, message);
    final r =
        _decodeLE(Uint8List.fromList(crypto.sha512.convert(rInput).bytes)) % _l;
    final rBytes = _encodePoint(_scalarMul(_basePoint, r));

    final kInput = Uint8List(64 + message.length)
      ..setRange(0, 32, rBytes)
      ..setRange(32, 64, publicKey)
      ..setRange(64, 64 + message.length, message);
    final k =
        _decodeLE(Uint8List.fromList(crypto.sha512.convert(kInput).bytes)) % _l;
    final s = (r + (k * _scalar)) % _l;
    final sBytes = _encodeLE(s, 32);

    return Uint8List(64)
      ..setRange(0, 32, rBytes)
      ..setRange(32, 64, sBytes);
  }

  SignedEntitlementEnvelope signGrant(
    SignedEntitlementGrant grant, {
    String keyId = 'test-k1',
  }) {
    final payload = base64Url
        .encode(utf8.encode(jsonEncode(grant.toJson())))
        .replaceAll('=', '');
    final signingInput = Uint8List.fromList(utf8.encode('$keyId.$payload'));
    final sig = base64Url.encode(sign(signingInput)).replaceAll('=', '');
    return SignedEntitlementEnvelope(
      keyId: keyId,
      payloadBase64Url: payload,
      signatureBase64Url: sig,
      grant: grant,
    );
  }

  static final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
  static final BigInt _l =
      (BigInt.one << 252) +
      BigInt.parse('27742317777372353535851937790883648493');
  static final BigInt _d =
      (_mod(-BigInt.from(121665)) * BigInt.from(121666).modInverse(_p)) % _p;
  static final BigInt _d2 = (_d * BigInt.two) % _p;

  static final _Pt _basePoint = _Pt(
    BigInt.parse(
      '15112221349535400772501151409588531511454012693041857206046113283949847762202',
    ),
    BigInt.parse(
      '46316835694926478169428394003475163141307993866256225615783033603165251855960',
    ),
    BigInt.one,
    (BigInt.parse(
              '15112221349535400772501151409588531511454012693041857206046113283949847762202',
            ) *
            BigInt.parse(
              '46316835694926478169428394003475163141307993866256225615783033603165251855960',
            )) %
        _p,
  );
  static final _Pt _identity = _Pt(
    BigInt.zero,
    BigInt.one,
    BigInt.one,
    BigInt.zero,
  );

  static BigInt _mod(BigInt v) {
    final r = v % _p;
    return r.isNegative ? r + _p : r;
  }

  static BigInt _decodeLE(Uint8List bytes) {
    var out = BigInt.zero;
    for (var i = bytes.length - 1; i >= 0; i--) {
      out = (out << 8) | BigInt.from(bytes[i]);
    }
    return out;
  }

  static Uint8List _encodeLE(BigInt v, int length) {
    final out = Uint8List(length);
    var cur = v;
    for (var i = 0; i < length; i++) {
      out[i] = (cur & BigInt.from(0xff)).toInt();
      cur >>= 8;
    }
    return out;
  }

  static _Pt _add(_Pt p1, _Pt p2) {
    final a = (_mod(p1.y - p1.x) * _mod(p2.y - p2.x)) % _p;
    final b = (_mod(p1.y + p1.x) * _mod(p2.y + p2.x)) % _p;
    final c = (((p1.t * _d2) % _p) * p2.t) % _p;
    final d = (((p1.z * BigInt.two) % _p) * p2.z) % _p;
    final e = _mod(b - a);
    final f = _mod(d - c);
    final g = _mod(d + c);
    final h = _mod(b + a);
    return _Pt((e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p);
  }

  static _Pt _scalarMul(_Pt base, BigInt scalar) {
    var result = _identity;
    var addend = base;
    var k = scalar;
    while (k > BigInt.zero) {
      if (k.isOdd) result = _add(result, addend);
      addend = _add(addend, addend);
      k >>= 1;
    }
    return result;
  }

  static Uint8List _encodePoint(_Pt p) {
    final zInv = p.z.modInverse(_p);
    final x = (p.x * zInv) % _p;
    final y = (p.y * zInv) % _p;
    final bytes = _encodeLE(y, 32);
    if (x.isOdd) bytes[31] |= 0x80;
    return bytes;
  }
}

class _Pt {
  const _Pt(this.x, this.y, this.z, this.t);
  final BigInt x;
  final BigInt y;
  final BigInt z;
  final BigInt t;
}

/// Clearly fake Google Play Store gateway for unit/widget testing.
class FakeBillingStoreGateway implements BillingStoreGateway {
  FakeBillingStoreGateway({
    this.platform = BillingStorePlatform.androidGooglePlay,
    this.storeAvailable = true,
    this.offers = const <SubscriptionPlanOffer>[],
    this.notFoundIds = const <String>{},
    this.queryErrorMessage,
    this.launchResult = const PurchaseLaunchResult(
      PurchaseLaunchStatus.launched,
    ),
    this.restoreUpdatesToEmit = const <StorePurchaseUpdate>[],
  });

  final StreamController<List<StorePurchaseUpdate>> _stream =
      StreamController<List<StorePurchaseUpdate>>.broadcast();

  @override
  BillingStorePlatform platform;

  bool storeAvailable;
  List<SubscriptionPlanOffer> offers;
  Set<String> notFoundIds;
  String? queryErrorMessage;
  PurchaseLaunchResult launchResult;
  List<StorePurchaseUpdate> restoreUpdatesToEmit;

  final List<SubscriptionPlanOffer> launchedOffers = <SubscriptionPlanOffer>[];
  final List<String> launchedAccountIds = <String>[];
  final List<StorePurchaseUpdate> completedPurchases = <StorePurchaseUpdate>[];
  int restoreCalls = 0;
  bool disposed = false;

  @override
  bool get isSupportedPlatform =>
      platform == BillingStorePlatform.androidGooglePlay;

  @override
  Stream<List<StorePurchaseUpdate>> get purchaseUpdates => _stream.stream;

  void emitPurchases(List<StorePurchaseUpdate> updates) {
    if (!_stream.isClosed) {
      _stream.add(updates);
    }
  }

  @override
  Future<bool> isStoreAvailable() async =>
      isSupportedPlatform && storeAvailable;

  @override
  Future<StoreProductQueryResult> querySubscriptionOffers(
    Set<String> productIds,
  ) async {
    return StoreProductQueryResult(
      offers: offers,
      notFoundIds: notFoundIds,
      errorMessage: queryErrorMessage,
    );
  }

  @override
  Future<PurchaseLaunchResult> launchSubscriptionPurchase({
    required SubscriptionPlanOffer offer,
    required String obfuscatedAccountId,
  }) async {
    launchedOffers.add(offer);
    launchedAccountIds.add(obfuscatedAccountId);
    return launchResult;
  }

  @override
  Future<void> restorePurchases() async {
    restoreCalls++;
    if (restoreUpdatesToEmit.isNotEmpty) {
      emitPurchases(restoreUpdatesToEmit);
    }
  }

  @override
  Future<void> completePurchase(StorePurchaseUpdate purchase) async {
    completedPurchases.add(purchase);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _stream.close();
  }
}

/// Clearly fake trusted backend verification client for deterministic tests.
class FakePurchaseVerificationClient implements PurchaseVerificationClient {
  FakePurchaseVerificationClient({
    required this.verifyHandler,
    this.refreshHandler,
  });

  Future<VerificationResult> Function({
    required String packageName,
    required String productId,
    required String purchaseToken,
    required String obfuscatedAccountId,
  })
  verifyHandler;

  Future<VerificationResult> Function({
    required String packageName,
    required String entitlementId,
    required String obfuscatedAccountId,
  })?
  refreshHandler;

  int verifyCalls = 0;
  int refreshCalls = 0;

  @override
  Future<VerificationResult> verifyPurchase({
    required String packageName,
    required String productId,
    required String purchaseToken,
    required String obfuscatedAccountId,
  }) async {
    verifyCalls++;
    return verifyHandler(
      packageName: packageName,
      productId: productId,
      purchaseToken: purchaseToken,
      obfuscatedAccountId: obfuscatedAccountId,
    );
  }

  @override
  Future<VerificationResult> refreshEntitlement({
    required String packageName,
    required String entitlementId,
    required String obfuscatedAccountId,
  }) async {
    refreshCalls++;
    if (refreshHandler != null) {
      return refreshHandler!(
        packageName: packageName,
        entitlementId: entitlementId,
        obfuscatedAccountId: obfuscatedAccountId,
      );
    }
    return const VerificationResult(status: VerificationStatus.offline);
  }
}

/// Sample FAKE localized Play offers for test fixtures (clearly test data).
List<SubscriptionPlanOffer> sampleFakePlayOffers({bool includeTrial = false}) =>
    <SubscriptionPlanOffer>[
      SubscriptionPlanOffer(
        productId: BillingConfig.recommendedMonthlyProductId,
        basePlanId: 'monthly-base',
        interval: BillingInterval.monthly,
        title: 'DeckOS Pro Monthly (Test Fixture)',
        description: 'Monthly recurring test fixture offer',
        formattedPrice: r'$4.99',
        priceAmountMicros: 4990000,
        currencyCode: 'USD',
        billingPeriodIso: 'P1M',
        freeTrialPeriodIso: includeTrial ? 'P7D' : null,
      ),
      const SubscriptionPlanOffer(
        productId: BillingConfig.recommendedYearlyProductId,
        basePlanId: 'yearly-base',
        interval: BillingInterval.yearly,
        title: 'DeckOS Pro Yearly (Test Fixture)',
        description: 'Yearly recurring test fixture offer',
        formattedPrice: r'$49.99',
        priceAmountMicros: 49990000,
        currencyCode: 'USD',
        billingPeriodIso: 'P1Y',
      ),
    ];

BillingConfig makeConfiguredTestBillingConfig(TestEd25519KeyPair keyPair) =>
    BillingConfig(
      packageName: BillingConfig.defaultPackageName,
      monthlyProductId: BillingConfig.recommendedMonthlyProductId,
      yearlyProductId: BillingConfig.recommendedYearlyProductId,
      verificationEndpoint: Uri.parse('https://billing.bytetrix.example'),
      entitlementPublicKeys: <String, String>{
        'test-k1': keyPair.publicKeyBase64Url,
      },
      offlineGraceWindow: const Duration(hours: 72),
    );
