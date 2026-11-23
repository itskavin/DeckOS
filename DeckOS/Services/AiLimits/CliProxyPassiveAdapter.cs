using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Models;

namespace DeckOS.Services.AiLimits
{
    /// <summary>
    /// Strictly read-only passive observer for a user's existing local CLIProxyAPI instance.
    /// Reads ONLY GET /v8/management/credentials (with GET /v0/management/auth-files fallback on 404)
    /// to observe already-captured response headers (quota.signals, model_quotas) and cooldowns.
    ///
    /// Attribution: Signal/cooldown schemas verified against router-for-me/CLIProxyAPI (MIT, v8.0.48 / 6eb8554f).
    /// NEVER invokes /api-call, /credentials/verify, /download, /refresh, or any active-probe endpoint,
    /// NEVER retries rejected management keys (guarding against CPA's 5-strike 30-minute IP ban),
    /// and NEVER persists or exposes credential material (id_token, email, auth filename, key).
    /// </summary>
    public sealed class CliProxyPassiveAdapter : IAiLimitsSourceAdapter
    {
        // CLIProxyAPI bans the caller IP for 30 minutes after 5 failed management-key attempts
        // (handler.go maxFailures=5, banDuration=30m). DeckOS stays well under that: a rejected key
        // is never sent again for longer than the ban window, and each proxy host:port gets at most
        // MaxAuthFailuresPerEndpoint rejected attempts per window, whatever key is tried.
        public static readonly TimeSpan AuthFailureWindow = TimeSpan.FromMinutes(35);
        public const int MaxAuthFailuresPerEndpoint = 2;

        private readonly Func<HttpClient> _clientFactory;
        private readonly ConcurrentDictionary<string, DateTimeOffset> _rejectedCredentials = new(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, List<DateTimeOffset>> _endpointAuthFailures = new(StringComparer.OrdinalIgnoreCase);
        private readonly ConcurrentDictionary<string, SemaphoreSlim> _endpointLocks = new(StringComparer.OrdinalIgnoreCase);

        public CliProxyPassiveAdapter(HttpMessageHandler? testHandler = null)
        {
            _clientFactory = testHandler != null
                ? () => new HttpClient(testHandler, disposeHandler: false) { Timeout = AiLimitsUrlValidator.DefaultTimeout }
                : () => new HttpClient(new SocketsHttpHandler
                {
                    AllowAutoRedirect = false,
                    UseCookies = false,
                    PooledConnectionLifetime = TimeSpan.FromMinutes(2),
                }, disposeHandler: true)
                {
                    Timeout = AiLimitsUrlValidator.DefaultTimeout,
                };
        }

        public string Kind => AiLimitsSourceKinds.CliProxyPassive;

        public AiLimitsSourceKindDescriptorDto Descriptor => new()
        {
            Kind = Kind,
            Title = "CLIProxyAPI (Passive Local)",
            Description = "Reads already-captured passive rate-limit headers and cooldowns from your local CLIProxyAPI without triggering upstream requests.",
            AccessMode = AiLimitsAccessModes.PassiveLocalProxy,
            RequiresCredential = true,
            SupportsMultiAccount = true,
            SupportsGuidedSetup = false,
            SupportsTestConnection = true,
            ProvenanceNote = "DeckOS only reads passive local proxy metadata and never triggers upstream quota probes or edits proxy settings. CLIProxyAPI is a separate user-run tool with independent provider policy considerations.",
        };

        public async Task<AiLimitsAdapterResult> FetchAsync(
            AiLimitsSourceConfig source,
            string? secret,
            DateTimeOffset now,
            CancellationToken ct)
        {
            var urlCheck = AiLimitsUrlValidator.ValidateSourceUrl(source.BaseUrl, source.AllowNonLoopback);
            if (!urlCheck.Ok || urlCheck.NormalizedUri == null)
            {
                return new AiLimitsAdapterResult
                {
                    Ok = false,
                    Reachable = false,
                    Status = AiLimitsSourceStatuses.Error,
                    ErrorCode = urlCheck.ErrorCode,
                    StatusMessage = urlCheck.ErrorMessage,
                };
            }

            if (string.IsNullOrWhiteSpace(secret))
            {
                return new AiLimitsAdapterResult
                {
                    Ok = false,
                    Reachable = false,
                    Status = AiLimitsSourceStatuses.AuthRequired,
                    ErrorCode = AiLimitsErrorCodes.AuthFailed,
                    StatusMessage = "Management key is required for CLIProxyAPI.",
                    AuthCircuitBreak = true,
                };
            }

            var baseUri = urlCheck.NormalizedUri.ToString().TrimEnd('/');
            var endpointKey = urlCheck.NormalizedUri.Authority;
            var credFingerprint = ComputeCredentialFingerprint(baseUri, secret);

            // Single-flight per proxy endpoint: tests, manual refreshes and background polls never
            // race each other into the proxy, so the failure budget below is enforced exactly.
            var endpointLock = _endpointLocks.GetOrAdd(endpointKey, _ => new SemaphoreSlim(1, 1));
            await endpointLock.WaitAsync(ct);
            try
            {
                if (_rejectedCredentials.TryGetValue(credFingerprint, out var blockedUntil) && now < blockedUntil)
                {
                    return AuthBlocked("This management key was already rejected by CLIProxyAPI, so DeckOS will not send it again. Enter the correct key to retry (this protects you from CLIProxyAPI's 30-minute IP lockout).");
                }

                if (RecentAuthFailures(endpointKey, now) >= MaxAuthFailuresPerEndpoint)
                {
                    return AuthBlocked("CLIProxyAPI rejected recent management keys. DeckOS paused all attempts to this proxy for 35 minutes so CLIProxyAPI does not lock out this PC. Check the key in CLIProxyAPI's config, then retry later.");
                }

                // Prefer canonical v8 management endpoint; fall back to legacy v0 ONLY on HTTP 404 (never on 401/403).
                var result = await TryGetEndpointAsync(baseUri + "/v8/management/credentials", secret, now, ct);
                var version = "v8";
                if (result.StatusCode == HttpStatusCode.NotFound)
                {
                    result = await TryGetEndpointAsync(baseUri + "/v0/management/auth-files", secret, now, ct);
                    version = "v0";
                }

                if (result.ErrorCode == AiLimitsErrorCodes.AuthFailed)
                {
                    _rejectedCredentials[credFingerprint] = now + AuthFailureWindow;
                    RecordAuthFailure(endpointKey, now);
                }
                else if (result.ErrorCode == null)
                {
                    _rejectedCredentials.TryRemove(credFingerprint, out _);
                }

                return BuildResult(source, result, version, urlCheck.IsNonLoopbackHttp, now);
            }
            finally
            {
                endpointLock.Release();
            }
        }

        private static AiLimitsAdapterResult AuthBlocked(string message) => new()
        {
            Ok = false,
            Reachable = true,
            Status = AiLimitsSourceStatuses.AuthRequired,
            ErrorCode = AiLimitsErrorCodes.AuthFailed,
            StatusMessage = message,
            AuthCircuitBreak = true,
        };

        private int RecentAuthFailures(string endpointKey, DateTimeOffset now)
        {
            if (!_endpointAuthFailures.TryGetValue(endpointKey, out var list)) return 0;
            lock (list)
            {
                list.RemoveAll(t => now - t >= AuthFailureWindow);
                return list.Count;
            }
        }

        private void RecordAuthFailure(string endpointKey, DateTimeOffset now)
        {
            var list = _endpointAuthFailures.GetOrAdd(endpointKey, _ => new List<DateTimeOffset>());
            lock (list) list.Add(now);
        }

        public static string ComputeCredentialFingerprint(string baseUri, string secret)
        {
            var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(baseUri + "|" + secret));
            return Convert.ToHexString(bytes);
        }

