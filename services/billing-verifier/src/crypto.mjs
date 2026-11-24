import crypto from 'node:crypto';

/**
 * Cryptographic helpers for DeckOS Billing Verifier:
 * - Ed25519 asymmetric signing & verification of entitlement envelopes (matching
 *   Dart's `app/lib/src/billing/ed25519_verifier.dart` byte-for-byte).
 * - Privacy-preserving keyed SHA-256 hashing of Google Play purchaseTokens.
 * - RS256 Service Account JWT assertions for Google Play Developer API OAuth2.
 */

export function generateEd25519KeyPair() {
  const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
  // Export raw 32-byte Ed25519 public key from SPKI DER (last 32 bytes of 44-byte SPKI).
  const spki = publicKey.export({ type: 'spki', format: 'der' });
  const rawPublicKey = spki.subarray(spki.length - 32);
  return {
    publicKey,
    privateKey,
    publicKeyBase64Url: rawPublicKey.toString('base64url'),
    publicKeyPem: publicKey.export({ type: 'spki', format: 'pem' }).toString(),
    privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
  };
}

/**
 * Reconstructs a Node KeyObject from a raw 32-byte base64url Ed25519 public key.
 */
export function publicKeyFromRawBase64Url(rawBase64Url) {
  const raw = Buffer.from(rawBase64Url, 'base64url');
  if (raw.length !== 32) {
    throw new Error('Ed25519 public key must be 32 bytes');
  }
  // ASN.1 SPKI prefix for OID 1.3.101.112 (id-Ed25519)
  const spkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
  return crypto.createPublicKey({
    key: Buffer.concat([spkiPrefix, raw]),
    format: 'der',
    type: 'spki',
  });
}

/**
 * Signs a DeckOS entitlement grant payload into the canonical wire envelope:
 *   `{ kid, payload, sig }`
 * where `sig = Ed25519(privateKey, utf8("${kid}.${payload}"))`.
 */
export function signEntitlementGrant(grant, { privateKey, keyId }) {
  if (!keyId || typeof keyId !== 'string') {
    throw new Error('keyId is required');
  }
  const keyObj =
    typeof privateKey === 'string'
      ? crypto.createPrivateKey(privateKey)
      : privateKey;
  const payloadBase64Url = Buffer.from(JSON.stringify(grant), 'utf8').toString(
    'base64url',
  );
  const signingInput = Buffer.from(`${keyId}.${payloadBase64Url}`, 'utf8');
  const signature = crypto.sign(null, signingInput, keyObj);
  return {
    kid: keyId,
    payload: payloadBase64Url,
    sig: signature.toString('base64url'),
  };
}

/**
 * Verifies an entitlement envelope against a map of `keyId -> rawBase64Url`.
 */
export function verifyEntitlementEnvelope(envelope, publicKeysById) {
  if (
    !envelope ||
    typeof envelope.kid !== 'string' ||
    typeof envelope.payload !== 'string' ||
    typeof envelope.sig !== 'string'
  ) {
    return { valid: false, grant: null };
  }
  const rawPub = publicKeysById[envelope.kid];
  if (!rawPub) {
    return { valid: false, grant: null };
  }
  try {
    const pubKey = publicKeyFromRawBase64Url(rawPub);
    const signingInput = Buffer.from(
      `${envelope.kid}.${envelope.payload}`,
      'utf8',
    );
    const sigBytes = Buffer.from(envelope.sig, 'base64url');
    const ok = crypto.verify(null, signingInput, pubKey, sigBytes);
    if (!ok) {
      return { valid: false, grant: null };
    }
    const grant = JSON.parse(
      Buffer.from(envelope.payload, 'base64url').toString('utf8'),
    );
    return { valid: true, grant };
  } catch {
    return { valid: false, grant: null };
  }
}

/**
 * Privacy-preserving keyed hash of a Google Play `purchaseToken`.
 * Used as the primary database/log lookup key so raw tokens are never logged.
 */
export function hashPurchaseToken(purchaseToken, hmacSecret) {
  if (!purchaseToken || !hmacSecret) {
    throw new Error('purchaseToken and hmacSecret are required');
  }
  return crypto
    .createHmac('sha256', hmacSecret)
    .update(purchaseToken, 'utf8')
    .digest('hex');
}

/**
 * Creates a signed RS256 JWT assertion for Google Service Account OAuth2 token
 * exchange (`https://oauth2.googleapis.com/token`).
 */
export function createServiceAccountJwt({
  clientEmail,
  privateKeyPem,
  scope = 'https://www.googleapis.com/auth/androidpublisher',
  tokenUri = 'https://oauth2.googleapis.com/token',
  nowSec = Math.floor(Date.now() / 1000),
}) {
  const header = Buffer.from(
    JSON.stringify({ alg: 'RS256', typ: 'JWT' }),
    'utf8',
  ).toString('base64url');
  const claims = Buffer.from(
    JSON.stringify({
      iss: clientEmail,
      scope,
      aud: tokenUri,
      iat: nowSec,
      exp: nowSec + 3600,
    }),
    'utf8',
  ).toString('base64url');
  const signingInput = `${header}.${claims}`;
  const signature = crypto
    .sign('RSA-SHA256', Buffer.from(signingInput, 'utf8'), privateKeyPem)
    .toString('base64url');
  return `${signingInput}.${signature}`;
}

export function sanitizeForLogs(raw, sensitiveValues = []) {
  if (!raw) return '';
  let text = String(raw);
  for (const secret of sensitiveValues) {
    if (secret) {
      text = text.split(secret).join('[redacted]');
    }
  }
  return text.replace(/\b[A-Za-z0-9._-]{32,}\b/g, '[redacted]');
}
