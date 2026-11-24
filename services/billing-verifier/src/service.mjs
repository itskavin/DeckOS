import crypto from 'node:crypto';
import {
  hashPurchaseToken,
  signEntitlementGrant,
} from './crypto.mjs';
import { normalizeSubscriptionV2 } from './play_api.mjs';
import { parsePubSubRtdnBody } from './rtdn.mjs';

export const DEFAULT_PACKAGE_NAME = 'io.github.itskavin.deckos';
export const DEFAULT_OFFLINE_WINDOW_MS = 72 * 60 * 60 * 1000;

/**
 * Trusted server-side Google Play subscription verification & RTDN processor.
 *
 * Security & privacy invariants:
 * 1. Never trusts client booleans or local PC companions.
 * 2. Always queries `purchases.subscriptionsv2.get` on Google Play as source of truth.
 * 3. Server-side acknowledges ONLY verified, non-pending, active/grace purchases
 *    within Play's 3-day window (5 minutes for license testers).
 * 4. Enforces package name binding and `obfuscatedExternalAccountId` replay
 *    protection. Cross-install recovery requires a separate authenticated design.
 * 5. Never logs or returns raw `purchaseToken` values.
 * 6. Signs short-lived, offline-bounded entitlement grants with Ed25519 so the
 *    Android client needs only the public key.
 */
export class BillingVerificationService {
  constructor({
    packageName = DEFAULT_PACKAGE_NAME,
    playApi,
    store,
    signingPrivateKey,
    signingKeyId,
    tokenHmacSecret,
    verifyPubSubAuth,
    offlineWindowMs = DEFAULT_OFFLINE_WINDOW_MS,
    productIds = [],
    clock = () => Date.now(),
    log = () => {},
  }) {
    this._packageName = packageName;
    this._playApi = playApi;
    this._store = store;
    this._signingPrivateKey = signingPrivateKey;
    this._signingKeyId = signingKeyId;
    this._tokenHmacSecret = tokenHmacSecret;
    this._verifyPubSubAuth = verifyPubSubAuth;
    this._offlineWindowMs = Math.max(0, Math.min(offlineWindowMs, 7 * 24 * 60 * 60 * 1000));
    this._productIds = new Set(productIds);
    this._clock = clock;
    this._log = log;
  }

  /**
   * Verifies a purchase or restore submitted by the Android app, acknowledges
   * eligible purchases on Google Play, persists state keyed by token hash, and
   * returns an Ed25519-signed entitlement envelope.
   */
  async verifyPurchase({
    packageName,
    productId,
    purchaseToken,
    obfuscatedAccountId,
  }) {
    if (packageName !== this._packageName) {
      return { ok: false, statusCode: 403, code: 'package_mismatch' };
    }
    if (
      !purchaseToken ||
      typeof purchaseToken !== 'string' ||
      purchaseToken.length < 8 || purchaseToken.length > 8192
    ) {
      return { ok: false, statusCode: 400, code: 'invalid_purchase_token' };
    }
    if (
      !obfuscatedAccountId ||
      typeof obfuscatedAccountId !== 'string' ||
      obfuscatedAccountId.length < 16 ||
      obfuscatedAccountId.length > 64
    ) {
      return { ok: false, statusCode: 400, code: 'invalid_account_id' };
    }

    const tokenHash = hashPurchaseToken(purchaseToken, this._tokenHmacSecret);
    const nowMs = this._clock();

    let resource;
    try {
      resource = await this._playApi.getSubscriptionV2({
        packageName: this._packageName,
        purchaseToken,
      });
    } catch (err) {
      this._log(
        `Play API lookup failed for ${tokenHash.slice(0, 12)}: upstream_request_failed`,
      );
      return { ok: false, statusCode: 502, code: 'play_api_unavailable' };
    }

    if (!resource) {
      return { ok: false, statusCode: 404, code: 'purchase_not_found' };
    }

    const normalized = normalizeSubscriptionV2(resource, nowMs);
    const effectiveProductId = normalized.productId;
    if (!effectiveProductId || effectiveProductId !== productId || !this._productIds.has(effectiveProductId)) {
      return { ok: false, statusCode: 403, code: 'product_mismatch' };
    }
    const existing = await this._store.getByTokenHash(tokenHash);
    // Google reports checkout binding, NOT proof that a caller supplying a
    // stolen token owns the Play account. Never allow a first-claim bypass or
    // transfer to a freshly generated installation ID after reinstall.
    if (normalized.obfuscatedExternalAccountId !== obfuscatedAccountId ||
        (existing && existing.boundAccountId !== obfuscatedAccountId)) {
      return { ok: false, statusCode: 403, code: 'account_binding_mismatch' };
    }

    // Server-side acknowledgement within Play's 3-day window (5 min for testers).
    // NEVER acknowledge PENDING, ON_HOLD, PAUSED, EXPIRED, or REVOKED purchases.
    let acknowledged = normalized.acknowledged;
    const eligibleToAcknowledge =
      !acknowledged &&
      (normalized.state === 'active' ||
        normalized.state === 'inGracePeriod' ||
        normalized.state === 'canceledActive');

    if (eligibleToAcknowledge && effectiveProductId) {
      try {
        await this._playApi.acknowledgeSubscription({
          packageName: this._packageName,
          subscriptionId: effectiveProductId,
          purchaseToken,
        });
        acknowledged = true;
        this._log(
          `Acknowledged subscription ${effectiveProductId} (${tokenHash.slice(0, 12)})`,
        );
      } catch (err) {
        this._log(
          `Acknowledge failed for ${tokenHash.slice(0, 12)}: upstream_request_failed`,
        );
        return { ok: false, statusCode: 502, code: 'acknowledgement_failed' };
      }
    }

    const entitlementId =
      existing?.entitlementId ??
      `ent_${crypto.randomBytes(16).toString('hex')}`;

    const record = {
      entitlementId,
      tokenHash,
      // Stored strictly server-side for background refresh/RTDN sync; NEVER
      // returned in HTTP responses or logs. Production DB must encrypt this column.
      purchaseToken,
      productId: effectiveProductId,
      state: normalized.state,
      expiresAtMs: normalized.expiresAtMs,
      autoRenewing: normalized.autoRenewing,
      acknowledged,
      boundAccountId: obfuscatedAccountId,
      updatedAtMs: nowMs,
      lastEventTimeMillis: existing?.lastEventTimeMillis ?? nowMs,
    };
    await this._store.saveRecord(record);

    const envelope = this._issueEnvelope(record, nowMs);
    return { ok: true, statusCode: 200, entitlement: envelope };
  }