        private readonly record struct RawFetch(
            bool Reached,
            HttpStatusCode? StatusCode,
            string? Body,
            string? ErrorCode,
            string? ErrorMessage,
            TimeSpan? RetryAfter);

        private async Task<RawFetch> TryGetEndpointAsync(string url, string secret, DateTimeOffset now, CancellationToken ct)
        {
            using var client = _clientFactory();
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + secret);
            req.Headers.TryAddWithoutValidation("X-Management-Key", secret);
            req.Headers.UserAgent.ParseAdd("DeckOS");

            HttpResponseMessage resp;
            try
            {
                resp = await client.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            }
            catch (TaskCanceledException) when (!ct.IsCancellationRequested)
            {
                return new(false, null, null, AiLimitsErrorCodes.Timeout, "Timed out connecting to CLIProxyAPI.", null);
            }
            catch (HttpRequestException)
            {
                return new(false, null, null, AiLimitsErrorCodes.Unreachable, "Could not reach CLIProxyAPI at the configured URL.", null);
            }

            using (resp)
            {
                if (AiLimitsUrlValidator.IsRedirectStatus(resp.StatusCode))
                {
                    return new(true, resp.StatusCode, null, AiLimitsErrorCodes.RedirectBlocked,
                        "CLIProxyAPI returned an HTTP redirect; redirects are blocked so credentials are never forwarded.", null);
                }

                if (resp.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden)
                {
                    // CLIProxyAPI bans an IP for 30 minutes after 5 failed management-key attempts
                    // (router-for-me/CLIProxyAPI handler.go:419-460). Stop polling immediately on 401/403.
                    return new(true, resp.StatusCode, null, AiLimitsErrorCodes.AuthFailed,
                        "Management key rejected (HTTP " + (int)resp.StatusCode + "). Background checks paused to avoid CLIProxyAPI's IP lockout.", null);
                }

                if ((int)resp.StatusCode == 429 || (int)resp.StatusCode >= 500)
                {
                    var retryAfter = AiLimitsUrlValidator.ParseRetryAfter(resp, now, TimeSpan.FromMinutes(30));
                    return new(true, resp.StatusCode, null,
                        (int)resp.StatusCode == 429 ? AiLimitsErrorCodes.RateLimited : AiLimitsErrorCodes.Unreachable,
                        $"CLIProxyAPI returned HTTP {(int)resp.StatusCode}.",
                        retryAfter);
                }

                if (resp.StatusCode == HttpStatusCode.NotFound)
                {
                    return new(true, resp.StatusCode, null, AiLimitsErrorCodes.UnsupportedVersion,
                        "CLIProxyAPI management endpoint was not found (HTTP 404).", null);
                }

                if (!resp.IsSuccessStatusCode)
                {
                    return new(true, resp.StatusCode, null, AiLimitsErrorCodes.InternalError,
                        $"CLIProxyAPI returned HTTP {(int)resp.StatusCode}.", null);
                }

                var (tooLarge, body) = await AiLimitsUrlValidator.ReadBoundedStringAsync(resp.Content, AiLimitsUrlValidator.DefaultMaxResponseBytes, ct);
                if (tooLarge)
                {
                    return new(true, resp.StatusCode, null, AiLimitsErrorCodes.ResponseTooLarge,
                        "CLIProxyAPI response exceeded maximum safe size (2 MiB).", null);
                }

                return new(true, resp.StatusCode, body, null, null, null);
            }
        }

