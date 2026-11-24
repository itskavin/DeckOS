/// Encrypted storage adapter for signed entitlement grants and the opaque
/// installation-scoped `obfuscatedAccountId`.
///
/// Entitlements are NEVER persisted as a bare `is_pro = true` preference flag.
/// Every cached grant is stored as a [SignedEntitlementEnvelope] and
/// cryptographically re-verified on read.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'billing_models.dart';

/// Abstract key-value secure storage interface for billing state.
abstract class BillingStorage {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Keystore-backed Android secure storage (matching DeckOS's `CredentialStore`).
class SecureBillingStorage implements BillingStorage {
  const SecureBillingStorage([
    this._storage = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    ),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory storage for deterministic unit and widget tests.
class MemoryBillingStorage implements BillingStorage {
  final Map<String, String> _data = <String, String>{};

  Map<String, String> get debugSnapshot =>
      Map<String, String>.unmodifiable(_data);

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }
}

/// Repository persisting signed entitlement envelopes and the opaque
/// installation-scoped account provenance ID (no DeckOS user account required).
class BillingCacheRepository {
  BillingCacheRepository(this._storage, {Random? random})
    : _random = random ?? Random.secure();

  static const String _envelopeKey = 'deckos_billing_signed_entitlement_v1';
  static const String _accountIdKey = 'deckos_billing_obfuscated_account_v1';

  final BillingStorage _storage;
  final Random _random;

  /// Returns an existing non-PII opaque installation ID or creates one
  /// (32-char hex string, well within Google Play's 64-char limit for
  /// `obfuscatedAccountId`).
  Future<String> getOrCreateObfuscatedAccountId() async {
    final existing = await _storage.read(_accountIdKey);
    if (existing != null && _isValidObfuscatedId(existing)) {
      return existing;
    }
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final digest = crypto.sha256.convert(bytes).toString().substring(0, 32);
    final id = 'dos_$digest';
    await _storage.write(_accountIdKey, id);
    return id;
  }

  Future<SignedEntitlementEnvelope?> readEnvelope() async {
    final raw = await _storage.read(_envelopeKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return SignedEntitlementEnvelope.tryParseJson(decoded);
    } catch (_) {
      return null;
    }
  }

  Future<void> saveEnvelope(SignedEntitlementEnvelope envelope) async {
    await _storage.write(_envelopeKey, jsonEncode(envelope.toJson()));
  }

  Future<void> clearEnvelope() => _storage.delete(_envelopeKey);

  static bool _isValidObfuscatedId(String value) =>
      value.length >= 16 &&
      value.length <= 64 &&
      RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value);
}
