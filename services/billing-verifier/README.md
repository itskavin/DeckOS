# DeckOS Billing Verification Service (Template)

Trusted server-side Google Play subscription verifier, RTDN Pub/Sub push handler, and Ed25519 entitlement signer for **DeckOS** (`io.github.itskavin.deckos`, publisher **Bytetrix**, support `contact@kavin.sh`).

**Status:** Unconfigured reference implementation & test suite. **Not deployed.** No cloud account, GCP service account, Play Console SKU, or production signing key has been provisioned.

## Why a separate trusted backend is required

DeckOS's desktop companion runs on the user's own PC, so it is **not** a trusted license authority:

- Never bundle Google Play Developer API service-account JSON into the Android APK or the PC companion.
- Never grant persistent Pro access from a client boolean, `SharedPreferences` flag, or a local PC response.
- Never reuse local PC pairing credentials or LAN TLS pins as cloud billing authentication.

Instead:

1. The Android app completes Play checkout using Google Play Billing (`in_app_purchase`) and submits `{ packageName, productId, purchaseToken, obfuscatedAccountId }` over **HTTPS POST JSON** to `/v1/billing/verify` (never in query strings).
2. This service authenticates to Google Play Developer API v3 via a backend-only GCP service account and calls `purchases.subscriptionsv2.get` as the authoritative source of truth.
3. For verified active/grace purchases with `ACKNOWLEDGEMENT_STATE_PENDING`, this service calls `purchases.subscriptions.acknowledge` within Google Play's **3-day window** (5 minutes for license testers). `PENDING`, `ON_HOLD`, `PAUSED`, `EXPIRED`, and `REVOKED` purchases are **never** acknowledged.
4. This service stores state keyed by an HMAC-SHA256 hash of `purchaseToken` (never logging or returning plaintext tokens) and issues an **Ed25519-signed entitlement envelope** (`{ kid, payload, sig }`) with a bounded `offlineValidUntil` timestamp.
5. The Android app embeds **only the 32-byte Ed25519 public key** (`BillingConfig.entitlementPublicKeys`), verifying signatures locally via `app/lib/src/billing/ed25519_verifier.dart`.
6. In the intended production design, Google Play **Real-time Developer Notifications (RTDN)** are pushed via Google Cloud Pub/Sub to `/v1/billing/rtdn` with an as-yet-unimplemented Pub/Sub OIDC verifier, deduplicated by `messageId`, and always trigger a fresh `subscriptionsv2.get` check.

## Running local tests (no credentials or cloud accounts required)

```bash
cd services/billing-verifier
npm test
```

## Production deployment prerequisites (owner decision required)

1. Choose hosting (e.g., Cloud Run, Fly.io, Cloudflare Worker port, or VPS behind HTTPS TLS) and durable encrypted database replacing `InMemoryBillingRecordStore`.
2. Create GCP Service Account with Play Console **View financial data, orders, and cancellation survey responses** + **Manage orders and subscriptions** permissions linked to `io.github.itskavin.deckos`.
3. Create Google Cloud Pub/Sub topic, grant `google-play-developer-notifications@system.gserviceaccount.com` the **Pub/Sub Publisher** role, configure an authenticated push subscription with OIDC JWT verification pointing to `/v1/billing/rtdn`, and register the topic in Play Console → **Monetization setup**.
4. Generate an Ed25519 signing keypair in a secret manager, keep the private key strictly server-side, and configure the 32-byte base64url public key + `kid` in DeckOS `BillingConfig`.
5. Implement full Google OIDC JWT validation (`iss`, `aud`, `email_verified`, expected Pub/Sub push service account email) in `verifyPubSubAuth` before enabling `/v1/billing/rtdn` in production.


## Startup and ownership boundary

`npm start` always refuses to start. Setting `NODE_ENV=production` or historical secret/RTDN environment variables does not enable a server. This prevents accidental deployment with in-memory storage and fixture authentication. Importing `createBillingHttpServer(service)` is for local tests or a future reviewed launcher; it does not certify adapters.

Production requires encrypted durable transactional storage (unique ownership and atomic RTDN deduplication/state updates), authenticated account/reinstall recovery, explicit product allowlists, real Google Pub/Sub OIDC signature/issuer/audience/expiry/email validation, rate limiting, secrets management and reviewed HTTPS ingress. No production adapter, endpoint, account, database or cloud resource is provisioned. In-memory storage does not provide cross-process idempotency/recovery.

Verification rejects an ID differing from Google's checkout binding even on first claim, and rejects a conflicting stored owner. An opaque installation ID is linkable data, not user authentication. Token possession does not prove a caller's Google account; a reinstall with a new ID is rejected. Same-install restore is fixture-tested; cross-install recovery is a blocking design requirement. No cloud login/recovery bypass exists. Products must be explicitly allowlisted; the default allowlist is empty.

The app delegates Ed25519 to maintained `cryptography` 2.9.0. Tests use Node crypto for interoperability and fixtures for all Play/RTDN calls. Do not advertise this as production billing readiness.