        private static AiLimitsAdapterResult BuildResult(
            AiLimitsSourceConfig source,
            RawFetch raw,
            string apiVersion,
            bool isNonLoopbackHttp,
            DateTimeOffset now)
        {
            if (raw.ErrorCode != null)
            {
                var isAuth = raw.ErrorCode == AiLimitsErrorCodes.AuthFailed;
                var isRateLimited = raw.ErrorCode == AiLimitsErrorCodes.RateLimited;
                return new AiLimitsAdapterResult
                {
                    Ok = false,
                    Reachable = raw.Reached,
                    Status = isAuth
                        ? AiLimitsSourceStatuses.AuthRequired
                        : isRateLimited
                            ? AiLimitsSourceStatuses.RateLimited
                            : raw.Reached ? AiLimitsSourceStatuses.Degraded : AiLimitsSourceStatuses.Offline,
                    ErrorCode = raw.ErrorCode,
                    StatusMessage = raw.ErrorMessage,
                    RetryAfter = raw.RetryAfter,
                    AuthCircuitBreak = isAuth,
                };
            }

            try
            {
                var accounts = ParseCredentialsPayload(source.Id, raw.Body ?? "{}", now);
                var withSignals = accounts.Count(a => a.Windows.Any(w => w.UsedPercent.HasValue));
                var lanNote = isNonLoopbackHttp ? " Warning: non-loopback HTTP transmits the management key unencrypted on LAN." : "";
                return new AiLimitsAdapterResult
                {
                    Ok = true,
                    Reachable = true,
                    Status = accounts.Count > 0 ? AiLimitsSourceStatuses.Connected : AiLimitsSourceStatuses.AwaitingData,
                    StatusMessage = $"Connected via CLIProxyAPI {apiVersion} ({accounts.Count} accounts, {withSignals} with passive quota signals).{lanNote}",
                    DetectedApiVersion = apiVersion,
                    CapabilitiesNote = "Passive observation reads already-captured Claude & Codex headers and cooldowns from CLIProxyAPI. Providers without passive headers (e.g. Antigravity) stay unavailable rather than 0%.",
                    Accounts = accounts,
                };
            }
            catch (JsonException)
            {
                return new AiLimitsAdapterResult
                {
                    Ok = false,
                    Reachable = true,
                    Status = AiLimitsSourceStatuses.Error,
                    ErrorCode = AiLimitsErrorCodes.UnsupportedVersion,
                    StatusMessage = "CLIProxyAPI returned an unexpected JSON payload.",
                    DetectedApiVersion = apiVersion,
                };
            }
        }

        /// <summary>
        /// Immediately whitelist-normalizes CLIProxyAPI credentials JSON into secret-free account DTOs.
        /// Raw fields like email, id_token, name, path, account, project_id are NEVER copied or persisted.
        /// </summary>
        public static List<AiLimitsAccountDto> ParseCredentialsPayload(string sourceId, string json, DateTimeOffset now)
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            JsonElement listEl = default;
            if (root.ValueKind == JsonValueKind.Array)
            {
                listEl = root;
            }
            else if (root.ValueKind == JsonValueKind.Object)
            {
                if (root.TryGetProperty("files", out var filesEl) && filesEl.ValueKind == JsonValueKind.Array)
                    listEl = filesEl;
                else if (root.TryGetProperty("credentials", out var credsEl) && credsEl.ValueKind == JsonValueKind.Array)
                    listEl = credsEl;
            }

            var accounts = new List<AiLimitsAccountDto>();
            if (listEl.ValueKind != JsonValueKind.Array)
                return accounts;

            var providerCounts = new Dictionary<string, int>(StringComparer.Ordinal);
            var index = 0;

