# DeckOS subscriptions: combined candidate 12

Prepared 24 November 2026. Publisher: **Bytetrix**; support/privacy: **contact@kavin.sh**. Package: `io.github.itskavin.deckos`.

**Unconfigured, not deployed and not upload-ready.** Pricing, production product IDs, trials and Free-vs-Pro boundaries remain deferred. No Play products, paid cloud accounts or actual charges were created. All existing features remain available; no false Pro entitlement is granted.

## Included implementation

Settings opens a localized Subscription page. Its default `BillingConfig.unconfigured` has no product IDs, verification URL, public keys or enforced gates. It displays unavailable status, with no fabricated prices/trials, and can open Google's subscription management page. The controller invokes no BillingClient connection, billing ID creation or verifier network call in this state. Security/privacy controls can never be gated by the entitlement policy.

The official Flutter `in_app_purchase` 3.3.1 / `in_app_purchase_android` 0.5.5 adapter includes Play Billing 9.1.0. Configured catalogs use real Play ProductDetails prices/offer phases, no preselected plan, same-currency annual savings only, recurring terms and cancellation information. Actual Play checkout has not been tested.

Google's [Billing deprecation schedule](https://developer.android.com/google/play/billing/deprecation-faq), checked 24 November 2026, lists Billing 7's final extension deadline as 1 November 2026; Billing 8/9 remain supported until their 2027/2028 deadlines. The final merged manifest must retain `com.google.android.play.billingclient.version`. [Integration guidance](https://developer.android.com/google/play/billing/integrate) describes verification and timely acknowledgement. Pending transactions never grant access or get acknowledged. The template acknowledges eligible verified active/grace/canceled-active purchases server-side; the app completes purchases only following valid verification.

## Trust and storage

The companion is user controlled and never a license authority. No Google service-account or entitlement-signing private key ships in the APK or companion. A future trusted service uses subscriptionsv2.get, then signs `kid.payloadBase64Url` with Ed25519. The app delegates verification to maintained `cryptography` **2.9.0**, with small-order encoding checks and no application curve arithmetic. Node-to-Dart canonical-payload interoperability is tested.

Signed grants are verified asynchronously before acceptance/cache load; synchronous UI getters use only the accepted verified state, with package, product, installation, acknowledgement and expiry checks. Cache validity is 72 hours by default, bounded from the signed issuance time and clamped to seven days. Android storage uses a Keystore-protected key with no plaintext fallback; real-device migration is pending. No hardware-backed guarantee is made.

A future configured endpoint is a compile-time owner setting, never discovered/user-entered. It requires an HTTPS DNS name without credentials/query/fragment/nonstandard port. Native connections resolve once, reject private/reserved DNS results, connect to that result and perform normal CA/original-hostname TLS verification. Redirects are disabled. Tokens go only in POST JSON bodies; responses are bounded and errors avoid raw tokens. PC pins/credentials are never reused. Non-Android purchase UI is unsupported; browser transport is not production billing support.

## Ownership and restore limits

There is no DeckOS cloud login. A configured installation creates an opaque random ID for Play checkout, stored locally; this is linkable data, not guaranteed anonymous/non-personal data. Verification requires the ID reported by Google at checkout and any stored owner to match, including on first claim. A token alone does not prove the caller's Google account. Same-install restore is fixture-tested. **Reinstall/new-device transfer is blocked** when the ID changes; durable ownership and authenticated recovery must be designed and tested before production. Local PC accounts do not authenticate cloud ownership. No recovery bypass is supplied.

## Verifier template production boundary

`services/billing-verifier` is a reference implementation with fixture tests. `npm start` intentionally exits nonzero even with all historical environment variables populated. There is no production launcher. Its in-memory store and injected fixture auth are not durable storage or real OIDC verification.

Production needs encrypted durable transactional ownership (unique constraints, concurrency and atomic RTDN deduplication/state updates), authenticated reinstall recovery, explicit product allowlist, rate limiting, real Google Pub/Sub OIDC signature/issuer/audience/expiry/email validation, secrets management and reviewed HTTPS ingress. Google RPCs have finite cancellation and reject redirects; HTTP bodies are bounded and adapter exceptions become safe errors. No infrastructure, endpoint, account, key or database is provisioned. The default server product allowlist is empty.

## Privacy and final launch gates

The offline privacy notice and Data safety inventory disclose Billing SDK presence now, separately from future enabled flows. Unconfigured DeckOS does not create/send billing IDs/tokens. Google management opens externally under Google's policies; no claim is made that SDK internals collect no personal information. When enabled, product IDs, purchase tokens, opaque IDs and lifecycle state would support verification/fraud prevention, with signed grants cached locally. Durable encrypted server token retention, deletion and recovery policy are not implemented. Google's payment-service exception does not exempt developer-held purchase history. The untracked public policy draft remains unpublished.

Before enabling purchases: finalize deferred pricing/gates; create real Play subscription/base-plan configuration; provision and independently review backend/OIDC/durable ownership/recovery; embed public verification keys; reconcile disclosures with actual SDK/server flows; test real license-tester purchases, acknowledgement, renewal, cancellation, pending/grace/hold, restore/recovery and revocation. Also complete physical TLS/Keystore migration, 16KB Android runtime QA, reviewer access, account eligibility and off-machine upload-key backup. Do not create prices or infrastructure merely to close these gates.

Tests cover signatures/tampering/noncanonical/small-order points, forged/error/unconfigured grants, account/product/expiry limits, redirect/private-DNS rejection, HTTP failures and template startup refusal. They use fixtures/isolated servers; they do not establish live Google billing, deployed RTDN or physical phone acceptance.
