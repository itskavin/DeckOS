# Secure transport implementation handoff

**Production release blocker, not a warning-only fix.** This document scopes the next implementation; TLS is not implemented by release preparation.

## Existing behavior and entry points

- `DeckOS/Program.cs` defaults Kestrel to `http://0.0.0.0:4787`; environment/configuration can override URLs, but that does not make the default client secure.
- `DeckOS/Lib/PairingInfo.cs` encodes the long-lived pairing key, host and port in `deckos://pair?...`; it does not bind a server certificate or negotiate authenticated TLS.
- `app/lib/src/welcome/pairing.dart` strips `https://` from manual input and reconstructs `http://...`. Merely changing the server to HTTPS breaks or downgrades this route.
- `app/lib/src/connection/pc_store.dart` persists host/port/key and reconstructs HTTP. Splash, PC switching, discovery, connection config, and cached routes must migrate together.
- `app/lib/core/deckos_client/deckos_client.dart` sends the PC key on REST requests. `app/lib/src/services/signalr_service.dart` adds it to the SignalR URL and needs both secure negotiation and WebSocket trust validation.
- `app/lib/src/connection/usb_route.dart` probes a plain HTTP loopback route and can fall back to LAN. Neither fallback nor USB mode may silently weaken certificate validation.

## Recommended local-first design

Use a per-PC TLS key/certificate created locally by the companion, with the private key protected by Windows DPAPI or an appropriate platform credential store. Preserve the current local-first architecture; no public relay or new cloud account is required just to secure the LAN.

Introduce a versioned pairing QR containing the explicit HTTPS endpoint, a certificate/SPKI SHA-256 pin and a short-lived one-time pairing token. The phone verifies that pin before exchanging the token for its device credential. The physical QR is the trust bootstrap. Certificate rotation, a changed pin and manual pairing must require explicit verification/re-pairing, never an accept-any-certificate callback. Consider per-device revocable credentials rather than copying one global permanent key to every phone.

Store the endpoint scheme, verified pin and credential with each saved PC; migrate existing preferences without clearing data. Treat legacy HTTP devices as requiring secure re-pairing for remote production access. Discovery advertises capability/endpoint information without credentials; it cannot establish trust by itself.

Apply one endpoint-specific TLS policy to REST, SignalR negotiate, WebSocket upgrade/reconnect, image transfers and every retry route. `signalr_netcore` exposes a custom `HttpConnectionOptions.httpClient` and `ITransport`; its WebSocket construction needs inspection/adaptation in addition to the Dio adapter. A pinned REST client alone leaves the WebSocket path exposed. Never install a process-wide trust-all `HttpOverrides` workaround.

Keep browser configurator compatibility explicit: a loopback-only HTTP listener may serve the same-machine configurator, with strict source/origin/Host checks for privileged local bootstrap routes. Remote listeners must use TLS. A self-signed LAN web page requires a separate browser trust/onboarding decision; native pinning does not automatically trust the browser. Preserve local-key endpoint restrictions, CSRF/origin checks and authentication while separating listeners.

USB forwarding should carry the same authenticated TLS connection, using the expected PC pin despite the forwarded loopback address, or have an explicitly reviewed direct local transport design. A failed USB route must never downgrade to cleartext LAN. Once routes are migrated, deny remote cleartext in production Android network security configuration.

This is the smallest coherent default-transport fix. Disabling optional credential entry alone does not secure the pairing key on every request. User-configured HTTPS alone also does not solve the hard-coded HTTP clients, certificate trust bootstrap or fallback paths.

## Acceptance evidence

Verify fresh pairing, manual verification, existing-PC migration, PC switching, discovery, REST, SignalR initial connection/reconnect, image upload, and USB-to-LAN transitions. Wrong pins, changed certificates, expired tokens and replayed tokens must fail before credentials leave the phone. Confirm packet capture has no HTTP/ws authentication/configuration plaintext and sensitive URLs never appear in logs. Test a real Android device against a real Windows companion without resetting existing profiles or user data. Then update privacy text, rebuild the AAB and run release/16KB checks again.