            foreach (var item in listEl.EnumerateArray())
            {
                index++;
                if (item.ValueKind != JsonValueKind.Object) continue;

                var rawProvider = GetString(item, "provider") ?? GetString(item, "type") ?? "other";
                var provider = AiLimitsProviders.Normalize(rawProvider);
                var providerLabel = AiLimitsProviders.DisplayLabel(provider);

                providerCounts.TryGetValue(provider, out var seq);
                seq++;
                providerCounts[provider] = seq;

                // Stable opaque identity derived strictly via SHA-256; never emits raw auth_index/id/name/email.
                var stableRaw = GetString(item, "auth_index")
                    ?? GetString(item, "id")
                    ?? $"{provider}#{index}";
                var accountId = AiLimitsConfigStore.DeriveOpaqueAccountId(sourceId, stableRaw);
                var defaultAlias = $"{providerLabel} #{seq}";

                var disabled = GetBool(item, "disabled") == true || string.Equals(GetString(item, "status"), "disabled", StringComparison.OrdinalIgnoreCase);
                var unavailable = GetBool(item, "unavailable") == true;
                var quotaBlocked = GetBool(item, "quota_blocked") == true;
                var requiresSignIn = GetBool(item, "requires_sign_in") == true;
                var nextRetryAfter = ParseTimestamp(item, "next_retry_after");
                var cooldownUntil = ExtractCooldownUntil(item, nextRetryAfter, now);

                DateTimeOffset? observedAt = null;
                var signals = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                if (item.TryGetProperty("quota", out var quotaEl) && quotaEl.ValueKind == JsonValueKind.Object)
                {
                    observedAt = ParseTimestamp(quotaEl, "observed_at");
                    if (quotaEl.TryGetProperty("signals", out var sigEl) && sigEl.ValueKind == JsonValueKind.Object)
                        ReadStringSignals(sigEl, signals);
                }

                // Fallback: if top-level quota.signals is empty, inspect model_quotas for the newest observed passive signal.
                var modelWindows = new List<AiLimitsWindowDto>();
                if (item.TryGetProperty("model_quotas", out var mqEl) && mqEl.ValueKind == JsonValueKind.Object)
                {
                    DateTimeOffset? latestModelObs = null;
                    Dictionary<string, string>? latestModelSignals = null;
                    foreach (var mqProp in mqEl.EnumerateObject())
                    {
                        if (mqProp.Value.ValueKind != JsonValueKind.Object) continue;
                        var mObs = ParseTimestamp(mqProp.Value, "observed_at");
                        var mSigs = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                        if (mqProp.Value.TryGetProperty("signals", out var mSigEl) && mSigEl.ValueKind == JsonValueKind.Object)
                            ReadStringSignals(mSigEl, mSigs);
                        if (mSigs.Count == 0) continue;

                        if (latestModelSignals == null || (mObs.HasValue && (!latestModelObs.HasValue || mObs > latestModelObs)))
                        {
                            latestModelObs = mObs;
                            latestModelSignals = mSigs;
                        }
                    }

                    if (signals.Count == 0 && latestModelSignals != null)
                    {
                        signals = latestModelSignals;
                        observedAt ??= latestModelObs;
                    }
                }

                var windows = new List<AiLimitsWindowDto>();
                string? plan = null;
                bool? ordinaryAllowed = null;

                if (signals.Count > 0)
                {
                    if (provider == AiLimitsProviders.Claude || HasPrefix(signals, "Anthropic-Ratelimit-Unified-"))
                    {
                        ParseClaudePassiveSignals(signals, observedAt, now, quotaBlocked, windows, out ordinaryAllowed);
                    }
                    else if (provider == AiLimitsProviders.Codex || HasPrefix(signals, "X-Codex-"))
                    {
                        ParseCodexPassiveSignals(signals, observedAt, now, quotaBlocked, windows, out plan, out ordinaryAllowed);
                    }
                    else if (provider == AiLimitsProviders.Devin || signals.ContainsKey("daily_quota_remaining_percent") || signals.ContainsKey("weekly_quota_remaining_percent"))
                    {
                        ParseDevinPassiveSignals(signals, observedAt, now, quotaBlocked, windows, out plan);
                    }
                    else
                    {
                        ParseGenericPassiveSignals(signals, observedAt, now, quotaBlocked, windows);
                    }
                }

                if (modelWindows.Count > 0)
                    windows.AddRange(modelWindows);

                // Without quota.observed_at the capture time is unknown, so the reading can't be shown as fresh.
                if (!observedAt.HasValue)
                {
                    foreach (var w in windows.Where(w => w.Status == AiLimitsWindowStatuses.Available))
                    {
                        w.Status = AiLimitsWindowStatuses.Stale;
                        w.Note = "Capture time unknown";
                    }
                }

                // Never assume empty signals means 0%! Populate honest unavailable states.
                string connectionStatus;
                string quotaStatus;
                string freshness;
                string? statusMessage = null;
                string? errorCode = null;

                if (disabled)
                {
                    connectionStatus = AiLimitsConnectionStatuses.Disabled;
                    quotaStatus = AiLimitsQuotaStatuses.Unavailable;
                    freshness = AiLimitsFreshness.Unavailable;
                    statusMessage = "Disabled in CLIProxyAPI.";
                }
                else if (requiresSignIn)
                {
                    connectionStatus = AiLimitsConnectionStatuses.AuthRequired;
                    quotaStatus = AiLimitsQuotaStatuses.AuthRequired;
                    freshness = AiLimitsFreshness.Unavailable;
                    errorCode = AiLimitsErrorCodes.AuthFailed;
                    statusMessage = "Account requires sign-in inside CLIProxyAPI.";
                }
                else if (windows.Count == 0)
                {
                    connectionStatus = unavailable ? AiLimitsConnectionStatuses.Unavailable : AiLimitsConnectionStatuses.Connected;
                    var supportsPassive = provider is AiLimitsProviders.Claude or AiLimitsProviders.Codex or AiLimitsProviders.Devin;
                    quotaStatus = supportsPassive ? AiLimitsQuotaStatuses.AwaitingData : AiLimitsQuotaStatuses.Unavailable;
                    freshness = AiLimitsFreshness.Unavailable;
                    statusMessage = supportsPassive
                        ? "Connected in CLIProxyAPI — no passive quota headers captured yet."
                        : $"{providerLabel} does not emit passive quota headers in CLIProxyAPI. Open the official dashboard to check limits.";

                    windows.Add(AiLimitsNormalizer.BuildUnavailableWindow(
                        "five_hour",
                        AiLimitsWindowKinds.FiveHour,
                        "5h Limit",
                        300,
                        AiLimitsWindowStatuses.Unavailable,
                        supportsPassive ? "Awaiting proxy traffic" : "No passive proxy headers"));
                    windows.Add(AiLimitsNormalizer.BuildUnavailableWindow(
                        "weekly",
                        AiLimitsWindowKinds.Weekly,
                        "Weekly",
                        10080,
                        AiLimitsWindowStatuses.Unavailable,
                        supportsPassive ? "Awaiting proxy traffic" : "No passive proxy headers"));
                }
                else
                {
                    connectionStatus = unavailable ? AiLimitsConnectionStatuses.Unavailable : AiLimitsConnectionStatuses.Connected;
                    var anyRateLimited = quotaBlocked || ordinaryAllowed == false || windows.Any(w => w.Status == AiLimitsWindowStatuses.RateLimited);
                    var anyAvailable = windows.Any(w => w.Status == AiLimitsWindowStatuses.Available);
                    var anyStale = windows.Any(w => w.Status == AiLimitsWindowStatuses.Stale);

                    if (anyRateLimited)
                    {
                        quotaStatus = cooldownUntil.HasValue && cooldownUntil.Value > now
                            ? AiLimitsQuotaStatuses.Cooldown
                            : AiLimitsQuotaStatuses.RateLimited;
                        freshness = anyStale && !anyAvailable ? AiLimitsFreshness.Stale : AiLimitsFreshness.Fresh;
                        statusMessage = cooldownUntil.HasValue && cooldownUntil.Value > now
                            ? "Quota blocked / cooling down in CLIProxyAPI."
                            : "Rate limit reached according to last passive proxy headers.";
                    }
                    else if (anyAvailable)
                    {
                        quotaStatus = AiLimitsQuotaStatuses.Ok;
                        freshness = AiLimitsFreshness.Fresh;
                    }
                    else if (anyStale)
                    {
                        quotaStatus = AiLimitsQuotaStatuses.Stale;
                        freshness = AiLimitsFreshness.Stale;
                        statusMessage = "Last passive headers are stale — awaiting next proxied request.";
                    }
                    else
                    {
                        quotaStatus = AiLimitsQuotaStatuses.Unavailable;
                        freshness = AiLimitsFreshness.Unavailable;
                    }
                }

                accounts.Add(new AiLimitsAccountDto
                {
                    Id = accountId,
                    SourceId = sourceId,
                    SourceKind = AiLimitsSourceKinds.CliProxyPassive,
                    Provider = provider,
                    Product = AiLimitsProviders.DefaultProduct(provider),
                    ProviderLabel = providerLabel,
                    Alias = defaultAlias,
                    DefaultAlias = defaultAlias,
                    Plan = plan,
                    ModelPool = "all",
                    Enabled = !disabled,
                    ConnectionStatus = connectionStatus,
                    QuotaStatus = quotaStatus,
                    Freshness = freshness,
                    SupportLevel = AiLimitsAccessModes.PassiveLocalProxy,
                    CoverageScope = AiLimitsCoverageScopes.ProxyObservedOnly,
                    ProvenanceLabel = "CLIProxyAPI · Passive",
                    ProvenanceDetails = "Passively observed from headers captured by your local CLIProxyAPI. DeckOS sends zero extra upstream probes and never modifies proxy settings.",
                    ObservedAt = observedAt,
                    StaleAfterSeconds = AiLimitsNormalizer.DefaultStaleAfterSeconds,
                    CooldownUntil = cooldownUntil,
                    OrdinaryUsageAllowed = ordinaryAllowed,
                    DashboardUrl = AiLimitsProviders.OfficialDashboardUrl(provider),
                    ErrorCode = errorCode,
                    StatusMessage = statusMessage,
                    Windows = AiLimitsNormalizer.OrderWindows(windows),
                });
            }