  /**
   * Refreshes an existing entitlement by opaque `entitlementId` (never needing
   * the client to re-send raw purchaseTokens on every app launch/resume).
   */
  async refreshEntitlement({ packageName, entitlementId, obfuscatedAccountId }) {
    if (packageName !== this._packageName) {
      return { ok: false, statusCode: 403, code: 'package_mismatch' };
    }
    const existing = await this._store.getByEntitlementId(entitlementId);
    if (!existing) {
      return { ok: false, statusCode: 404, code: 'entitlement_not_found' };
    }
    if (existing.boundAccountId !== obfuscatedAccountId) {
      return { ok: false, statusCode: 403, code: 'account_binding_mismatch' };
    }

    const nowMs = this._clock();
    try {
      const resource = await this._playApi.getSubscriptionV2({
        packageName: this._packageName,
        purchaseToken: existing.purchaseToken,
      });
      if (!resource) {
        const revokedRecord = {
          ...existing,
          state: 'revoked',
          autoRenewing: false,
          updatedAtMs: nowMs,
        };
        await this._store.saveRecord(revokedRecord);
        return {
          ok: true,
          statusCode: 200,
          entitlement: this._issueEnvelope(revokedRecord, nowMs),
        };
      }
      const normalized = normalizeSubscriptionV2(resource, nowMs);
      if (normalized.obfuscatedExternalAccountId !== obfuscatedAccountId ||
          !this._productIds.has(normalized.productId) || normalized.productId !== existing.productId) {
        return { ok: false, statusCode: 403, code: 'ownership_or_product_mismatch' };
      }
      const updated = {
        ...existing,
        productId: normalized.productId || existing.productId,
        state: normalized.state,
        expiresAtMs: normalized.expiresAtMs,
        autoRenewing: normalized.autoRenewing,
        acknowledged: normalized.acknowledged || existing.acknowledged,
        updatedAtMs: nowMs,
      };
      await this._store.saveRecord(updated);
      return {
        ok: true,
        statusCode: 200,
        entitlement: this._issueEnvelope(updated, nowMs),
      };
    } catch (err) {
      this._log(
        `Refresh Play API lookup failed for ${existing.entitlementId}: upstream_request_failed`,
      );
      return { ok: false, statusCode: 502, code: 'play_api_unavailable' };
    }
  }

