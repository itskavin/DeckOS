import test from 'node:test';
import { spawnSync } from 'node:child_process';
import { GooglePlayDeveloperClient } from '../src/play_api.mjs';
import assert from 'node:assert/strict';
import {
  generateEd25519KeyPair,
  hashPurchaseToken,
  signEntitlementGrant,
  verifyEntitlementEnvelope,
} from '../src/crypto.mjs';
import { normalizeSubscriptionV2 } from '../src/play_api.mjs';
import { createBillingHttpServer } from '../src/server.mjs';
import { BillingVerificationService, DEFAULT_PACKAGE_NAME } from '../src/service.mjs';
import { InMemoryBillingRecordStore } from '../src/store.mjs';

const BASE_TIME_MS = Date.parse('2026-11-24T12:00:00Z');
const ONE_MONTH_MS = 30 * 24 * 60 * 60 * 1000;
const RAW_TOKEN = 'gkp_fake_test_token_sensitive_9f8a7b6c5d4e3f2a1b0c9d8e7f6a';

function makeFakePlayApi(initialByToken = {}) {
  const resources = new Map(Object.entries(initialByToken));
  const acknowledgedCalls = [];
  return {
    resources,
    acknowledgedCalls,
    async getSubscriptionV2({ packageName, purchaseToken }) {
      assert.equal(packageName, DEFAULT_PACKAGE_NAME);
      return resources.get(purchaseToken) ?? null;
    },
    async acknowledgeSubscription({ packageName, subscriptionId, purchaseToken }) {
      acknowledgedCalls.push({ packageName, subscriptionId, purchaseToken });
      const current = resources.get(purchaseToken);
      if (current) {
        current.acknowledgementState = 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED';
      }
    },
  };
}

function makeSubV2({
  state = 'SUBSCRIPTION_STATE_ACTIVE',
  acknowledged = false,
  productId = 'deckos_pro_monthly',
  expiryMs = BASE_TIME_MS + ONE_MONTH_MS,
  autoRenew = true,
  obfuscatedExternalAccountId = 'dos_0123456789abcdef0123456789abcdef',
  developerInitiatedCancellation = null,
} = {}) {
  return {
    kind: 'androidpublisher#subscriptionPurchaseV2',
    subscriptionState: state,
    acknowledgementState: acknowledged
      ? 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED'
      : 'ACKNOWLEDGEMENT_STATE_PENDING',
    externalAccountIdentifiers: obfuscatedExternalAccountId
      ? { obfuscatedExternalAccountId }
      : undefined,
    canceledStateContext: developerInitiatedCancellation
      ? { developerInitiatedCancellation }
      : undefined,
    lineItems: [
      {
        productId,
        expiryTime: new Date(expiryMs).toISOString(),
        autoRenewingPlan: { autoRenewEnabled: autoRenew },
      },
    ],
  };
}

function makeService({
  playApi,
  store = new InMemoryBillingRecordStore(),
  nowMs = BASE_TIME_MS,
  verifyPubSubAuth = async (h) => h === 'Bearer valid-pubsub-oidc',
  logs = [],
}) {
  const keys = generateEd25519KeyPair();
  let currentNow = nowMs;
  const service = new BillingVerificationService({
    packageName: DEFAULT_PACKAGE_NAME,
    productIds: ['deckos_pro_monthly', 'deckos_pro_yearly'],
    playApi,
    store,
    signingPrivateKey: keys.privateKey,
    signingKeyId: 'k1',
    tokenHmacSecret: 'test-hmac-secret-never-ship-in-apk',
    verifyPubSubAuth,
    clock: () => currentNow,
    log: (msg) => logs.push(msg),
  });
  return {
    service,
    keys,
    store,
    logs,
    setNow: (ms) => {
      currentNow = ms;
    },
  };
}

