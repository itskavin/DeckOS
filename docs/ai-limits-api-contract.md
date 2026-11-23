# DeckOS AI Limits Backend API & SignalR Contract (v1)

> **Status:** Locked v1 contract for parallel backend (.NET 8) and frontend (Flutter) implementation.
> **Security & Account-Safety Baseline:** Official-supported local interfaces and strictly passive local/proxy observation only. No active undocumented provider quota polling, no OAuth token refresh/mutation, no browser-cookie extraction, no client/User-Agent spoofing, no live inference or `/credentials/verify` probes, and no cap-bypass account rotation.

## Authentication & Transport

- **REST Base Path:** `/api/ai-limits`
- **Authentication:** Standard DeckOS `ApiKey` authentication (`X-API-KEY` header or `Authorization: Bearer <key>`), identical to all other `/api/*` endpoints.
- **JSON Casing:** `camelCase` (`JsonNamingPolicy.CamelCase`, case-insensitive on input).
- **SignalR Hub:** `/deckHub`
  - **Event Name:** `ReceiveAiLimitsState`
  - **Payload:** Exact same JSON object as `GET /api/ai-limits` (`AiLimitsSnapshotResponse`).
  - Sent automatically on `DeckHub.OnConnectedAsync()` and pushed whenever sources, accounts, or quota observations change.
- **Zero-Secret Guarantee:**
  - Credentials (e.g., CLIProxyAPI management key) are sent once over DeckOS's authenticated channel on `POST`/`PUT` and stored locally via `SecretFile` (Windows DPAPI / macOS & Linux `0600`).
  - `GET` responses, SignalR events, logs, `DeckProfile` JSON, and `.deckos` backups **never** contain credentials, OAuth tokens, raw `id_token`, raw emails, or auth filenames.
  - All account IDs (`acct_<hex>`) and source IDs (`src_<hex>`) are stable, opaque identifiers.

---

## Supported Source Kinds (Verified Cross-Platform Win/macOS/Linux)

| `kind` | `accessMode` / `supportLevel` | `coverageScope` | `requiresCredential` | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `codex_local` | `official_local_rpc` (fallback: `passive_local_file`) | `account_wide_live` (fallback: `account_wide_last_local_turn`) | `false` | Official `codex -s read-only -a never app-server` over stdio (`initialize` → `initialized` → `account/rateLimits/read` with `excludeResetCreditDetails: true`, zero inference), with automatic passive `~/.codex/sessions/**/*.jsonl` fallback. One account per source; multi-account via separate `CODEX_HOME` (`configDir`). |
| `claude_statusline` | `official_local_hook` | `account_wide_last_local_turn` | `false` | Official Claude Code `statusLine` stdin `rate_limits` passive local snapshot file (zero extra API calls, never reads `.credentials.json`). Includes guided non-destructive hook wrapper setup preserving existing `statusLine`. |
| `cliproxy_passive` | `passive_local_proxy` | `proxy_observed_only` | `true` | Read-only `GET /v8/management/credentials` (fallback `GET /v0/management/auth-files`) against a user's existing local CLIProxyAPI. Reads only already-captured passive `quota.signals`, `model_quotas`, and `cooldowns` (Claude & Codex). Never invokes `/api-call` or `/credentials/verify`; never modifies proxy config. Empty signals remain `unavailable`, never `0%`. |
| `gemini_local_otel` | `passive_local_file` | `local_device_activity_only` | `false` | Passive reader for Gemini CLI official local OpenTelemetry `outfile` (`GEMINI_TELEMETRY_ENABLED=true`). Reports the local request count since 00:00 UTC only (`remainingPercent: null`, `resetsAt: null`); never fabricates 5h/weekly bars or a reset time. |
| `manual_dashboard` | `manual_dashboard` | `none` | `false` | Honest fallback tile for subscriptions without a safe official quota API (Antigravity, Gemini Web, Cursor Personal, Windsurf Personal, Copilot Personal, etc.) with official dashboard deep-link. |