            return accounts;
        }

        private static void ParseClaudePassiveSignals(
            Dictionary<string, string> signals,
            DateTimeOffset? observedAt,
            DateTimeOffset now,
            bool quotaBlocked,
            List<AiLimitsWindowDto> windows,
            out bool? ordinaryAllowed)
        {
            var overallStatus = signals.TryGetValue("Anthropic-Ratelimit-Unified-Status", out var st) ? st : null;
            ordinaryAllowed = overallStatus switch
            {
                var s when string.Equals(s, "rejected", StringComparison.OrdinalIgnoreCase) => false,
                var s when string.Equals(s, "allowed", StringComparison.OrdinalIgnoreCase) || string.Equals(s, "allowed_warning", StringComparison.OrdinalIgnoreCase) => true,
                _ => quotaBlocked ? false : null,
            };

            if (TryParseUtilizationPercent(signals, "Anthropic-Ratelimit-Unified-5h-Utilization", out var pct5h))
            {
                var reset5h = TryParseEpochSeconds(signals, "Anthropic-Ratelimit-Unified-5h-Reset");
                var st5h = signals.TryGetValue("Anthropic-Ratelimit-Unified-5h-Status", out var v) ? v : null;
                var limited5h = string.Equals(st5h, "rejected", StringComparison.OrdinalIgnoreCase);
                windows.Add(AiLimitsNormalizer.BuildPercentWindow(
                    "five_hour",
                    AiLimitsWindowKinds.FiveHour,
                    "5h Limit",
                    300,
                    pct5h,
                    reset5h,
                    observedAt,
                    now,
                    ordinaryUsageAllowed: limited5h ? false : ordinaryAllowed,
                    isRateLimited: limited5h));
            }

            if (TryParseUtilizationPercent(signals, "Anthropic-Ratelimit-Unified-7d-Utilization", out var pct7d))
            {
                var reset7d = TryParseEpochSeconds(signals, "Anthropic-Ratelimit-Unified-7d-Reset");
                var st7d = signals.TryGetValue("Anthropic-Ratelimit-Unified-7d-Status", out var v) ? v : null;
                var limited7d = string.Equals(st7d, "rejected", StringComparison.OrdinalIgnoreCase);
                windows.Add(AiLimitsNormalizer.BuildPercentWindow(
                    "weekly",
                    AiLimitsWindowKinds.Weekly,
                    "Weekly",
                    10080,
                    pct7d,
                    reset7d,
                    observedAt,
                    now,
                    ordinaryUsageAllowed: limited7d ? false : ordinaryAllowed,
                    isRateLimited: limited7d));
            }
        }

        private static void ParseCodexPassiveSignals(
            Dictionary<string, string> signals,
            DateTimeOffset? observedAt,
            DateTimeOffset now,
            bool quotaBlocked,
            List<AiLimitsWindowDto> windows,
            out string? plan,
            out bool? ordinaryAllowed)
        {
            plan = signals.TryGetValue("X-Codex-Plan-Type", out var pt) && !string.IsNullOrWhiteSpace(pt)
                ? FormatPlanName(pt)
                : null;
            ordinaryAllowed = quotaBlocked ? false : null;

            AddCodexSignalWindow(signals, "X-Codex-Primary-", "primary", AiLimitsWindowKinds.FiveHour, "5h Limit", 300, observedAt, now, quotaBlocked, windows);
            AddCodexSignalWindow(signals, "X-Codex-Secondary-", "secondary", AiLimitsWindowKinds.Weekly, "Weekly", 10080, observedAt, now, quotaBlocked, windows);

            // Parse additional Codex model-pool headers verified in router-for-me/CLIProxyAPI quota_signals.go (MIT):
            // e.g., X-Codex-Code-Review-Primary-Used-Percent, X-Codex-Bengalfox-Primary-Used-Percent (+ Limit-Name),
            // or X-Codex-Additional-<pool>-Primary-Used-Percent.
            var extraPools = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var key in signals.Keys)
            {
                if (!key.StartsWith("X-Codex-", StringComparison.OrdinalIgnoreCase)) continue;
                var rest = key["X-Codex-".Length..];
                if (rest.StartsWith("Primary-", StringComparison.OrdinalIgnoreCase) ||
                    rest.StartsWith("Secondary-", StringComparison.OrdinalIgnoreCase) ||
                    rest.StartsWith("Credits-", StringComparison.OrdinalIgnoreCase) ||
                    rest.Equals("Plan-Type", StringComparison.OrdinalIgnoreCase) ||
                    rest.Equals("Active-Limit", StringComparison.OrdinalIgnoreCase))
                    continue;

                var pIdx = rest.IndexOf("-Primary-Used-Percent", StringComparison.OrdinalIgnoreCase);
                if (pIdx > 0) extraPools.Add(rest[..pIdx]);
                var sIdx = rest.IndexOf("-Secondary-Used-Percent", StringComparison.OrdinalIgnoreCase);
                if (sIdx > 0) extraPools.Add(rest[..sIdx]);
            }

            foreach (var poolKey in extraPools)
            {
                var poolPrefix = "X-Codex-" + poolKey + "-";
                var poolName = signals.TryGetValue(poolPrefix + "Limit-Name", out var ln) && !string.IsNullOrWhiteSpace(ln)
                    ? AiLimitsNormalizer.SanitizeText(ln, 48) ?? poolKey
                    : poolKey;
                AddCodexSignalWindow(signals, poolPrefix + "Primary-", $"pool:{poolKey.ToLowerInvariant()}:primary",
                    AiLimitsWindowKinds.FiveHour, $"{poolName} 5h", 300, observedAt, now, quotaBlocked, windows, modelPool: poolName, prefixIdWithPool: true);
                AddCodexSignalWindow(signals, poolPrefix + "Secondary-", $"pool:{poolKey.ToLowerInvariant()}:secondary",
                    AiLimitsWindowKinds.Weekly, $"{poolName} Weekly", 10080, observedAt, now, quotaBlocked, windows, modelPool: poolName, prefixIdWithPool: true);
            }

            // CodexBar (MIT) CodexRateWindowNormalizer: Pro plans have no 5h cap and report one
            // 10080-minute window in the primary slot. Window kind comes from duration, so a weekly
            // primary already lands in `weekly`; the missing 5h is reported as not applicable.
            var mainPool = windows.Where(w => string.Equals(w.ModelPool, "all", StringComparison.OrdinalIgnoreCase)).ToList();
            var primaryIsWeekly = TryParseInt(signals, "X-Codex-Primary-Window-Minutes") is >= 9000;
            if (mainPool.All(w => w.Kind != AiLimitsWindowKinds.FiveHour) &&
                mainPool.Any(w => w.Kind == AiLimitsWindowKinds.Weekly) &&
                (AiLimitsNormalizer.IsCodexProPlan(pt) || primaryIsWeekly))
            {
                windows.Add(AiLimitsNormalizer.BuildUnavailableWindow(
                    "five_hour",
                    AiLimitsWindowKinds.FiveHour,
                    "5h Limit",
                    300,
                    AiLimitsWindowStatuses.NotApplicable,
                    AiLimitsNormalizer.IsCodexProPlan(pt) ? "No 5h cap on Pro" : "Weekly-only plan"));
            }
        }

        private static void ParseDevinPassiveSignals(
            Dictionary<string, string> signals,
            DateTimeOffset? observedAt,
            DateTimeOffset now,
            bool quotaBlocked,
            List<AiLimitsWindowDto> windows,
            out string? plan)
        {
            // Verified in router-for-me/CLIProxyAPI internal/runtime/executor/devin_executor.go (MIT):
            // signals contain remaining percentages like "85%" and RFC3339 reset timestamps.
            plan = signals.TryGetValue("plan", out var p) ? AiLimitsNormalizer.SanitizeText(p, 48) : null;

            if (TryParseRemainingPercentToUsed(signals, "daily_quota_remaining_percent", out var dailyUsed))
            {
                var resetAt = TryParseEpochSeconds(signals, "daily_quota_reset_at");
                windows.Add(AiLimitsNormalizer.BuildPercentWindow(
                    "daily",
                    AiLimitsWindowKinds.Daily,
                    "Daily",
                    1440,
                    dailyUsed,
                    resetAt,
                    observedAt,
                    now,
                    isRateLimited: quotaBlocked && dailyUsed >= 99.5));
            }

            if (TryParseRemainingPercentToUsed(signals, "weekly_quota_remaining_percent", out var weeklyUsed))
            {
                var resetAt = TryParseEpochSeconds(signals, "weekly_quota_reset_at");
                windows.Add(AiLimitsNormalizer.BuildPercentWindow(
                    "weekly",
                    AiLimitsWindowKinds.Weekly,
                    "Weekly",
                    10080,
                    weeklyUsed,
                    resetAt,
                    observedAt,
                    now,
                    isRateLimited: quotaBlocked && weeklyUsed >= 99.5));
            }
        }

        private static bool TryParseRemainingPercentToUsed(Dictionary<string, string> signals, string key, out double usedPercent)
        {
            usedPercent = 0;
            if (!signals.TryGetValue(key, out var raw) || string.IsNullOrWhiteSpace(raw)) return false;
            var cleaned = raw.Trim().TrimEnd('%').Trim();
            if (!double.TryParse(cleaned, NumberStyles.Float, CultureInfo.InvariantCulture, out var remaining)) return false;
            if (double.IsNaN(remaining) || double.IsInfinity(remaining)) return false;
            usedPercent = Math.Clamp(100.0 - remaining, 0.0, 100.0);
            return true;
        }

        private static void AddCodexSignalWindow(
            Dictionary<string, string> signals,
            string prefix,
            string slot,
            string fallbackKind,
            string fallbackLabel,
            int fallbackMinutes,
            DateTimeOffset? observedAt,
            DateTimeOffset now,
            bool quotaBlocked,
            List<AiLimitsWindowDto> windows,
            string modelPool = "all",
            bool prefixIdWithPool = false)
        {
            if (!TryParseDouble(signals, prefix + "Used-Percent", out var pct))
                return;

            var mins = TryParseInt(signals, prefix + "Window-Minutes") ?? fallbackMinutes;
            var (kind, baseLabel) = AiLimitsNormalizer.ClassifyWindowMinutes(mins, fallbackKind, fallbackLabel);
            var label = prefixIdWithPool ? $"{modelPool} {baseLabel}" : baseLabel;
            var resetAt = TryParseEpochSeconds(signals, prefix + "Reset-At");
            if (!resetAt.HasValue && observedAt.HasValue && TryParseInt(signals, prefix + "Reset-After-Seconds") is { } afterSec && afterSec > 0)
                resetAt = observedAt.Value.AddSeconds(afterSec);

            var id = prefixIdWithPool ? slot : (kind == AiLimitsWindowKinds.Custom ? slot : kind);
            windows.Add(AiLimitsNormalizer.BuildPercentWindow(
                id,
                kind,
                label,
                mins,
                pct,
                resetAt,
                observedAt,
                now,
                modelPool: modelPool,
                isRateLimited: quotaBlocked && pct >= 99.5,
                clampOverflow: true));
        }

        private static void ParseGenericPassiveSignals(
            Dictionary<string, string> signals,
            DateTimeOffset? observedAt,
            DateTimeOffset now,
            bool quotaBlocked,
            List<AiLimitsWindowDto> windows)
        {
            // Conservative parser for Devin or future passive headers only when explicit utilization/percent keys exist.
            foreach (var (k, v) in signals)
            {
                if (!k.Contains("utilization", StringComparison.OrdinalIgnoreCase) &&
                    !k.Contains("used-percent", StringComparison.OrdinalIgnoreCase))
                    continue;
                if (!double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var num))
                    continue;

                var pct = k.Contains("utilization", StringComparison.OrdinalIgnoreCase) && num >= 0 && num <= 1.0 && v.Contains('.')
                    ? num * 100.0
                    : num;
                var kind = k.Contains("5h", StringComparison.OrdinalIgnoreCase)
                    ? AiLimitsWindowKinds.FiveHour
                    : k.Contains("7d", StringComparison.OrdinalIgnoreCase) || k.Contains("week", StringComparison.OrdinalIgnoreCase)
                        ? AiLimitsWindowKinds.Weekly
                        : AiLimitsWindowKinds.Custom;
                var label = kind switch
                {
                    AiLimitsWindowKinds.FiveHour => "5h Limit",
                    AiLimitsWindowKinds.Weekly => "Weekly",
                    _ => "Quota",
                };
                windows.Add(AiLimitsNormalizer.BuildPercentWindow(
                    kind,
                    kind,
                    label,
                    kind == AiLimitsWindowKinds.FiveHour ? 300 : kind == AiLimitsWindowKinds.Weekly ? 10080 : null,
                    pct,
                    null,
                    observedAt,
                    now,
                    isRateLimited: quotaBlocked));
            }
        }

        private static bool TryParseUtilizationPercent(Dictionary<string, string> signals, string key, out double percent)
        {
            percent = 0;
            if (!signals.TryGetValue(key, out var raw) || string.IsNullOrWhiteSpace(raw))
                return false;
            if (!double.TryParse(raw.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
                return false;
            if (double.IsNaN(value) || double.IsInfinity(value))
                return false;

            // Verified live on CLIProxyAPI v8: Anthropic-Ratelimit-Unified-*-Utilization is a 0.0..1.0 ratio (e.g. 0.42 -> 42%).
            // If an upstream ever emits >1.0 (already scaled 0..100), keep as percentage.
            percent = value <= 1.0 ? value * 100.0 : value;
            return true;
        }

        private static bool TryParseDouble(Dictionary<string, string> signals, string key, out double value)
        {
            value = 0;
            return signals.TryGetValue(key, out var raw)
                && double.TryParse(raw.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out value)
                && !double.IsNaN(value) && !double.IsInfinity(value);
        }

        private static int? TryParseInt(Dictionary<string, string> signals, string key) =>
            signals.TryGetValue(key, out var raw) && int.TryParse(raw.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var n)
                ? n
                : null;

        private static DateTimeOffset? TryParseEpochSeconds(Dictionary<string, string> signals, string key)
        {
            if (!signals.TryGetValue(key, out var raw) || string.IsNullOrWhiteSpace(raw)) return null;
            raw = raw.Trim();
            if (long.TryParse(raw, NumberStyles.Integer, CultureInfo.InvariantCulture, out var unix))
            {
                if (unix > 1_000_000_000_000L) return DateTimeOffset.FromUnixTimeMilliseconds(unix);
                if (unix > 1_000_000_000L) return DateTimeOffset.FromUnixTimeSeconds(unix);
            }
            if (DateTimeOffset.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed))
                return parsed.ToUniversalTime();
            return null;
        }

        private static DateTimeOffset? ExtractCooldownUntil(JsonElement item, DateTimeOffset? nextRetryAfter, DateTimeOffset now)
        {
            DateTimeOffset? best = nextRetryAfter;
            if (!item.TryGetProperty("cooldowns", out var cdEl)) return best;

            // Canonical CLIProxyAPI v8/v0 schema (sdk/cliproxy/auth/cooldown_view.go):
            // array of { scope, model_key?, reason, retry_at (RFC3339), remaining_seconds (int64), ... }
            if (cdEl.ValueKind == JsonValueKind.Array)
            {
                foreach (var elem in cdEl.EnumerateArray())
                {
                    if (elem.ValueKind != JsonValueKind.Object) continue;
                    var candidate = ParseTimestamp(elem, "retry_at")
                        ?? ParseTimestamp(elem, "next_recover_at")
                        ?? ParseTimestamp(elem, "until");
                    if (!candidate.HasValue && elem.TryGetProperty("remaining_seconds", out var rem) && rem.TryGetInt64(out var secs) && secs > 0)
                        candidate = now.AddSeconds(secs);
                    if (candidate.HasValue && (!best.HasValue || candidate.Value > best.Value))
                        best = candidate;
                }
            }
            else if (cdEl.ValueKind == JsonValueKind.Object)
            {
                foreach (var prop in cdEl.EnumerateObject())
                {
                    DateTimeOffset? candidate = null;
                    if (prop.Value.ValueKind == JsonValueKind.Number && prop.Value.TryGetDouble(out var secs) && secs > 0)
                    {
                        candidate = secs > 1_000_000_000 ? DateTimeOffset.FromUnixTimeSeconds((long)secs) : now.AddSeconds(secs);
                    }
                    else if (prop.Value.ValueKind == JsonValueKind.String &&
                        DateTimeOffset.TryParse(prop.Value.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dt))
                    {
                        candidate = dt.ToUniversalTime();
                    }
                    else if (prop.Value.ValueKind == JsonValueKind.Object)
                    {
                        candidate = ParseTimestamp(prop.Value, "retry_at")
                            ?? ParseTimestamp(prop.Value, "next_recover_at")
                            ?? ParseTimestamp(prop.Value, "until")
                            ?? ParseTimestamp(prop.Value, "next_retry_after");
                    }

                    if (candidate.HasValue && (!best.HasValue || candidate.Value > best.Value))
                        best = candidate;
                }
            }
            return best;
        }

        private static void ReadStringSignals(JsonElement el, Dictionary<string, string> target)
        {
            foreach (var p in el.EnumerateObject())
            {
                var str = p.Value.ValueKind switch
                {
                    JsonValueKind.String => p.Value.GetString(),
                    JsonValueKind.Number => p.Value.GetRawText(),
                    JsonValueKind.True => "true",
                    JsonValueKind.False => "false",
                    _ => null,
                };
                if (!string.IsNullOrEmpty(str))
                    target[p.Name] = str;
            }
        }

        private static bool HasPrefix(Dictionary<string, string> signals, string prefix) =>
            signals.Keys.Any(k => k.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));

        private static string? GetString(JsonElement obj, string prop) =>
            obj.TryGetProperty(prop, out var el) && el.ValueKind == JsonValueKind.String ? el.GetString() : null;

        private static bool? GetBool(JsonElement obj, string prop) =>
            obj.TryGetProperty(prop, out var el) && (el.ValueKind == JsonValueKind.True || el.ValueKind == JsonValueKind.False)
                ? el.GetBoolean()
                : null;

        private static DateTimeOffset? ParseTimestamp(JsonElement obj, string prop)
        {
            if (!obj.TryGetProperty(prop, out var el)) return null;
            if (el.ValueKind == JsonValueKind.String &&
                DateTimeOffset.TryParse(el.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dt))
                return dt.ToUniversalTime();
            if (el.ValueKind == JsonValueKind.Number && el.TryGetInt64(out var unix) && unix > 0)
                return unix > 1_000_000_000_000L ? DateTimeOffset.FromUnixTimeMilliseconds(unix) : DateTimeOffset.FromUnixTimeSeconds(unix);
            return null;
        }

        private static string FormatPlanName(string raw)
        {
            var trimmed = raw.Trim();
            if (trimmed.Length == 0) return trimmed;
            return char.ToUpperInvariant(trimmed[0]) + trimmed[1..].ToLowerInvariant();
        }
    }
}
