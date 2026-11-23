using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Hubs;
using DeckOS.Models;
using Microsoft.AspNetCore.SignalR;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace DeckOS.Services.AiLimits
{
    public interface IAiLimitsEnvironmentDetector
    {
        Task<AiLimitsDetectedEnvironmentDto> DetectAsync(CancellationToken ct);
    }

    /// <summary>
    /// Strictly read-only, zero-secret local environment detector.
    /// Checks only loopback 127.0.0.1:8317 TCP reachability (never reads config.yaml or secrets),
    /// CLI executable presence on PATH, and default local directory existence.
    /// </summary>
    public sealed class LocalAiLimitsEnvironmentDetector : IAiLimitsEnvironmentDetector
    {
        public async Task<AiLimitsDetectedEnvironmentDto> DetectAsync(CancellationToken ct)
        {
            var cliProxyReachable = await ProbeLoopbackPortAsync(8317, ct);
            var codexDir = AiUsageService.CodexDir;
            var claudeDir = AiUsageService.ClaudeDir;
            var geminiDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".gemini");
            var claudeSettingsPath = Path.Combine(claudeDir, "settings.json");

            return new AiLimitsDetectedEnvironmentDto
            {
                CliProxyReachable = cliProxyReachable,
                CliProxySuggestedUrl = cliProxyReachable ? "http://127.0.0.1:8317" : null,
                CodexCliAvailable = ExistsOnPath("codex"),
                CodexDefaultHomeExists = Directory.Exists(codexDir),
                ClaudeCliAvailable = ExistsOnPath("claude"),
                ClaudeConfigDirExists = Directory.Exists(claudeDir),
                ClaudeStatusLineConfigured = !string.IsNullOrWhiteSpace(ClaudeStatusLineAdapter.ReadExistingStatusLineCommand(claudeSettingsPath)),
                GeminiDirExists = Directory.Exists(geminiDir),
            };
        }

        private static async Task<bool> ProbeLoopbackPortAsync(int port, CancellationToken ct)
        {
            using var tcp = new TcpClient();
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(TimeSpan.FromMilliseconds(250));
            try
            {
                await tcp.ConnectAsync("127.0.0.1", port, timeoutCts.Token);
                return tcp.Connected;
            }
            catch
            {
                return false;
            }
        }

        private static bool ExistsOnPath(string command)
        {
            var pathVar = Environment.GetEnvironmentVariable("PATH");
            if (string.IsNullOrWhiteSpace(pathVar)) return false;

            var exts = OperatingSystem.IsWindows()
                ? (Environment.GetEnvironmentVariable("PATHEXT") ?? ".EXE;.CMD;.BAT;.COM")
                    .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                : new[] { "" };

            foreach (var dir in pathVar.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                foreach (var ext in exts)
                {
                    try
                    {
                        var candidate = Path.Combine(dir, command + ext);
                        if (File.Exists(candidate)) return true;
                    }
                    catch { }
                }
            }
            return false;
        }
    }

    public readonly record struct AiLimitsRefreshOutcome(
        bool CooldownBlocked,
        int? RetryAfterSeconds,
        DateTimeOffset? NextRefreshAllowedAt,
        AiLimitsSnapshotResponse Snapshot);

    public sealed class AiLimitsService : BackgroundService
    {
        public const string HubEvent = "ReceiveAiLimitsState";
        private static readonly TimeSpan MaxBackoff = TimeSpan.FromMinutes(30);
        private static readonly TimeSpan EnvCacheTtl = TimeSpan.FromSeconds(30);

        private readonly ILogger<AiLimitsService> _logger;
        private readonly IHubContext<DeckHub>? _hub;
        private readonly AiLimitsConfigStore _store;
        private readonly IAiLimitsEnvironmentDetector _envDetector;
        private readonly Dictionary<string, IAiLimitsSourceAdapter> _adapters;
        private readonly ClaudeStatusLineAdapter _claudeAdapter;
        private readonly Func<DateTimeOffset> _clock;
        private readonly Func<int> _connectedClientsCount;

        private readonly SemaphoreSlim _globalConcurrency = new(3, 3);
        private readonly ConcurrentDictionary<string, SemaphoreSlim> _sourceLocks = new(StringComparer.Ordinal);
        private readonly ConcurrentDictionary<string, SourceRuntimeState> _runtime = new(StringComparer.Ordinal);
        private readonly object _refreshGate = new();
        private readonly object _envGate = new();

        private AiLimitsConfigDocument _config;
        private DateTimeOffset? _lastManualRefreshAt;
        private int _activeRefreshCount;
        private (DateTimeOffset At, AiLimitsDetectedEnvironmentDto Value)? _envCache;

        private sealed class SourceRuntimeState
        {
            public string Status = AiLimitsSourceStatuses.AwaitingData;
            public string? ErrorCode;
            public string? StatusMessage;
            public string? DetectedApiVersion;
            public DateTimeOffset? LastCheckedAt;
            public DateTimeOffset? LastSyncedAt;
            public DateTimeOffset? BackoffUntil;
            public TimeSpan CurrentBackoff = TimeSpan.Zero;
            public bool AuthCircuitBroken;
            // Fingerprint of the URL + credential the circuit opened on; only a different one may retry.
            public string? AuthFingerprint;
            // Fingerprint of the most recent fetch attempt (backoff applies to that URL + credential).
            public string? LastFingerprint;
            public DateTimeOffset NextAutoPollAt = DateTimeOffset.MinValue;
            public DateTime? LastObservedFileWriteUtc;
            public List<AiLimitsAccountDto> Accounts = new();
        }

        public AiLimitsService(
            ILogger<AiLimitsService> logger,
            AiLimitsConfigStore store,
            IEnumerable<IAiLimitsSourceAdapter> adapters,
            ClaudeStatusLineAdapter claudeAdapter,
            IAiLimitsEnvironmentDetector envDetector,
            IHubContext<DeckHub>? hub = null,
            Func<DateTimeOffset>? clock = null,
            Func<int>? connectedClientsCount = null)
        {
            _logger = logger;
            _store = store;
            _claudeAdapter = claudeAdapter;
            _envDetector = envDetector;
            _hub = hub;
            _clock = clock ?? (() => DateTimeOffset.UtcNow);
            _connectedClientsCount = connectedClientsCount ?? (() => DeckHub.ConnectedCount);
            _adapters = adapters.ToDictionary(a => a.Kind, StringComparer.OrdinalIgnoreCase);
            _config = _store.LoadConfig();
        }

        public async Task<AiLimitsSnapshotResponse> GetSnapshotAsync(bool refreshEnv = false, CancellationToken ct = default)
        {
            var now = _clock();
            var detected = await GetDetectedEnvironmentAsync(refreshEnv, now, ct);
            return BuildSnapshot(detected, now);
        }

        public AiLimitsSnapshotResponse GetCachedSnapshotForHub()
        {
            var now = _clock();
            AiLimitsDetectedEnvironmentDto detected;
            lock (_envGate)
            {
                detected = _envCache?.Value ?? new AiLimitsDetectedEnvironmentDto();
            }
            return BuildSnapshot(detected, now);
        }

        public async Task<AiLimitsSourceTestResponse> TestSourceAsync(AiLimitsSourceTestRequest req, CancellationToken ct = default)
        {
            var now = _clock();
            var validationError = ValidateSourceRequest(req, out var normalizedUrl);
            if (validationError != null)
            {
                return new AiLimitsSourceTestResponse
                {
                    Ok = false,
                    Reachable = false,
                    Status = AiLimitsSourceStatuses.Error,
                    ErrorCode = validationError.Value.ErrorCode,
                    Message = validationError.Value.Message,
                };
            }

            if (!_adapters.TryGetValue(req.Kind, out var adapter))
            {
                return new AiLimitsSourceTestResponse
                {
                    Ok = false,
                    Reachable = false,
                    Status = AiLimitsSourceStatuses.Error,
                    ErrorCode = AiLimitsErrorCodes.InternalError,
                    Message = $"Unsupported source kind '{req.Kind}'.",
                };
            }

            var tempId = !string.IsNullOrWhiteSpace(req.SourceId) ? req.SourceId.Trim() : "test_preview";
            var secret = !string.IsNullOrWhiteSpace(req.Credential)
                ? req.Credential.Trim()
                : (!string.IsNullOrWhiteSpace(req.SourceId) ? _store.GetSecret(req.SourceId.Trim()) : null);

            var tempConfig = new AiLimitsSourceConfig
            {
                Id = tempId,
                Kind = req.Kind.Trim(),
                Label = string.IsNullOrWhiteSpace(req.Label) ? adapter.Descriptor.Title : req.Label.Trim(),
                Enabled = true,
                BaseUrl = normalizedUrl,
                AllowNonLoopback = req.AllowNonLoopback,
                ConfigDir = NullIfBlank(req.ConfigDir),
                SnapshotFile = NullIfBlank(req.SnapshotFile),
                CodexMode = NormalizeCodexMode(req.CodexMode),
                Provider = NullIfBlank(req.Provider),
                PlanLabel = NullIfBlank(req.PlanLabel),
                DashboardUrl = AiLimitsUrlValidator.ValidateDashboardUrl(req.DashboardUrl),
                DailyLimitHint = req.DailyLimitHint is > 0 ? req.DailyLimitHint : null,
                PollIntervalSeconds = 180,
            };

            // Testing a saved source with its stored key must not resend a key the proxy already
            // rejected, nor bypass a Retry-After the proxy asked for.
            if (!string.IsNullOrWhiteSpace(req.SourceId) && _runtime.TryGetValue(tempId, out var saved))
            {
                var sameFingerprint = saved.AuthFingerprint == CircuitFingerprint(tempConfig, secret);
                if (adapter.Descriptor.RequiresCredential && saved.AuthCircuitBroken && sameFingerprint)
                {
                    return new AiLimitsSourceTestResponse
                    {
                        Ok = false,
                        Reachable = true,
                        Status = AiLimitsSourceStatuses.AuthRequired,
                        ErrorCode = AiLimitsErrorCodes.AuthFailed,
                        Message = "This key was already rejected. Enter a corrected key or URL to test again.",
                    };
                }
                if (saved.BackoffUntil is { } until && now < until && saved.LastFingerprint == CircuitFingerprint(tempConfig, secret))
                {
                    return new AiLimitsSourceTestResponse
                    {
                        Ok = false,
                        Reachable = true,
                        Status = AiLimitsSourceStatuses.RateLimited,
                        ErrorCode = AiLimitsErrorCodes.CooldownActive,
                        Message = $"Source asked DeckOS to wait; try again in {Math.Max(1, (int)Math.Ceiling((until - now).TotalSeconds))}s.",
                    };
                }
            }

            var res = await adapter.FetchAsync(tempConfig, secret, now, ct);
            return new AiLimitsSourceTestResponse
            {
                Ok = res.Ok,
                Reachable = res.Reachable,
                Status = res.Status,
                ErrorCode = res.ErrorCode,
                Message = res.StatusMessage ?? (res.Ok ? "Connection succeeded." : "Connection failed."),
                DetectedApiVersion = res.DetectedApiVersion,
                CapabilitiesNote = res.CapabilitiesNote,
                Accounts = res.Accounts.Select(a => AiLimitsNormalizer.CloneWithCurrentFreshness(a, now)).ToList(),
            };
        }

        public async Task<(AiLimitsSourceDto? Source, List<AiLimitsAccountDto> Accounts, AiLimitsSnapshotResponse Snapshot, string? ErrorCode, string? ErrorMessage)> CreateSourceAsync(
            AiLimitsSourceUpsertRequest req,
            CancellationToken ct = default)
        {
            var err = ValidateSourceRequest(req, out var normalizedUrl);
            if (err != null)
                return (null, new(), await GetSnapshotAsync(false, ct), err.Value.ErrorCode, err.Value.Message);

            var adapter = _adapters[req.Kind.Trim()];
            var sourceId = AiLimitsConfigStore.NewSourceId();
            var cfg = new AiLimitsSourceConfig
            {
                Id = sourceId,
                Kind = adapter.Kind,
                Label = string.IsNullOrWhiteSpace(req.Label) ? DefaultSourceLabel(adapter, req) : req.Label.Trim(),
                Enabled = req.Enabled,
                BaseUrl = normalizedUrl,
                AllowNonLoopback = req.AllowNonLoopback,
                ConfigDir = NullIfBlank(req.ConfigDir),
                SnapshotFile = NullIfBlank(req.SnapshotFile),
                CodexMode = adapter.Kind == AiLimitsSourceKinds.CodexLocal ? NormalizeCodexMode(req.CodexMode) : null,
                Provider = adapter.Kind == AiLimitsSourceKinds.ManualDashboard ? AiLimitsProviders.Normalize(req.Provider) : NullIfBlank(req.Provider),
                PlanLabel = NullIfBlank(req.PlanLabel),
                DashboardUrl = AiLimitsUrlValidator.ValidateDashboardUrl(req.DashboardUrl),
                DailyLimitHint = req.DailyLimitHint is > 0 ? req.DailyLimitHint : null,
                PollIntervalSeconds = Math.Clamp(req.PollIntervalSeconds ?? 180, 60, 3600),
                CreatedAt = _clock(),
            };

            lock (_refreshGate)
            {
                _config.Sources.Add(cfg);
                _store.SaveConfig(_config);
            }

            if (!string.IsNullOrWhiteSpace(req.Credential))
                _store.SetSecret(sourceId, req.Credential);

            if (cfg.Enabled)
                await SyncSourceAsync(cfg, manual: true, ct);

            var snapshot = await GetSnapshotAsync(false, ct);
            await BroadcastAsync(snapshot);

            var dto = snapshot.Sources.FirstOrDefault(s => s.Id == sourceId);
            var accts = snapshot.Accounts.Where(a => a.SourceId == sourceId).ToList();
            return (dto, accts, snapshot, null, null);
        }

        public async Task<(AiLimitsSourceDto? Source, List<AiLimitsAccountDto> Accounts, AiLimitsSnapshotResponse Snapshot, string? ErrorCode, string? ErrorMessage, bool NotFound)> UpdateSourceAsync(
            string sourceId,
            AiLimitsSourceUpsertRequest req,
            CancellationToken ct = default)
        {
            AiLimitsSourceConfig? existing;
            lock (_refreshGate)
            {
                existing = _config.Sources.FirstOrDefault(s => s.Id == sourceId);
            }
            if (existing == null)
                return (null, new(), await GetSnapshotAsync(false, ct), "not_found", "Source not found.", true);

            if (string.IsNullOrWhiteSpace(req.Kind)) req.Kind = existing.Kind;
            var err = ValidateSourceRequest(req, out var normalizedUrl);
            if (err != null)
                return (null, new(), await GetSnapshotAsync(false, ct), err.Value.ErrorCode, err.Value.Message, false);

            var adapter = _adapters[req.Kind.Trim()];
            lock (_refreshGate)
            {
                existing.Kind = adapter.Kind;
                existing.Label = string.IsNullOrWhiteSpace(req.Label) ? existing.Label : req.Label.Trim();
                existing.Enabled = req.Enabled;
                existing.BaseUrl = normalizedUrl;
                existing.AllowNonLoopback = req.AllowNonLoopback;
                existing.ConfigDir = NullIfBlank(req.ConfigDir);
                existing.SnapshotFile = NullIfBlank(req.SnapshotFile);
                existing.CodexMode = adapter.Kind == AiLimitsSourceKinds.CodexLocal ? NormalizeCodexMode(req.CodexMode) : null;
                existing.Provider = adapter.Kind == AiLimitsSourceKinds.ManualDashboard ? AiLimitsProviders.Normalize(req.Provider) : NullIfBlank(req.Provider);
                existing.PlanLabel = NullIfBlank(req.PlanLabel);
                existing.DashboardUrl = AiLimitsUrlValidator.ValidateDashboardUrl(req.DashboardUrl);
                existing.DailyLimitHint = req.DailyLimitHint is > 0 ? req.DailyLimitHint : null;
                if (req.PollIntervalSeconds.HasValue)
                    existing.PollIntervalSeconds = Math.Clamp(req.PollIntervalSeconds.Value, 60, 3600);
                _store.SaveConfig(_config);
            }

            if (req.ClearCredential)
            {
                _store.DeleteSecret(sourceId);
            }
            else if (!string.IsNullOrWhiteSpace(req.Credential))
            {
                _store.SetSecret(sourceId, req.Credential);
            }

            // A changed URL or credential gets a fresh attempt; an unchanged rejected key stays closed
            // (SyncSourceAsync compares fingerprints) and an unchanged endpoint keeps its Retry-After.
            if (_runtime.TryGetValue(sourceId, out var st) &&
                st.LastFingerprint != CircuitFingerprint(existing, _store.GetSecret(sourceId)))
            {
                st.BackoffUntil = null;
                st.CurrentBackoff = TimeSpan.Zero;
            }

            if (existing.Enabled)
                await SyncSourceAsync(existing, manual: true, ct);
            else if (_runtime.TryGetValue(sourceId, out var disabledSt))
            {
                disabledSt.Status = AiLimitsSourceStatuses.Disabled;
                disabledSt.StatusMessage = "Source disabled.";
            }

            var snapshot = await GetSnapshotAsync(false, ct);
            await BroadcastAsync(snapshot);
            var dto = snapshot.Sources.FirstOrDefault(s => s.Id == sourceId);
            var accts = snapshot.Accounts.Where(a => a.SourceId == sourceId).ToList();
            return (dto, accts, snapshot, null, null, false);
        }

        public async Task<(bool Deleted, AiLimitsSnapshotResponse Snapshot)> DeleteSourceAsync(string sourceId, CancellationToken ct = default)
        {
            List<string> removedAccountIds = new();
            bool removed;
            lock (_refreshGate)
            {
                var idx = _config.Sources.FindIndex(s => s.Id == sourceId);
                removed = idx >= 0;
                if (removed)
                {
                    if (_runtime.TryGetValue(sourceId, out var rt))
                        removedAccountIds.AddRange(rt.Accounts.Select(a => a.Id));
                    _config.Sources.RemoveAt(idx);
                    foreach (var aid in removedAccountIds)
                    {
                        _config.AccountOverrides.Remove(aid);
                        _config.HiddenAccountIds.Remove(aid);
                    }
                    _store.SaveConfig(_config);
                }
            }

            if (removed)
            {
                _store.DeleteSecret(sourceId);
                _runtime.TryRemove(sourceId, out _);
                _sourceLocks.TryRemove(sourceId, out _);
            }

            var snapshot = await GetSnapshotAsync(false, ct);
            if (removed) await BroadcastAsync(snapshot);
            return (removed, snapshot);
        }

        public async Task<AiLimitsRefreshOutcome> ManualRefreshAsync(string? sourceId, CancellationToken ct = default)
        {
            var now = _clock();
            int cooldownSeconds;
            DateTimeOffset? blockedUntil = null;

            // A single source that asked for Retry-After (or is in error backoff) is not re-polled early.
            if (!string.IsNullOrWhiteSpace(sourceId) &&
                _runtime.TryGetValue(sourceId, out var srcRt) &&
                srcRt.BackoffUntil is { } backoffUntil && now < backoffUntil)
            {
                var wait = Math.Max(1, (int)Math.Ceiling((backoffUntil - now).TotalSeconds));
                return new AiLimitsRefreshOutcome(true, wait, backoffUntil, await GetSnapshotAsync(false, ct));
            }

            lock (_refreshGate)
            {
                cooldownSeconds = _config.ManualCooldownSeconds;
                if (_lastManualRefreshAt.HasValue)
                {
                    var nextAllowed = _lastManualRefreshAt.Value.AddSeconds(cooldownSeconds);
                    if (now < nextAllowed)
                        blockedUntil = nextAllowed;
                }
                if (blockedUntil == null)
                    _lastManualRefreshAt = now;
            }

            if (blockedUntil.HasValue)
            {
                var retryAfter = Math.Max(1, (int)Math.Ceiling((blockedUntil.Value - now).TotalSeconds));
                var cached = await GetSnapshotAsync(false, ct);
                return new AiLimitsRefreshOutcome(true, retryAfter, blockedUntil, cached);
            }

            List<AiLimitsSourceConfig> targets;
            lock (_refreshGate)
            {
                targets = string.IsNullOrWhiteSpace(sourceId)
                    ? _config.Sources.Where(s => s.Enabled).ToList()
                    : _config.Sources.Where(s => s.Id == sourceId && s.Enabled).ToList();
            }

            Interlocked.Increment(ref _activeRefreshCount);
            try
            {
                var tasks = targets.Select(src => SyncSourceAsync(src, manual: true, ct));
                await Task.WhenAll(tasks);
            }
            finally
            {
                Interlocked.Decrement(ref _activeRefreshCount);
            }

            var snapshot = await GetSnapshotAsync(refreshEnv: true, ct);
            await BroadcastAsync(snapshot);
            return new AiLimitsRefreshOutcome(false, null, now.AddSeconds(cooldownSeconds), snapshot);
        }

        public async Task<(AiLimitsAccountDto? Account, AiLimitsSnapshotResponse Snapshot)> UpdateAccountAsync(
            string accountId,
            AiLimitsAccountUpdateRequest req,
            CancellationToken ct = default)
        {
            var current = await GetSnapshotAsync(false, ct);
            if (current.Accounts.All(a => a.Id != accountId))
                return (null, current);

            lock (_refreshGate)
            {
                if (!_config.AccountOverrides.TryGetValue(accountId, out var ov))
                    _config.AccountOverrides[accountId] = ov = new AiLimitsAccountOverride();

                if (req.Alias != null)
                    ov.Alias = string.IsNullOrWhiteSpace(req.Alias) ? null : req.Alias.Trim();
                if (req.Enabled.HasValue)
                    ov.Enabled = req.Enabled.Value;
                if (req.Plan != null)
                    ov.Plan = string.IsNullOrWhiteSpace(req.Plan) ? null : req.Plan.Trim();
                if (req.DashboardUrl != null)
                    ov.DashboardUrl = string.IsNullOrWhiteSpace(req.DashboardUrl)
                        ? null
                        : AiLimitsUrlValidator.ValidateDashboardUrl(req.DashboardUrl);

                _store.SaveConfig(_config);
            }

            var snapshot = await GetSnapshotAsync(false, ct);
            await BroadcastAsync(snapshot);
            return (snapshot.Accounts.FirstOrDefault(a => a.Id == accountId), snapshot);
        }

        public async Task<(bool Removed, AiLimitsSnapshotResponse Snapshot)> RemoveAccountLocalAsync(string accountId, CancellationToken ct = default)
        {
            var current = await GetSnapshotAsync(false, ct);
            var target = current.Accounts.FirstOrDefault(a => a.Id == accountId);
            if (target == null)
                return (false, current);

            // For single-account manual_dashboard sources, deleting the account removes its local source entry.
            if (target.SourceKind == AiLimitsSourceKinds.ManualDashboard)
            {
                var (deleted, snap) = await DeleteSourceAsync(target.SourceId, ct);
                return (deleted, snap);
            }

            lock (_refreshGate)
            {
                _config.HiddenAccountIds.Add(accountId);
                _config.AccountOverrides.Remove(accountId);
                _store.SaveConfig(_config);
            }

            var snapshot = await GetSnapshotAsync(false, ct);
            await BroadcastAsync(snapshot);
            return (true, snapshot);
        }

        public AiLimitsSourceConfig? FindSourceConfig(string sourceId)
        {
            lock (_refreshGate)
            {
                return _config.Sources.FirstOrDefault(s => s.Id == sourceId);
            }
        }

        public AiLimitsSetupGuideResponse? GetSetupGuide(string sourceId, bool isLocalRequest)
        {
            var src = FindSourceConfig(sourceId);
            if (src == null) return null;

            if (src.Kind == AiLimitsSourceKinds.ClaudeStatusLine)
                return _claudeAdapter.GetSetupGuide(src, isLocalRequest);

            if (src.Kind == AiLimitsSourceKinds.CodexLocal)
            {
                return new AiLimitsSetupGuideResponse
                {
                    SourceId = src.Id,
                    Kind = src.Kind,
                    Supported = true,
                    IsInstalled = Directory.Exists(CodexLocalAdapter.ResolveCodexHome(src.ConfigDir)),
                    HasExistingUserHook = false,
                    CanAutoInstall = false,
                    Steps = new List<string>
                    {
                        "Install OpenAI Codex CLI (`codex`) and sign in with `codex login`.",
                        "DeckOS queries `codex app-server --listen stdio://` (`account/rateLimits/read`) with zero inference and falls back to passive `sessions/*.jsonl` logs.",
                        "For multiple Codex accounts, create separate `CODEX_HOME` directories and add each as its own Codex Local source.",
                    },
                    Caveats = new List<string>
                    {
                        "Codex `--profile` only overlays `config.toml` and does not isolate separate accounts; separate `CODEX_HOME` folders are required.",
                        "Pro plans currently have no 5-hour limit and report weekly limits only.",
                    },
                };
            }

            return new AiLimitsSetupGuideResponse
            {
                SourceId = src.Id,
                Kind = src.Kind,
                Supported = false,
                CanAutoInstall = false,
            };
        }

        public async Task<(AiLimitsSetupGuideResponse? Guide, AiLimitsSnapshotResponse Snapshot)> InstallClaudeHookAsync(string sourceId, CancellationToken ct = default)
        {
            var src = FindSourceConfig(sourceId);
            if (src == null || src.Kind != AiLimitsSourceKinds.ClaudeStatusLine)
                return (null, await GetSnapshotAsync(false, ct));

            var guide = _claudeAdapter.InstallHook(src);
            await SyncSourceAsync(src, manual: true, ct);
            var snapshot = await GetSnapshotAsync(refreshEnv: true, ct);
            await BroadcastAsync(snapshot);
            return (guide, snapshot);
        }

        public async Task<(AiLimitsSetupGuideResponse? Guide, AiLimitsSnapshotResponse Snapshot)> UninstallClaudeHookAsync(string sourceId, CancellationToken ct = default)
        {
            var src = FindSourceConfig(sourceId);
            if (src == null || src.Kind != AiLimitsSourceKinds.ClaudeStatusLine)
                return (null, await GetSnapshotAsync(false, ct));

            var guide = _claudeAdapter.UninstallHook(src);
            await SyncSourceAsync(src, manual: true, ct);
            var snapshot = await GetSnapshotAsync(refreshEnv: true, ct);
            await BroadcastAsync(snapshot);
            return (guide, snapshot);
        }

        public async Task<(bool Ok, AiLimitsSnapshotResponse Snapshot)> IngestClaudeStatusLineAsync(string sourceId, string rawJson, CancellationToken ct = default)
        {
            var src = FindSourceConfig(sourceId);
            if (src == null || src.Kind != AiLimitsSourceKinds.ClaudeStatusLine)
                return (false, await GetSnapshotAsync(false, ct));

            _claudeAdapter.IngestSanitizedPayload(src, rawJson, _clock());
            await SyncSourceAsync(src, manual: true, ct);
            var snapshot = await GetSnapshotAsync(false, ct);
            await BroadcastAsync(snapshot);
            return (true, snapshot);
        }

        /// <summary>
        /// Safe projection for legacy `ai_usage` tiles in InfoService so legacy tiles stay
        /// unbroken using ONLY official/passive snapshots (zero undocumented /api/oauth/usage polling).
        /// </summary>
        public AiUsageService.Plan? TryGetLegacyPlan(string provider)
        {
            var normalized = AiLimitsProviders.Normalize(provider);
            var now = _clock();
            var candidates = _runtime.Values
                .SelectMany(rt => rt.Accounts)
                .Where(a => a.Provider == normalized && a.Enabled)
                .Select(a => AiLimitsNormalizer.CloneWithCurrentFreshness(a, now))
                .Where(a => a.Windows.Any(w => w.UsedPercent.HasValue))
                .OrderByDescending(a => AuthorityRank(a.SupportLevel))
                .ThenByDescending(a => a.ObservedAt ?? DateTimeOffset.MinValue)
                .ToList();

            var best = candidates.FirstOrDefault();
            if (best == null) return null;

            var w5 = best.Windows.FirstOrDefault(w => w.Kind == AiLimitsWindowKinds.FiveHour && w.UsedPercent.HasValue);
            var w7 = best.Windows.FirstOrDefault(w => w.Kind == AiLimitsWindowKinds.Weekly && w.UsedPercent.HasValue);
            if (w5 == null && w7 == null) return null;

            return new AiUsageService.Plan(
                w5 != null ? new AiUsageService.Window(w5.UsedPercent!.Value, w5.ResetsAt) : null,
                w7 != null ? new AiUsageService.Window(w7.UsedPercent!.Value, w7.ResetsAt) : null);
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            // Initial safe sync of already configured sources once at startup.
            try
            {
                List<AiLimitsSourceConfig> initial;
                lock (_refreshGate) initial = _config.Sources.Where(s => s.Enabled).ToList();
                if (initial.Count > 0)
                {
                    await Task.WhenAll(initial.Select(s => SyncSourceAsync(s, manual: false, stoppingToken)));
                    var snap = await GetSnapshotAsync(false, stoppingToken);
                    await BroadcastAsync(snap);
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogDebug(ex, "AiLimits: initial startup sync encountered an error");
            }

            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    // Pause background polling when no Deck clients are connected (no background hammering).
                    if (_connectedClientsCount() > 0)
                    {
                        var now = _clock();
                        List<AiLimitsSourceConfig> sources;
                        lock (_refreshGate) sources = _config.Sources.Where(s => s.Enabled).ToList();

                        var anyUpdated = false;
                        foreach (var src in sources)
                        {
                            var rt = _runtime.GetOrAdd(src.Id, _ => new SourceRuntimeState());
                            if (rt.AuthCircuitBroken) continue;
                            if (rt.BackoffUntil.HasValue && now < rt.BackoffUntil.Value) continue;

                            var passiveFileChanged = HasPassiveFileChanged(src, rt);
                            if (!passiveFileChanged && now < rt.NextAutoPollAt) continue;

                            await SyncSourceAsync(src, manual: false, stoppingToken);
                            anyUpdated = true;
                        }

                        if (anyUpdated)
                        {
                            var snap = await GetSnapshotAsync(false, stoppingToken);
                            await BroadcastAsync(snap);
                        }
                    }
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    _logger.LogDebug(ex, "AiLimits: background loop warning");
                }

                try { await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken); }
                catch (TaskCanceledException) { }
            }
        }

        private bool HasPassiveFileChanged(AiLimitsSourceConfig src, SourceRuntimeState rt)
        {
            string? file = src.Kind switch
            {
                AiLimitsSourceKinds.ClaudeStatusLine => _claudeAdapter.ResolveSnapshotPath(src),
                AiLimitsSourceKinds.GeminiLocalOtel => GeminiOtelAdapter.ResolveTelemetryPath(src),
                _ => null,
            };
            if (string.IsNullOrEmpty(file) || !File.Exists(file)) return false;
            try
            {
                var writeUtc = File.GetLastWriteTimeUtc(file);
                if (!rt.LastObservedFileWriteUtc.HasValue || writeUtc > rt.LastObservedFileWriteUtc.Value)
                {
                    rt.LastObservedFileWriteUtc = writeUtc;
                    return true;
                }
            }
            catch { }
            return false;
        }

        private async Task SyncSourceAsync(AiLimitsSourceConfig source, bool manual, CancellationToken ct)
        {
            if (!_adapters.TryGetValue(source.Kind, out var adapter)) return;

            var sourceLock = _sourceLocks.GetOrAdd(source.Id, _ => new SemaphoreSlim(1, 1));
            // Single-flight coalescing per source: if a sync is already running, await it without duplicating work.
            if (!await sourceLock.WaitAsync(0, ct))
            {
                await sourceLock.WaitAsync(ct);
                sourceLock.Release();
                return;
            }

            try
            {
                var rt = _runtime.GetOrAdd(source.Id, _ => new SourceRuntimeState());
                var now = _clock();
                var secret = _store.GetSecret(source.Id);
                var fingerprint = CircuitFingerprint(source, secret);

                if (rt.AuthCircuitBroken)
                {
                    // Credential sources (CLIProxyAPI) never resend a rejected URL + key, manual or automatic:
                    // repeated failures get the PC IP-banned. Local official sources (e.g. `codex login`
                    // fixed outside DeckOS) may retry on an explicit manual refresh only.
                    var sameAttempt = rt.AuthFingerprint == fingerprint;
                    if (adapter.Descriptor.RequiresCredential ? sameAttempt : !manual) return;
                }
                if (rt.BackoffUntil.HasValue && now < rt.BackoffUntil.Value && rt.LastFingerprint == fingerprint) return;

                await _globalConcurrency.WaitAsync(ct);
                try
                {
                    rt.LastFingerprint = fingerprint;
                    var res = await adapter.FetchAsync(source, secret, now, ct);

                    rt.LastCheckedAt = now;
                    rt.Status = res.Status;
                    rt.ErrorCode = res.ErrorCode;
                    rt.StatusMessage = res.StatusMessage;
                    if (!string.IsNullOrEmpty(res.DetectedApiVersion))
                        rt.DetectedApiVersion = res.DetectedApiVersion;

                    if (res.AuthCircuitBreak)
                    {
                        // Circuit breaker: stop on the first 401/403 until the URL or credential changes.
                        rt.AuthCircuitBroken = true;
                        rt.AuthFingerprint = fingerprint;
                        rt.BackoffUntil = null;
                        rt.CurrentBackoff = TimeSpan.Zero;
                        MarkAccountsAuthRequired(rt.Accounts, res.StatusMessage);
                    }
                    else if (!res.Ok && (res.RetryAfter.HasValue || res.ErrorCode is AiLimitsErrorCodes.RateLimited or AiLimitsErrorCodes.Unreachable or AiLimitsErrorCodes.Timeout))
                    {
                        rt.AuthCircuitBroken = false;
                        var baseDelay = res.RetryAfter
                            ?? (rt.CurrentBackoff == TimeSpan.Zero
                                ? TimeSpan.FromSeconds(60)
                                : TimeSpan.FromTicks(Math.Min(rt.CurrentBackoff.Ticks * 2, MaxBackoff.Ticks)));
                        var jittered = ApplyJitter(baseDelay);
                        rt.CurrentBackoff = jittered;
                        rt.BackoffUntil = now + jittered;
                        rt.NextAutoPollAt = rt.BackoffUntil.Value;
                        // Retain last-known-good accounts during transient backoff instead of erasing them!
                        if (res.Accounts.Count > 0)
                            rt.Accounts = res.Accounts;
                        foreach (var a in rt.Accounts)
                            a.BackoffUntil = rt.BackoffUntil;
                    }
                    else
                    {
                        rt.AuthCircuitBroken = false;
                        rt.CurrentBackoff = TimeSpan.Zero;
                        rt.BackoffUntil = null;
                        rt.LastSyncedAt = res.Ok ? now : rt.LastSyncedAt;
                        rt.NextAutoPollAt = now.AddSeconds(Math.Clamp(source.PollIntervalSeconds, 60, 3600));
                        rt.Accounts = res.Accounts;
                    }
                }
                finally
                {
                    _globalConcurrency.Release();
                }
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _logger.LogDebug(ex, "AiLimits: source {SourceId} sync failed", source.Id);
                var rt = _runtime.GetOrAdd(source.Id, _ => new SourceRuntimeState());
                rt.LastCheckedAt = _clock();
                rt.Status = AiLimitsSourceStatuses.Error;
                rt.ErrorCode = AiLimitsErrorCodes.InternalError;
                rt.StatusMessage = "Source refresh failed.";
            }
            finally
            {
                sourceLock.Release();
            }
        }

        private static void MarkAccountsAuthRequired(List<AiLimitsAccountDto> accounts, string? message)
        {
            foreach (var a in accounts)
            {
                a.ConnectionStatus = AiLimitsConnectionStatuses.AuthRequired;
                a.QuotaStatus = AiLimitsQuotaStatuses.AuthRequired;
                a.ErrorCode = AiLimitsErrorCodes.AuthFailed;
                a.StatusMessage = message ?? "Authentication required.";
                foreach (var w in a.Windows)
                {
                    if (w.Status == AiLimitsWindowStatuses.Available)
                        w.Status = AiLimitsWindowStatuses.AuthRequired;
                }
            }
        }

        private AiLimitsSnapshotResponse BuildSnapshot(AiLimitsDetectedEnvironmentDto detected, DateTimeOffset now)
        {
            List<AiLimitsSourceConfig> sources;
            Dictionary<string, AiLimitsAccountOverride> overrides;
            HashSet<string> hidden;
            int autoInterval;
            int cooldown;
            DateTimeOffset? nextRefresh;

            lock (_refreshGate)
            {
                sources = _config.Sources.ToList();
                overrides = _config.AccountOverrides.ToDictionary(kv => kv.Key, kv => kv.Value, StringComparer.Ordinal);
                hidden = new HashSet<string>(_config.HiddenAccountIds, StringComparer.Ordinal);
                autoInterval = _config.AutoRefreshIntervalSeconds;
                cooldown = _config.ManualCooldownSeconds;
                nextRefresh = _lastManualRefreshAt.HasValue && now < _lastManualRefreshAt.Value.AddSeconds(cooldown)
                    ? _lastManualRefreshAt.Value.AddSeconds(cooldown)
                    : null;
            }

            var sourceDtos = new List<AiLimitsSourceDto>(sources.Count);
            var accountDtos = new List<AiLimitsAccountDto>();

            foreach (var src in sources)
            {
                _adapters.TryGetValue(src.Kind, out var adapter);
                var rt = _runtime.GetOrAdd(src.Id, _ => new SourceRuntimeState
                {
                    Status = src.Enabled ? AiLimitsSourceStatuses.AwaitingData : AiLimitsSourceStatuses.Disabled,
                });

                var visibleAccounts = new List<AiLimitsAccountDto>();
                foreach (var rawAcct in rt.Accounts)
                {
                    if (hidden.Contains(rawAcct.Id)) continue;
                    var acct = AiLimitsNormalizer.CloneWithCurrentFreshness(rawAcct, now);
                    if (overrides.TryGetValue(acct.Id, out var ov))
                    {
                        if (!string.IsNullOrWhiteSpace(ov.Alias)) acct.Alias = ov.Alias;
                        if (ov.Enabled.HasValue) acct.Enabled = ov.Enabled.Value;
                        if (!string.IsNullOrWhiteSpace(ov.Plan)) acct.Plan = ov.Plan;
                        if (!string.IsNullOrWhiteSpace(ov.DashboardUrl)) acct.DashboardUrl = ov.DashboardUrl;
                    }
                    if (!src.Enabled)
                    {
                        acct.Enabled = false;
                        acct.ConnectionStatus = AiLimitsConnectionStatuses.Disabled;
                    }
                    visibleAccounts.Add(acct);
                }

                int? retrySec = rt.BackoffUntil.HasValue && rt.BackoffUntil.Value > now
                    ? Math.Max(1, (int)Math.Ceiling((rt.BackoffUntil.Value - now).TotalSeconds))
                    : null;

                sourceDtos.Add(new AiLimitsSourceDto
                {
                    Id = src.Id,
                    Kind = src.Kind,
                    Label = src.Label,
                    Enabled = src.Enabled,
                    AccessMode = adapter?.Descriptor.AccessMode ?? AiLimitsAccessModes.ManualDashboard,
                    SupportLevel = adapter?.Descriptor.AccessMode ?? AiLimitsAccessModes.ManualDashboard,
                    HasCredential = _store.HasSecret(src.Id),
                    BaseUrl = src.BaseUrl,
                    AllowNonLoopback = src.AllowNonLoopback,
                    ConfigDir = src.ConfigDir,
                    SnapshotFile = src.SnapshotFile,
                    CodexMode = src.CodexMode,
                    Provider = src.Provider,
                    PlanLabel = src.PlanLabel,
                    DashboardUrl = src.DashboardUrl,
                    DailyLimitHint = src.DailyLimitHint,
                    PollIntervalSeconds = src.PollIntervalSeconds,
                    Status = src.Enabled ? rt.Status : AiLimitsSourceStatuses.Disabled,
                    ErrorCode = src.Enabled ? rt.ErrorCode : null,
                    StatusMessage = src.Enabled ? rt.StatusMessage : "Disabled",
                    DetectedApiVersion = rt.DetectedApiVersion,
                    LastCheckedAt = rt.LastCheckedAt,
                    LastSyncedAt = rt.LastSyncedAt,
                    BackoffUntil = rt.BackoffUntil,
                    RetryAfterSeconds = retrySec,
                    AccountCount = visibleAccounts.Count,
                });

                accountDtos.AddRange(visibleAccounts);
            }

            return new AiLimitsSnapshotResponse
            {
                SchemaVersion = 1,
                GeneratedAt = now,
                Capabilities = new AiLimitsCapabilitiesDto
                {
                    Platform = CurrentPlatform(),
                    ClaudeStatusLineInstallerAvailable = true,
                    Detected = detected,
                    SupportedSourceKinds = _adapters.Values
                        .Select(a => a.Descriptor)
                        .OrderBy(d => DescriptorOrder(d.Kind))
                        .ToList(),
                },
                Refresh = new AiLimitsRefreshPolicyDto
                {
                    CooldownSeconds = cooldown,
                    NextRefreshAllowedAt = nextRefresh,
                    AutoRefreshIntervalSeconds = autoInterval,
                    IsRefreshing = Volatile.Read(ref _activeRefreshCount) > 0,
                },
                Sources = sourceDtos,
                Accounts = accountDtos,
            };
        }

        private async Task<AiLimitsDetectedEnvironmentDto> GetDetectedEnvironmentAsync(bool forceRefresh, DateTimeOffset now, CancellationToken ct)
        {
            if (!forceRefresh)
            {
                lock (_envGate)
                {
                    if (_envCache is { } cached && now - cached.At < EnvCacheTtl)
                        return cached.Value;
                }
            }

            var value = await _envDetector.DetectAsync(ct);
            lock (_envGate)
            {
                _envCache = (now, value);
            }
            return value;
        }

        private async Task BroadcastAsync(AiLimitsSnapshotResponse snapshot)
        {
            if (_hub == null) return;
            try
            {
                await _hub.Clients.All.SendAsync(HubEvent, snapshot);
            }
            catch { }
        }

        private (string ErrorCode, string Message)? ValidateSourceRequest(AiLimitsSourceTestRequest req, out string? normalizedUrl)
        {
            normalizedUrl = null;
            if (req == null || string.IsNullOrWhiteSpace(req.Kind) || !_adapters.ContainsKey(req.Kind.Trim()))
                return (AiLimitsErrorCodes.InternalError, "Select a supported AI Limits source kind.");

            var kind = req.Kind.Trim();
            if (kind == AiLimitsSourceKinds.CliProxyPassive)
            {
                var check = AiLimitsUrlValidator.ValidateSourceUrl(req.BaseUrl, req.AllowNonLoopback);
                if (!check.Ok || check.NormalizedUri == null)
                    return (check.ErrorCode ?? AiLimitsErrorCodes.InvalidUrl, check.ErrorMessage ?? "Invalid URL.");
                normalizedUrl = check.NormalizedUri.ToString().TrimEnd('/');
            }

            if (!string.IsNullOrWhiteSpace(req.DashboardUrl) && AiLimitsUrlValidator.ValidateDashboardUrl(req.DashboardUrl) == null)
                return (AiLimitsErrorCodes.InvalidUrl, "Dashboard URL must be a valid https:// URL without embedded credentials.");

            return null;
        }

        private static string DefaultSourceLabel(IAiLimitsSourceAdapter adapter, AiLimitsSourceTestRequest req)
        {
            if (adapter.Kind == AiLimitsSourceKinds.ManualDashboard && !string.IsNullOrWhiteSpace(req.Provider))
                return AiLimitsProviders.DisplayLabel(AiLimitsProviders.Normalize(req.Provider));
            return adapter.Descriptor.Title;
        }

        /// <summary>Opaque in-memory fingerprint of what a fetch would send (never persisted or logged).</summary>
        private static string CircuitFingerprint(AiLimitsSourceConfig source, string? secret) =>
            CliProxyPassiveAdapter.ComputeCredentialFingerprint(
                $"{source.Kind}|{source.BaseUrl}|{source.AllowNonLoopback}|{source.ConfigDir}",
                secret?.Trim() ?? string.Empty);

        private static string NormalizeCodexMode(string? mode) =>
            string.Equals(mode, CodexLocalAdapter.ModeLogsOnly, StringComparison.OrdinalIgnoreCase)
                ? CodexLocalAdapter.ModeLogsOnly
                : CodexLocalAdapter.ModeRpcWithFallback;

        private static string? NullIfBlank(string? s) =>
            string.IsNullOrWhiteSpace(s) ? null : s.Trim();

        private static string CurrentPlatform() =>
            OperatingSystem.IsWindows() ? "windows"
            : OperatingSystem.IsMacOS() ? "macos"
            : OperatingSystem.IsLinux() ? "linux"
            : "other";

        private static int DescriptorOrder(string kind) => kind switch
        {
            AiLimitsSourceKinds.CliProxyPassive => 0,
            AiLimitsSourceKinds.CodexLocal => 1,
            AiLimitsSourceKinds.ClaudeStatusLine => 2,
            AiLimitsSourceKinds.GeminiLocalOtel => 3,
            AiLimitsSourceKinds.ManualDashboard => 4,
            _ => 10,
        };

        private static int AuthorityRank(string supportLevel) => supportLevel switch
        {
            AiLimitsAccessModes.OfficialLocalRpc => 4,
            AiLimitsAccessModes.OfficialLocalHook => 3,
            AiLimitsAccessModes.PassiveLocalFile => 2,
            AiLimitsAccessModes.PassiveLocalProxy => 1,
            _ => 0,
        };

        private static TimeSpan ApplyJitter(TimeSpan delay)
        {
            // ±15% bounded jitter
            var factor = 0.85 + Random.Shared.NextDouble() * 0.30;
            var ms = Math.Clamp(delay.TotalMilliseconds * factor, 1000, MaxBackoff.TotalMilliseconds);
            return TimeSpan.FromMilliseconds(ms);
        }
    }
}
