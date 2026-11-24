import { createServiceAccountJwt } from './crypto.mjs';

/**
 * Google Play Developer API v3 client for Subscriptions V2:
 * - GET  /androidpublisher/v3/applications/{packageName}/purchases/subscriptionsv2/tokens/{token}
 * - POST /androidpublisher/v3/applications/{packageName}/purchases/subscriptions/{subscriptionId}/tokens/{token}:acknowledge
 *
 * Primary references:
 * - https://developer.android.com/google/play/billing/subscriptions
 * - https://developers.google.com/android-publisher/api-ref/rest/v3/purchases.subscriptionsv2/get
 */

export const ANDROID_PUBLISHER_BASE =
  'https://androidpublisher.googleapis.com/androidpublisher/v3';

/**
 * Maps a `SubscriptionPurchaseV2` resource into normalized DeckOS entitlement
 * state fields.
 */
export function normalizeSubscriptionV2(resource, nowMs = Date.now()) {
  const lineItems = Array.isArray(resource?.lineItems)
    ? resource.lineItems
    : [];
  const primaryItem = lineItems[0] ?? null;
  const productId = primaryItem?.productId ?? null;
  const expiryMs = primaryItem?.expiryTime
    ? Date.parse(primaryItem.expiryTime)
    : null;
  const autoRenewing = Boolean(
    primaryItem?.autoRenewingPlan?.autoRenewEnabled,
  );
  const acknowledged =
    resource?.acknowledgementState === 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED';
  const obfuscatedExternalAccountId =
    resource?.externalAccountIdentifiers?.obfuscatedExternalAccountId ?? null;
  const linkedPurchaseToken = resource?.linkedPurchaseToken ?? null;

  const rawState = resource?.subscriptionState ?? 'SUBSCRIPTION_STATE_UNSPECIFIED';
  const hasFutureExpiry = Number.isFinite(expiryMs) && expiryMs > nowMs;

  let state;
  switch (rawState) {
    case 'SUBSCRIPTION_STATE_PENDING':
      state = 'pending';
      break;
    case 'SUBSCRIPTION_STATE_ACTIVE':
      state = hasFutureExpiry ? 'active' : 'expired';
      break;
    case 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD':
      state = hasFutureExpiry ? 'inGracePeriod' : 'expired';
      break;
    case 'SUBSCRIPTION_STATE_ON_HOLD':
      state = 'onHold';
      break;
    case 'SUBSCRIPTION_STATE_PAUSED':
      state = 'paused';
      break;
    case 'SUBSCRIPTION_STATE_CANCELED':
      state = hasFutureExpiry ? 'canceledActive' : 'expired';
      break;
    case 'SUBSCRIPTION_STATE_EXPIRED':
      state =
        resource?.canceledStateContext?.developerInitiatedCancellation != null ||
        resource?.canceledStateContext?.systemInitiatedCancellation != null
          ? 'revoked'
          : 'expired';
      break;
    default:
      state = 'free';
      break;
  }

  return {
    productId,
    state,
    expiresAtMs: Number.isFinite(expiryMs) ? expiryMs : null,
    autoRenewing,
    acknowledged,
    obfuscatedExternalAccountId,
    linkedPurchaseToken,
    rawSubscriptionState: rawState,
  };
}

/**
 * Live Google Play Developer API client using a GCP service account
 * (credentials loaded strictly on the trusted backend, NEVER shipped in the
 * Android APK or PC companion).
 */
export class GooglePlayDeveloperClient {
  constructor({
    serviceAccountEmail,
    serviceAccountPrivateKeyPem,
    fetchImpl = globalThis.fetch,
    rpcTimeoutMs = 10000,
    tokenUri = 'https://oauth2.googleapis.com/token',
  }) {
    this._rpcTimeoutMs = rpcTimeoutMs;
    this._email = serviceAccountEmail;
    this._privateKeyPem = serviceAccountPrivateKeyPem;
    this._fetch = fetchImpl;
    this._tokenUri = tokenUri;
    this._cachedToken = null;
    this._cachedTokenExpiryMs = 0;
  }

  async _fetchBounded(url, options) {
    return this._fetch(url, {
      ...options,
      redirect: 'error',
      signal: AbortSignal.timeout(this._rpcTimeoutMs),
    });
  }

  async _getAccessToken() {
    const now = Date.now();
    if (this._cachedToken && now < this._cachedTokenExpiryMs - 60_000) {
      return this._cachedToken;
    }
    const assertion = createServiceAccountJwt({
      clientEmail: this._email,
      privateKeyPem: this._privateKeyPem,
      tokenUri: this._tokenUri,
    });
    const body = new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion,
    });
    const res = await this._fetchBounded(this._tokenUri, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: body.toString(),
    });
    if (!res.ok) {
      throw new Error(`OAuth2 token exchange failed with HTTP ${res.status}`);
    }
    const json = await res.json();
    this._cachedToken = json.access_token;
    this._cachedTokenExpiryMs = now + Number(json.expires_in ?? 3600) * 1000;
    return this._cachedToken;
  }

  async getSubscriptionV2({ packageName, purchaseToken }) {
    const accessToken = await this._getAccessToken();
    const url =
      `${ANDROID_PUBLISHER_BASE}/applications/${encodeURIComponent(packageName)}` +
      `/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`;
    const res = await this._fetchBounded(url, {
      method: 'GET',
      headers: {
        authorization: `Bearer ${accessToken}`,
        accept: 'application/json',
      },
    });
    if (res.status === 404 || res.status === 410) {
      return null;
    }
    if (!res.ok) {
      throw new Error(`Play subscriptionsv2.get failed with HTTP ${res.status}`);
    }
    return await res.json();
  }

  async acknowledgeSubscription({
    packageName,
    subscriptionId,
    purchaseToken,
    developerPayload = '',
  }) {
    const accessToken = await this._getAccessToken();
    const url =
      `${ANDROID_PUBLISHER_BASE}/applications/${encodeURIComponent(packageName)}` +
      `/purchases/subscriptions/${encodeURIComponent(subscriptionId)}` +
      `/tokens/${encodeURIComponent(purchaseToken)}:acknowledge`;
    const res = await this._fetchBounded(url, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${accessToken}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify(
        developerPayload ? { developerPayload } : {},
      ),
    });
    if (!res.ok) {
      throw new Error(
        `Play subscriptions.acknowledge failed with HTTP ${res.status}`,
      );
    }
  }
}