test('Ed25519 envelope signing verifies and rejects tampering or key substitution', () => {
  const k1 = generateEd25519KeyPair();
  const k2 = generateEd25519KeyPair();
  const grant = {
    v: 1,
    pkg: DEFAULT_PACKAGE_NAME,
    eid: 'ent_abc123',
    pid: 'deckos_pro_monthly',
    state: 'active',
    iat: BASE_TIME_MS,
    exp: BASE_TIME_MS + ONE_MONTH_MS,
    ovu: BASE_TIME_MS + 72 * 3600 * 1000,
    ar: true,
    ack: true,
    aid: 'dos_0123456789abcdef0123456789abcdef',
  };
  const envelope = signEntitlementGrant(grant, {
    privateKey: k1.privateKey,
    keyId: 'k1',
  });
  const pubKeys = { k1: k1.publicKeyBase64Url, k2: k2.publicKeyBase64Url };

  const ok = verifyEntitlementEnvelope(envelope, pubKeys);
  assert.equal(ok.valid, true);
  assert.equal(ok.grant.eid, 'ent_abc123');

  // Tamper payload
  const tamperedPayload = Buffer.from(
    JSON.stringify({ ...grant, state: 'active', exp: BASE_TIME_MS + 9999999999 }),
  ).toString('base64url');
  assert.equal(
    verifyEntitlementEnvelope({ ...envelope, payload: tamperedPayload }, pubKeys).valid,
    false,
  );

  // Key ID substitution
  assert.equal(
    verifyEntitlementEnvelope({ ...envelope, kid: 'k2' }, pubKeys).valid,
    false,
  );
});

test('verifyPurchase queries subscriptionsv2, acknowledges once server-side, signs grant, and redacts raw token', async () => {
  const logs = [];
  const playApi = makeFakePlayApi({
    [RAW_TOKEN]: makeSubV2({ acknowledged: false }),
  });
  const { service, keys } = makeService({ playApi, logs });
  const accountId = 'dos_0123456789abcdef0123456789abcdef';

  const result = await service.verifyPurchase({
    packageName: DEFAULT_PACKAGE_NAME,
    productId: 'deckos_pro_monthly',
    purchaseToken: RAW_TOKEN,
    obfuscatedAccountId: accountId,
  });

  assert.equal(result.ok, true);
  assert.equal(playApi.acknowledgedCalls.length, 1);

  const verified = verifyEntitlementEnvelope(result.entitlement, {
    k1: keys.publicKeyBase64Url,
  });
  assert.equal(verified.valid, true);
  assert.equal(verified.grant.state, 'active');
  assert.equal(verified.grant.ack, true);
  assert.equal(verified.grant.pkg, DEFAULT_PACKAGE_NAME);
  assert.ok(verified.grant.ovu <= BASE_TIME_MS + 72 * 3600 * 1000);

  // Privacy invariant: raw purchaseToken never appears in response or logs.
  assert.equal(JSON.stringify(result).includes(RAW_TOKEN), false);
  assert.equal(logs.join('\n').includes(RAW_TOKEN), false);

  // Second verification call is idempotent and does NOT re-acknowledge.
  const second = await service.verifyPurchase({
    packageName: DEFAULT_PACKAGE_NAME,
    productId: 'deckos_pro_monthly',
    purchaseToken: RAW_TOKEN,
    obfuscatedAccountId: accountId,
  });
  assert.equal(second.ok, true);
  assert.equal(playApi.acknowledgedCalls.length, 1);
  assert.equal(
    verifyEntitlementEnvelope(second.entitlement, { k1: keys.publicKeyBase64Url }).grant.eid,
    verified.grant.eid,
  );
});

test('pending purchase is NOT acknowledged and NOT granted active access', async () => {
  const playApi = makeFakePlayApi({
    [RAW_TOKEN]: makeSubV2({ state: 'SUBSCRIPTION_STATE_PENDING', acknowledged: false }),
  });
  const { service, keys } = makeService({ playApi });

  const result = await service.verifyPurchase({
    packageName: DEFAULT_PACKAGE_NAME,
    productId: 'deckos_pro_monthly',
    purchaseToken: RAW_TOKEN,
    obfuscatedAccountId: 'dos_0123456789abcdef0123456789abcdef',
  });

  assert.equal(result.ok, true);
  assert.equal(playApi.acknowledgedCalls.length, 0);
  const { grant } = verifyEntitlementEnvelope(result.entitlement, {
    k1: keys.publicKeyBase64Url,
  });
  assert.equal(grant.state, 'pending');
  assert.equal(grant.ack, false);
});

