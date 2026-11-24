/// Ed25519 verification delegated to package:cryptography 2.9.x.
/// Only public keys ship in the app. Encoding checks reject small-order points
/// consistently across Dart and browser/platform backends; no curve math here.
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

abstract final class Ed25519Verifier {
  static final Ed25519 _algorithm = Ed25519();

  static Future<bool> verify({
    required Uint8List message,
    required Uint8List signature,
    required Uint8List publicKey,
  }) async {
    if (signature.length != 64 || publicKey.length != 32) return false;
    if (_isSmallOrder(publicKey) || _isSmallOrder(signature.sublist(0, 32))) {
      return false;
    }
    try {
      return await _algorithm.verify(
        message,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  // Canonical small-order y encodings (sign bit ignored). Noncanonical points
  // and S >= L are rejected by the maintained Ed25519 implementation.
  static bool _isSmallOrder(List<int> encoded) {
    final bytes = List<int>.of(encoded)..[31] &= 0x7f;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return const <String>{
      '0000000000000000000000000000000000000000000000000000000000000000',
      '0100000000000000000000000000000000000000000000000000000000000000',
      'ecffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff7f',
      '26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05',
      'c7176a703d4dd84fba3c0b760d10670f2a2053fa2c39ccc64ec7fd7792ac037a',
    }.contains(hex);
  }

  static Future<bool> verifyBase64({
    required String payload,
    required String signatureBase64,
    required String publicKeyBase64,
  }) async {
    final pub = tryDecodeBase64Bytes(publicKeyBase64);
    final sig = tryDecodeBase64Bytes(signatureBase64);
    if (pub == null || sig == null) return false;
    return verify(
      message: Uint8List.fromList(utf8.encode(payload)),
      signature: sig,
      publicKey: pub,
    );
  }

  static Uint8List? tryDecodeBase64Bytes(String input) {
    if (input.trim().isEmpty) return null;
    try {
      return base64Url.decode(base64Url.normalize(input.trim()));
    } catch (_) {
      return null;
    }
  }
}