> **Excluded by policy (verified by source audit):** Active undocumented consumer polling (`api.anthropic.com/api/oauth/usage`, `chatgpt.com/backend-api/wham/usage`, `retrieveUserQuota*`, `copilot_internal/user`), CLIProxyAPI `POST /api-call`, `/credentials/verify`, `/download`, `/refresh`, browser-cookie tools (`coding-limits`), `shuvquota-server` (`GET /api/quota` triggers live undocumented upstream polls with spoofed headers on 10s cache miss), and GPL-3.0 `onWatch` (background agents actively poll undocumented endpoints, rotate Codex OAuth files, and include prompt-sending quota-starters).
>
> **Upstream Protocol Reuse & MIT Attribution:**
> - `router-for-me/CLIProxyAPI` (MIT, `v8.0.48` / `6eb8554f`): Verified passive `GET /v8/management/credentials` + `/v0/management/auth-files` schemas, Claude 0–1 utilization scaling, Codex 0–100 + model-pool headers, Devin remaining-% inversion, `[]CooldownView` array schema, and 1st-401/403 auth circuit breaker + rejected-key guard protecting against CPA's 5-strike 30-minute IP ban.
> - `steipete/CodexBar` (MIT, `a26ca57b`): Adopted duration-based Codex window normalization (including ChatGPT Pro single `10080`-min `primary` re-slotting to `weekly` + `five_hour: not_applicable`) and defensive camelCase/snake_case RPC decoding.
> - `Maciek-roboblog/Claude-Code-Usage-Monitor` (MIT, `c59a83bf`): Adopted Claude Code bug `#52326` `>101` epoch-leak guard, expired-window staleness (never auto-zeroing), atomic temp-file writes, and plan-downgrade `rate_limits: null` tombstones.
> - `shuv1337/shuvquota` (MIT, `709d2db8`): Adopted constructive allowlist DTO rebuilding and control-character text sanitization (`SanitizeText`).

---

## Enumerations (String Values)

- **`source.kind` / `account.sourceKind`**:
  `"cliproxy_passive"` | `"codex_local"` | `"claude_statusline"` | `"gemini_local_otel"` | `"manual_dashboard"`
- **`accessMode` / `supportLevel`**:
  `"official_local_rpc"` | `"official_local_hook"` | `"passive_local_file"` | `"passive_local_proxy"` | `"manual_dashboard"`
- **`coverageScope`**:
  `"account_wide_live"` | `"account_wide_last_local_turn"` | `"proxy_observed_only"` | `"local_device_activity_only"` | `"none"`
- **`source.status`**:
  `"connected"` | `"degraded"` | `"awaiting_data"` | `"auth_required"` | `"rate_limited"` | `"offline"` | `"disabled"` | `"setup_required"` | `"error"`
- **`account.provider`**:
  `"claude"` | `"codex"` | `"gemini_cli"` | `"antigravity"` | `"gemini_web"` | `"copilot"` | `"cursor"` | `"windsurf"` | `"devin"` | `"other"`
- **`account.connectionStatus`**:
  `"connected"` | `"disabled"` | `"unavailable"` | `"auth_required"` | `"offline"` | `"setup_required"`
- **`account.quotaStatus`**:
  `"ok"` | `"stale"` | `"rate_limited"` | `"cooldown"` | `"awaiting_data"` | `"unavailable"` | `"auth_required"` | `"manual_only"` | `"local_only"`
- **`account.freshness`**:
  `"fresh"` | `"stale"` | `"local_only"` | `"manual_only"` | `"unavailable"`
- **`window.kind`**:
  `"five_hour"` | `"weekly"` | `"daily"` | `"monthly"` | `"spend_limit"` | `"credits"` | `"custom"`
- **`window.unit`**:
  `"percent"` | `"requests"` | `"credits"` | `"usd"` | `"tokens"` | `"none"`
- **`window.status`**:
  `"available"` | `"not_applicable"` | `"unavailable"` | `"stale"` | `"rate_limited"` | `"auth_required"` | `"not_connected"`
- **`errorCode`** (nullable):
  `"auth_failed"` | `"rate_limited"` | `"cooldown_active"` | `"unreachable"` | `"invalid_url"` | `"non_loopback_blocked"` | `"redirect_blocked"` | `"response_too_large"` | `"cli_not_found"` | `"hook_not_installed"` | `"no_data_yet"` | `"unsupported_version"` | `"local_only_action"` | `"timeout"` | `"internal_error"`