test('grace period, account hold, paused, canceled-active, expired, and revoked normalize accurately', () => {
  assert.equal(
    normalizeSubscriptionV2(makeSubV2({ state: 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD' }), BASE_TIME_MS).state,
    'inGracePeriod',
  );
  assert.equal(
    normalizeSubscriptionV2(makeSubV2({ state: 'SUBSCRIPTION_STATE_ON_HOLD' }), BASE_TIME_MS).state,
    'onHold',
  );
  assert.equal(
    normalizeSubscriptionV2(makeSubV2({ state: 'SUBSCRIPTION_STATE_PAUSED' }), BASE_TIME_MS).state,
    'paused',
  );
  assert.equal(
    normalizeSubscriptionV2(
      makeSubV2({ state: 'SUBSCRIPTION_STATE_CANCELED', autoRenew: false }),
      BASE_TIME_MS,
    ).state,
    'canceledActive',
  );
  assert.equal(
    normalizeSubscriptionV2(
      makeSubV2({ state: 'SUBSCRIPTION_STATE_ACTIVE', expiryMs: BASE_TIME_MS - 1000 }),
      BASE_TIME_MS,
    ).state,
    'expired',
  );
  assert.equal(
    normalizeSubscriptionV2(
      makeSubV2({
        state: 'SUBSCRIPTION_STATE_EXPIRED',
        expiryMs: BASE_TIME_MS - 1000,
        developerInitiatedCancellation: {},
      }),
      BASE_TIME_MS,
    ).state,
    'revoked',
  );
});

test('rejects wrong package name and conflicting account replay', async () => {
  const playApi = makeFakePlayApi({
    [RAW_TOKEN]: makeSubV2({
      acknowledged: true,
      obfuscatedExternalAccountId: 'dos_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    }),
  });
  const { service } = makeService({ playApi });

  const wrongPkg = await service.verifyPurchase({
    packageName: 'com.attacker.clone',
    productId: 'deckos_pro_monthly',
    purchaseToken: RAW_TOKEN,
    obfuscatedAccountId: 'dos_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });
  assert.equal(wrongPkg.ok, false);
  assert.equal(wrongPkg.statusCode, 403);

  const first = await service.verifyPurchase({
    packageName: DEFAULT_PACKAGE_NAME,
    productId: 'deckos_pro_monthly',
    purchaseToken: RAW_TOKEN,
    obfuscatedAccountId: 'dos_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  });
  assert.equal(first.ok, true);

  const replayOtherAccount = await service.verifyPurchase({
    packageName: DEFAULT_PACKAGE_NAME,
    productId: 'deckos_pro_monthly',
    purchaseToken: RAW_TOKEN,
    obfuscatedAccountId: 'dos_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  });
  assert.equal(replayOtherAccount.ok, false);
  assert.equal(replayOtherAccount.code, 'account_binding_mismatch');
});

test('RTDN push requires Pub/Sub auth, deduplicates messageId, and updates state on revoke/hold/renew', async () => {
  const logs = [];
  const playApi = makeFakePlayApi({
    [RAW_TOKEN]: makeSubV2({ acknowledged: true }),
  });
  const { service, keys, store } = makeService({ playApi, logs });
  const accountId = 'dos_0123456789abcdef0123456789abcdef';

  const initial = await service.verifyPurchase({
    packageName: DEFAULT_PACKAGE_NAME,
    productId: 'deckos_pro_monthly',
    purchaseToken: RAW_TOKEN,
    obfuscatedAccountId: accountId,
  });
  const eid = verifyEntitlementEnvelope(initial.entitlement, {
    k1: keys.publicKeyBase64Url,
  }).grant.eid;

  const makePubSubBody = (messageId, notificationType, eventTimeMillis) => ({
    message: {
      messageId,
      data: Buffer.from(
        JSON.stringify({
          version: '1.0',
          packageName: DEFAULT_PACKAGE_NAME,
          eventTimeMillis: String(eventTimeMillis),
          subscriptionNotification: {
            version: '1.0',
            notificationType,
            purchaseToken: RAW_TOKEN,
            subscriptionId: 'deckos_pro_monthly',
          },
        }),
      ).toString('base64'),
    },
  });

  // Unauthenticated webhook is rejected
  const unauth = await service.handleRtdnPush({
    authorizationHeader: 'Bearer forged',
    body: makePubSubBody('msg-1', 12, BASE_TIME_MS + 1000),
  });
  assert.equal(unauth.ok, false);
  assert.equal(unauth.statusCode, 401);

  // Account hold notification (type 5)
  playApi.resources.set(
    RAW_TOKEN,
    makeSubV2({ state: 'SUBSCRIPTION_STATE_ON_HOLD', acknowledged: true }),
  );
  const holdRes = await service.handleRtdnPush({
    authorizationHeader: 'Bearer valid-pubsub-oidc',
    body: makePubSubBody('msg-hold', 5, BASE_TIME_MS + 2000),
  });
  assert.equal(holdRes.ok, true);
  assert.equal(holdRes.state, 'onHold');

  // Duplicate Pub/Sub delivery is idempotent
  const dup = await service.handleRtdnPush({
    authorizationHeader: 'Bearer valid-pubsub-oidc',
    body: makePubSubBody('msg-hold', 5, BASE_TIME_MS + 2000),
  });
  assert.equal(dup.ok, true);
  assert.equal(dup.duplicate, true);

  // Revocation (type 12) immediately revokes
  playApi.resources.set(
    RAW_TOKEN,
    makeSubV2({
      state: 'SUBSCRIPTION_STATE_EXPIRED',
      expiryMs: BASE_TIME_MS - 1000,
      acknowledged: true,
      developerInitiatedCancellation: {},
    }),
  );
  const revokeRes = await service.handleRtdnPush({
    authorizationHeader: 'Bearer valid-pubsub-oidc',
    body: makePubSubBody('msg-revoke', 12, BASE_TIME_MS + 3000),
  });
  assert.equal(revokeRes.ok, true);
  assert.equal(revokeRes.state, 'revoked');

  // Refreshing by opaque entitlementId returns the revoked state
  const refreshed = await service.refreshEntitlement({
    packageName: DEFAULT_PACKAGE_NAME,
    entitlementId: eid,
    obfuscatedAccountId: accountId,
  });
  assert.equal(refreshed.ok, true);
  assert.equal(
    verifyEntitlementEnvelope(refreshed.entitlement, {
      k1: keys.publicKeyBase64Url,
    }).grant.state,
    'revoked',
  );
  assert.equal(logs.join('\n').includes(RAW_TOKEN), false);
  const rec = await store.getByTokenHash(
    hashPurchaseToken(RAW_TOKEN, 'test-hmac-secret-never-ship-in-apk'),
  );
  assert.equal(rec.state, 'revoked');
});

test('HTTP server rejects query strings on POST and serves /v1/billing/verify cleanly', async () => {
  const playApi = makeFakePlayApi({
    [RAW_TOKEN]: makeSubV2({ acknowledged: true }),
  });
  const { service } = makeService({ playApi });
  const server = createBillingHttpServer(service);

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const { port } = server.address();
  try {
    // Reject query string carrying token
    const badQuery = await fetch(
      `http://127.0.0.1:${port}/v1/billing/verify?purchaseToken=${RAW_TOKEN}`,
      {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({}),
      },
    );
    assert.equal(badQuery.status, 400);

    // Valid POST JSON body succeeds
    const good = await fetch(`http://127.0.0.1:${port}/v1/billing/verify`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        packageName: DEFAULT_PACKAGE_NAME,
        productId: 'deckos_pro_monthly',
        purchaseToken: RAW_TOKEN,
        obfuscatedAccountId: 'dos_0123456789abcdef0123456789abcdef',
      }),
    });
    assert.equal(good.status, 200);
    const json = await good.json();
    assert.ok(json.entitlement?.sig);
    assert.equal(JSON.stringify(json).includes(RAW_TOKEN), false);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});


test('production entrypoint refuses even fully populated environment placeholders', () => {
  const vars = ['PLAY_SERVICE_ACCOUNT_EMAIL', 'PLAY_SERVICE_ACCOUNT_PRIVATE_KEY',
    'ENTITLEMENT_SIGNING_PRIVATE_KEY', 'ENTITLEMENT_SIGNING_KEY_ID',
    'PURCHASE_TOKEN_HMAC_SECRET', 'RTDN_BEARER_VERIFICATION_MODE'];
  const env = { ...process.env, NODE_ENV: 'production' };
  for (const name of vars) env[name] = 'fixture-not-a-real-secret';
  const child = spawnSync(process.execPath, [new URL('../src/server.mjs', import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')], { env, encoding: 'utf8', timeout: 5000 });
  assert.equal(child.status, 1);
  assert.match(child.stderr, /template cannot start/);
  assert.doesNotMatch(child.stderr, /fixture-not-a-real-secret/);
});

test('first claim, missing Google binding, product substitution and reinstall transfer fail before acknowledgement', async () => {
  for (const patch of [
    { obfuscatedExternalAccountId: 'dos_another_installation_0123456789' },
    { obfuscatedExternalAccountId: null },
    { productId: 'other_product' },
  ]) {
    const playApi = makeFakePlayApi({ [RAW_TOKEN]: makeSubV2(patch) });
    const { service, store } = makeService({ playApi });
    const result = await service.verifyPurchase({ packageName: DEFAULT_PACKAGE_NAME,
      productId: 'deckos_pro_monthly', purchaseToken: RAW_TOKEN,
      obfuscatedAccountId: 'dos_0123456789abcdef0123456789abcdef' });
    assert.equal(result.statusCode, 403);
    assert.equal(playApi.acknowledgedCalls.length, 0);
    assert.equal(await store.getByTokenHash(hashPurchaseToken(RAW_TOKEN, 'test-hmac-secret-never-ship-in-apk')), null);
  }
});

test('expired and failed acknowledgement cannot produce acknowledged active grants; refresh binds owner', async () => {
  const playApi = makeFakePlayApi({ [RAW_TOKEN]: makeSubV2({ expiryMs: BASE_TIME_MS - 1 }) });
  const { service, keys } = makeService({ playApi });
  const body = { packageName: DEFAULT_PACKAGE_NAME, productId: 'deckos_pro_monthly',
    purchaseToken: RAW_TOKEN, obfuscatedAccountId: 'dos_0123456789abcdef0123456789abcdef' };
  const expired = await service.verifyPurchase(body);
  const grant = verifyEntitlementEnvelope(expired.entitlement, { k1: keys.publicKeyBase64Url }).grant;
  assert.equal(grant.state, 'expired');
  assert.equal(grant.ack, false);
  assert.equal(playApi.acknowledgedCalls.length, 0);
  const wrongOwner = await service.refreshEntitlement({ ...body, entitlementId: grant.eid,
    obfuscatedAccountId: 'dos_another_installation_0123456789' });
  assert.equal(wrongOwner.statusCode, 403);
  playApi.resources.set(RAW_TOKEN, makeSubV2());
  playApi.acknowledgeSubscription = async () => { throw new Error(RAW_TOKEN); };
  const failed = await service.verifyPurchase(body);
  assert.equal(failed.code, 'acknowledgement_failed');
  assert.equal(failed.entitlement, undefined);
});

test('HTTP malformed JSON, nonobjects, bounded bodies, adapter/OIDC exceptions return safe errors and process survives', async () => {
  const throwing = async () => { throw new Error(RAW_TOKEN); };
  const server = createBillingHttpServer({ verifyPurchase: throwing, refreshEntitlement: throwing, handleRtdnPush: throwing });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    for (const [body, expected] of [['{', 400], ['null', 400], ['[]', 400], ['"x"', 400], [JSON.stringify({ data: 'x'.repeat(65536) }), 413], ['{}', 503]]) {
      const response = await fetch(`${base}/v1/billing/verify`, { method: 'POST', body });
      assert.equal(response.status, expected);
      assert.equal((await response.text()).includes(RAW_TOKEN), false);
    }
    const rtdn = await fetch(`${base}/v1/billing/rtdn`, { method: 'POST', body: '{}' });
    assert.equal(rtdn.status, 503);
    assert.equal((await fetch(`${base}/healthz`)).status, 200);
  } finally { await new Promise(resolve => server.close(resolve)); }
});

test('Play RPC uses finite cancellation and refuses redirect token forwarding', async () => {
  const keys = (await import('node:crypto')).generateKeyPairSync('rsa', { modulusLength: 2048 });
  let calls = 0;
  const client = new GooglePlayDeveloperClient({ serviceAccountEmail: 'fixture@example.invalid',
    serviceAccountPrivateKeyPem: keys.privateKey, rpcTimeoutMs: 10,
    fetchImpl: async (url, options) => {
      calls++;
      assert.equal(options.redirect, 'error');
      assert.ok(options.signal);
      return await new Promise((resolve, reject) => {
        options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
        // Keep the test process alive; AbortSignal's own timer is unreferenced.
        setTimeout(resolve, 40);
      });
    } });
  await assert.rejects(client.getSubscriptionV2({ packageName: DEFAULT_PACKAGE_NAME, purchaseToken: RAW_TOKEN }), /timeout/i);
  assert.equal(calls, 1);
});