  /**
   * Processes a Google Cloud Pub/Sub push RTDN message.
   * Always authenticates the Pub/Sub OIDC token first, deduplicates by
   * `messageId`, and re-queries `subscriptionsv2.get` as the authoritative state.
   */
  async handleRtdnPush({ authorizationHeader, body }) {
    if (!this._verifyPubSubAuth) {
      return { ok: false, statusCode: 500, code: 'rtdn_auth_unconfigured' };
    }
    const authorized = await this._verifyPubSubAuth(authorizationHeader);
    if (!authorized) {
      return { ok: false, statusCode: 401, code: 'unauthorized_pubsub_push' };
    }

    let parsed;
    try {
      parsed = parsePubSubRtdnBody(body);
    } catch {
      return { ok: false, statusCode: 400, code: 'malformed_rtdn' };
    }

    if (parsed.packageName !== this._packageName) {
      return { ok: false, statusCode: 403, code: 'package_mismatch' };
    }

    if (await this._store.hasProcessedRtdn(parsed.messageId)) {
      return { ok: true, statusCode: 200, duplicate: true };
    }

    if (parsed.testNotification) {
      await this._store.markRtdnProcessed(parsed.messageId);
      this._log(`Processed Play RTDN testNotification (${parsed.messageId})`);
      return { ok: true, statusCode: 200, testNotification: true };
    }

    const sub = parsed.subscriptionNotification;
    if (!sub || !sub.purchaseToken) {
      await this._store.markRtdnProcessed(parsed.messageId);
      return { ok: true, statusCode: 200, ignored: true };
    }

    const tokenHash = hashPurchaseToken(sub.purchaseToken, this._tokenHmacSecret);
    const existing = await this._store.getByTokenHash(tokenHash);
    const nowMs = this._clock();

    // Ignore out-of-order stale events older than already recorded state.
    if (
      existing &&
      parsed.eventTimeMillis > 0 &&
      parsed.eventTimeMillis < existing.lastEventTimeMillis
    ) {
      await this._store.markRtdnProcessed(parsed.messageId);
      return { ok: true, statusCode: 200, staleIgnored: true };
    }

    let resource;
    try {
      resource = await this._playApi.getSubscriptionV2({
        packageName: this._packageName,
        purchaseToken: sub.purchaseToken,
      });
    } catch (err) {
      this._log(
        `RTDN Play API lookup failed (${sub.notificationTypeName}, ${tokenHash.slice(0, 12)}): upstream_request_failed`,
      );
      // Return 503 so Google Cloud Pub/Sub retries with backoff.
      return { ok: false, statusCode: 503, code: 'play_api_unavailable' };
    }

    let nextState;
    let normalized = null;
    if (!resource) {
      nextState = sub.notificationType === 12 ? 'revoked' : 'expired';
    } else {
      normalized = normalizeSubscriptionV2(resource, nowMs);
      nextState =
        sub.notificationType === 12
          ? 'revoked'
          : sub.notificationType === 20
            ? 'free'
            : normalized.state;
    }

    const entitlementId =
      existing?.entitlementId ??
      `ent_${crypto.randomBytes(16).toString('hex')}`;
    const updated = {
      entitlementId,
      tokenHash,
      purchaseToken: sub.purchaseToken,
      productId: normalized?.productId || sub.subscriptionId || existing?.productId || null,
      state: nextState,
      expiresAtMs: normalized?.expiresAtMs ?? existing?.expiresAtMs ?? null,
      autoRenewing:
        nextState === 'revoked' ? false : (normalized?.autoRenewing ?? false),
      acknowledged: normalized?.acknowledged ?? existing?.acknowledged ?? false,
      boundAccountId:
        existing?.boundAccountId ??
        normalized?.obfuscatedExternalAccountId ??
        'unbound_rtdn',
      updatedAtMs: nowMs,
      lastEventTimeMillis: Math.max(
        parsed.eventTimeMillis || 0,
        existing?.lastEventTimeMillis ?? 0,
      ),
    };

    await this._store.saveRecord(updated);
    await this._store.markRtdnProcessed(parsed.messageId);
    this._log(
      `Processed RTDN ${sub.notificationTypeName} -> ${nextState} (${tokenHash.slice(0, 12)})`,
    );
    return { ok: true, statusCode: 200, state: nextState };
  }

  _issueEnvelope(record, nowMs) {
    const rawOfflineUntil = nowMs + this._offlineWindowMs;
    const boundedOfflineUntil =
      record.expiresAtMs != null
        ? Math.min(rawOfflineUntil, record.expiresAtMs)
        : rawOfflineUntil;

    const grant = {
      v: 1,
      pkg: this._packageName,
      eid: record.entitlementId,
      ...(record.productId ? { pid: record.productId } : {}),
      state: record.state,
      iat: nowMs,
      ...(record.expiresAtMs != null ? { exp: record.expiresAtMs } : {}),
      ovu: Math.max(nowMs, boundedOfflineUntil),
      ar: Boolean(record.autoRenewing),
      ack: Boolean(record.acknowledged),
      aid: record.boundAccountId,
    };

    return signEntitlementGrant(grant, {
      privateKey: this._signingPrivateKey,
      keyId: this._signingKeyId,
    });
  }
}