---

## REST Endpoints

### 1. `GET /api/ai-limits`
Returns the full sanitized `AiLimitsSnapshotResponse`.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2026-11-23T06:20:00Z",
  "capabilities": {
    "platform": "windows",
    "claudeStatusLineInstallerAvailable": true,
    "detected": {
      "cliProxySuggestedUrl": "http://127.0.0.1:8317",
      "cliProxyReachable": true,
      "codexCliAvailable": true,
      "codexDefaultHomeExists": true,
      "claudeCliAvailable": true,
      "claudeConfigDirExists": true,
      "claudeStatusLineConfigured": false,
      "geminiDirExists": true
    },
    "supportedSourceKinds": [
      {
        "kind": "cliproxy_passive",
        "title": "CLIProxyAPI (Passive Local)",
        "description": "Reads already-captured passive rate-limit headers and cooldowns from your local CLIProxyAPI without triggering upstream requests.",
        "accessMode": "passive_local_proxy",
        "requiresCredential": true,
        "supportsMultiAccount": true,
        "supportsGuidedSetup": false,
        "supportsTestConnection": true,
        "provenanceNote": "DeckOS only reads passive local proxy metadata and never sends upstream probes or changes proxy settings. CLIProxyAPI itself is a separate user-run tool with independent provider policy considerations."
      }
    ]
  },
  "refresh": {
    "cooldownSeconds": 15,
    "nextRefreshAllowedAt": null,
    "autoRefreshIntervalSeconds": 180,
    "isRefreshing": false
  },
  "sources": [
    {
      "id": "src_8a91c2d4e5f6",
      "kind": "cliproxy_passive",
      "label": "Local CLIProxyAPI",
      "enabled": true,
      "accessMode": "passive_local_proxy",
      "supportLevel": "passive_local_proxy",
      "hasCredential": true,
      "baseUrl": "http://127.0.0.1:8317",
      "allowNonLoopback": false,
      "configDir": null,
      "snapshotFile": null,
      "codexMode": null,
      "provider": null,
      "planLabel": null,
      "dashboardUrl": null,
      "dailyLimitHint": null,
      "pollIntervalSeconds": 180,
      "status": "connected",
      "errorCode": null,
      "statusMessage": "Connected via CLIProxyAPI v8 (passive metadata)",
      "detectedApiVersion": "v8",
      "lastCheckedAt": "2026-11-23T06:19:50Z",
      "lastSyncedAt": "2026-11-23T06:19:50Z",
      "backoffUntil": null,
      "retryAfterSeconds": null,
      "accountCount": 3
    }
  ],
  "accounts": [
    {
      "id": "acct_4f2a9b1c8d7e",
      "sourceId": "src_8a91c2d4e5f6",
      "sourceKind": "cliproxy_passive",
      "provider": "claude",
      "product": "claude_code",
      "providerLabel": "Claude",
      "alias": "Claude #1",
      "defaultAlias": "Claude #1",
      "plan": null,
      "modelPool": "all",
      "enabled": true,
      "connectionStatus": "connected",
      "quotaStatus": "ok",
      "freshness": "fresh",
      "supportLevel": "passive_local_proxy",
      "coverageScope": "proxy_observed_only",
      "provenanceLabel": "CLIProxyAPI · Passive",
      "provenanceDetails": "Captured passively from response headers routed through your local CLIProxyAPI. Reflects proxy traffic only; no extra upstream quota requests are made by DeckOS.",
      "observedAt": "2026-11-23T06:15:10Z",
      "staleAfterSeconds": 900,
      "cooldownUntil": null,
      "backoffUntil": null,
      "ordinaryUsageAllowed": true,
      "dashboardUrl": "https://claude.ai/settings/usage",
      "errorCode": null,
      "statusMessage": null,
      "windows": [
        {
          "id": "five_hour",
          "kind": "five_hour",
          "label": "5h Limit",
          "windowMinutes": 300,
          "unit": "percent",
          "status": "available",
          "usedPercent": 42.0,
          "remainingPercent": 58.0,
          "used": 42.0,
          "limit": 100.0,
          "resetsAt": "2026-11-23T09:00:00Z",
          "modelPool": "all",
          "ordinaryUsageAllowed": true,
          "note": null
        },
        {
          "id": "weekly",
          "kind": "weekly",
          "label": "Weekly",
          "windowMinutes": 10080,
          "unit": "percent",
          "status": "available",
          "usedPercent": 61.0,
          "remainingPercent": 39.0,
          "used": 61.0,
          "limit": 100.0,
          "resetsAt": "2026-11-28T00:00:00Z",
          "modelPool": "all",
          "ordinaryUsageAllowed": true,
          "note": null
        }
      ]
    }
  ]
}
```

### 2. `GET /api/ai-limits/sources`
Returns `AiLimitsSourceDto[]` (never includes secrets).

### 3. `POST /api/ai-limits/sources/test`
Tests a proposed or existing source configuration without persisting changes.
- **Request (`AiLimitsSourceTestRequest`):**
  ```json
  {
    "sourceId": null,
    "kind": "cliproxy_passive",
    "label": "Local CLIProxyAPI",
    "baseUrl": "http://127.0.0.1:8317",
    "allowNonLoopback": false,
    "credential": "<optional-one-time-secret>",
    "configDir": null,
    "snapshotFile": null,
    "codexMode": "rpc_with_log_fallback",
    "provider": null,
    "planLabel": null,
    "dashboardUrl": null,
    "dailyLimitHint": null
  }
  ```
  - If `sourceId` is supplied and `credential` is null/empty, the backend reuses the stored credential for that source.
- **Response (`200 OK`, `AiLimitsSourceTestResponse`):**
  ```json
  {
    "ok": true,
    "reachable": true,
    "status": "connected",
    "errorCode": null,
    "message": "Connected via CLIProxyAPI v8 (6 credentials found, 3 with passive quota signals).",
    "detectedApiVersion": "v8",
    "capabilitiesNote": "Passive headers available for Claude and Codex; other providers show unavailable until supported.",
    "accounts": [ /* sanitized AiLimitsAccountDto[] preview */ ]
  }
  ```

### 4. `POST /api/ai-limits/sources` & `PUT /api/ai-limits/sources/{sourceId}`
Creates or updates a source.
- **Request (`AiLimitsSourceUpsertRequest`):**
  Same fields as `AiLimitsSourceTestRequest` plus:
  - `enabled`: `bool` (default `true`)
  - `pollIntervalSeconds`: `int?` (clamped `60..3600`, default `180`)
  - `clearCredential`: `bool?` (on `PUT`: `true` clears stored secret; omitting/blank `credential` preserves existing stored secret)
- **Response:**
  - `POST`: `201 Created` with `{ "source": AiLimitsSourceDto, "accounts": AiLimitsAccountDto[], "snapshot": AiLimitsSnapshotResponse }`
  - `PUT`: `200 OK` with `{ "source": AiLimitsSourceDto, "accounts": AiLimitsAccountDto[], "snapshot": AiLimitsSnapshotResponse }`
  - `400 Bad Request` on invalid kind/URL/parameters with `{ "errorCode": "...", "message": "..." }`.
  - `403 Forbidden` (`errorCode: "local_only_action"`) if a non-local client attempts to specify custom PC filesystem paths (`configDir` / `snapshotFile`).

### 5. `DELETE /api/ai-limits/sources/{sourceId}`
Deletes the source from local DeckOS config and removes its local stored credential. Never modifies external proxy/CLI config or logs out any provider.
- **Response:** `200 OK` with `{ "deleted": true, "snapshot": AiLimitsSnapshotResponse }`.

### 6. `POST /api/ai-limits/refresh` & `POST /api/ai-limits/sources/{sourceId}/refresh`
Triggers a bounded, single-flight refresh (respecting global manual cooldown and per-source 429/401 backoff).
- **Optional Body on `/refresh`:** `{ "sourceId": "src_..." }`
- **Response:**
  - `200 OK`: `AiLimitsSnapshotResponse`
  - `429 Too Many Requests` (when within cooldown or backoff): includes `Retry-After` header and body:
    ```json
    {
      "errorCode": "cooldown_active",
      "message": "Please wait 12s before refreshing again.",
      "retryAfterSeconds": 12,
      "nextRefreshAllowedAt": "2026-11-23T06:20:15Z",
      "snapshot": { /* current cached AiLimitsSnapshotResponse */ }
    }
    ```

### 7. `GET /api/ai-limits/accounts`, `PATCH|PUT /api/ai-limits/accounts/{accountId}`, `DELETE /api/ai-limits/accounts/{accountId}`
Local-only account customization (never mutates upstream providers).
- **`PATCH` / `PUT` Request (`AiLimitsAccountUpdateRequest`):**
  ```json
  {
    "alias": "Work",
    "enabled": true,
    "plan": "Max",
    "dashboardUrl": "https://claude.ai/settings/usage"
  }
  ```
- **Response:** `200 OK` with `{ "account": AiLimitsAccountDto, "snapshot": AiLimitsSnapshotResponse }`.
- **`DELETE` Response:** `200 OK` with `{ "removed": true, "snapshot": AiLimitsSnapshotResponse }`. (Marks account locally hidden/removed in DeckOS config; does not delete upstream credentials. Existing deck tiles bound to that `accountId` gracefully show unavailable/reconnect.)

### 8. Official Guided Setup & Passive Ingest Helpers
- **`GET /api/ai-limits/sources/{sourceId}/setup`** -> `AiLimitsSetupGuideResponse`:
  ```json
  {
    "sourceId": "src_...",
    "kind": "claude_statusline",
    "supported": true,
    "isInstalled": false,
    "hasExistingUserHook": false,
    "canAutoInstall": true,
    "steps": [
      "Install the DeckOS statusLine wrapper or add the command below to Claude Code settings.json.",
      "Run any normal Claude Code turn; Claude Code automatically writes rate_limits to the local snapshot without extra API requests."
    ],
    "caveats": [
      "Updates only during active local Claude Code sessions.",
      "Configuring a custom statusLine hides some built-in Claude Code footer hints.",
      "Existing statusLine commands are preserved and chained."
    ],
    "commandPreview": "powershell -NoProfile -File C:/Users/.../deckos-claude-statusline.ps1"
  }
  ```
- **`POST /api/ai-limits/sources/{sourceId}/install-hook`** *(Local PC loopback only; `403 local_only_action` for remote clients)*:
  - Opt-in non-destructive `claude_statusline` wrapper installation. Backs up `settings.json`, preserves any existing `statusLine` command, uses forward-slash paths on Windows, returns updated `AiLimitsSetupGuideResponse`.
- **`POST /api/ai-limits/sources/{sourceId}/uninstall-hook`** *(Local PC loopback only)*:
  - Restores the preserved previous `statusLine` command (or removes DeckOS wrapper if none existed).
- **`POST /api/ai-limits/sources/{sourceId}/ingest`** *(Authenticated)*:
  - Passive snapshot ingest for `claude_statusline` (whitelists only `rate_limits` fields, ignores all workspace/transcript/session PII, updates snapshot atomically, broadcasts `ReceiveAiLimitsState`).

### 9. Backend safety semantics (v1, additive)

- **Auth circuit (all `requiresCredential` sources, i.e. `cliproxy_passive`):** the first `401`/`403` opens the circuit for that exact URL + credential. While it is open, DeckOS never sends that pair again: not on background polls, `POST /refresh`, `POST /sources/{id}/refresh`, `POST /sources/test` (with `sourceId` and no new `credential`), or a `PUT` that changes only label/poll interval. Only a `PUT` that changes `credential`, `baseUrl`, `allowNonLoopback` or sets `clearCredential` makes one new attempt. A blocked call returns normally with source `status: "auth_required"`, `errorCode: "auth_failed"`. Local official sources (`codex_local` sign-in errors) skip background retries, but an explicit manual refresh may try again (no lockout risk).
- **Per-endpoint failure budget:** CLIProxyAPI bans an IP for 30 min after 5 failed management-key attempts. DeckOS allows at most **2 rejected attempts per proxy `host:port` per 35 minutes**, whatever key is used. A key that was rejected is not sent again for 35 minutes, even if it is re-entered. All requests to one proxy endpoint are single-flight. The v0 route is tried only after a v8 `404`, never after `401`/`403`.
- **Retry-After / backoff:** a `429` (with `Retry-After`, capped at 30 min, ±15% jitter) or `5xx`/timeout puts the source in backoff. `POST /api/ai-limits/sources/{id}/refresh` during backoff returns **`429 cooldown_active`** with the remaining `retryAfterSeconds`, without contacting the source. Global `POST /refresh` skips sources in backoff.
- **Unknown capture time:** a CLIProxyAPI credential without `quota.observed_at` shows its windows as `stale` (`note: "Capture time unknown"`), never fresh.
- **Invalid percentages:** NaN, negative, or `> 101` for Claude-style values give `status: "unavailable"` with `usedPercent: null` (`note: "Invalid reading ignored"`). Codex values above 100 (documented as over-limit) show as `100`.
- **Codex accounts:** one account per `codex_local` source, with a stable `accountId` shared by the RPC and session-log fallback. Extra `rateLimitsByLimitId` buckets (for example `codex_bengalfox` / "GPT-5.3-Codex-Spark") are extra **windows** with ids like `pool:codex_bengalfox:five_hour` and `modelPool` set to the bucket's `limitName`. The main pool has `modelPool: "all"`. A missing 5h window is `not_applicable` only for Pro-family plans (`pro`, `prolite`, `promax`) or when the primary window is weekly-length; otherwise it is `unavailable` ("Not reported by Codex"). A `credits` window carries only a balance note (`limit: null`, no percentage).
- **Window ids are unique per account.** Clients should pick at most one window per preferred `kind`, preferring `modelPool == "all"` (or null).
- **`AiLimitsSetupGuideResponse.errorCode` / `.message`** (nullable): set when DeckOS refused a setup action. For example, `install-hook` returns `200 { setup: { errorCode: "internal_error", message: "…" }, snapshot }` and leaves `settings.json` untouched when it is not plain JSON (comments, trailing commas). `canAutoInstall` is `false` on macOS/Linux when no usable `python3` is present.
- **Claude statusLine wrapper:** with an existing user `statusLine`, the installed command is `<deckos capture> -PassThru | <previous command>` (`--passthru` on POSIX). Claude Code's stdin passes through unchanged, so the previous command runs in the shell Claude Code chose (Git Bash or PowerShell on Windows). Other `statusLine` fields (`padding`, `refreshInterval`) are kept, and uninstall restores the original entry exactly. Only `rate_limits.{five_hour,seven_day,spend_limit}` fields are stored. A payload with no `rate_limits` clears the snapshot only after the session has made an API call (`cost.total_api_duration_ms > 0`). Claude Code omits `rate_limits` before the first response, and that must not wipe the last reading.
- **`external_monitor_cache`** is a reserved enum value. It is **not** offered in `supportedSourceKinds`, and create/test reject it. The audited monitors (onWatch, shuvquota) either poll undocumented endpoints in the background or refresh on GET.

---

## Tile Binding (`DeckButton`) & Legacy Compatibility

- **New Live Tile `dynamicType`:** `"ai_limits"`
  - `dynamicParameters` (secret-free only):
    - `accountId`: opaque `acct_...` ID from `GET /api/ai-limits`
    - `displayMode`: `"used"` (default) | `"remaining"`
    - `windows`: optional comma-separated priority filter, default `"five_hour,weekly"`
    - `showReset`: `"true"` (default) | `"false"`
  - When an `accountId` is missing (deleted source/account) or has `unavailable`/`not_connected` windows, the tile stays on the user's deck grid with its position/span intact and displays an honest reconnect/unavailable state.
- **Legacy `"ai_usage"` tiles:** Preserved and unbroken. `InfoService` routes legacy `ai_usage` plan queries to safe passive/official snapshots (never calls undocumented `api.anthropic.com/api/oauth/usage`), while `show="tokens"` continues reading local JSONL logs.
- **Demo `"ai_limits_demo"` tiles:** Untouched/isolated from live `"ai_limits"` data.
