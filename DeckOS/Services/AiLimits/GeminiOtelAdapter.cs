using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Models;

namespace DeckOS.Services.AiLimits
{
    /// <summary>
    /// Official Google Gemini CLI local OpenTelemetry passive observer.
    /// Reads ONLY local telemetry outfile (GEMINI_TELEMETRY_ENABLED=true) to count daily
    /// requests on this device. NEVER fabricates 5h/weekly caps or authoritative remaining %.
    /// </summary>
    public sealed class GeminiOtelAdapter : IAiLimitsSourceAdapter
    {
        private const long MaxTailBytes = 16L * 1024 * 1024;

        public string Kind => AiLimitsSourceKinds.GeminiLocalOtel;

        public AiLimitsSourceKindDescriptorDto Descriptor => new()
        {
            Kind = Kind,
            Title = "Gemini CLI (Local Telemetry)",
            Description = "Counts local daily Gemini CLI requests from official local OpenTelemetry logs (`GEMINI_TELEMETRY_ENABLED=true`). Local device activity only.",
            AccessMode = AiLimitsAccessModes.PassiveLocalFile,
            RequiresCredential = false,
            SupportsMultiAccount = true,
            SupportsGuidedSetup = false,
            SupportsTestConnection = true,
            ProvenanceNote = "Gemini CLI uses daily RPD rather than 5h/weekly caps and exposes local OpenTelemetry only. Remaining server quota across other devices stays unknown.",
        };

        public static string ResolveTelemetryPath(AiLimitsSourceConfig source)
        {
            if (!string.IsNullOrWhiteSpace(source.SnapshotFile))
                return source.SnapshotFile.Trim();

            var dir = !string.IsNullOrWhiteSpace(source.ConfigDir)
                ? source.ConfigDir.Trim()
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".gemini");
            return Path.Combine(dir, "telemetry.log");
        }

        public Task<AiLimitsAdapterResult> FetchAsync(
            AiLimitsSourceConfig source,
            string? secret,
            DateTimeOffset now,
            CancellationToken ct)
        {
            var path = ResolveTelemetryPath(source);
            var alias = string.IsNullOrWhiteSpace(source.Label) ? "Personal" : source.Label.Trim();

            if (!File.Exists(path))
            {
                var placeholder = BuildAccount(source, alias, 0, null, hasData: false, now);
                return Task.FromResult(new AiLimitsAdapterResult
                {
                    Ok = false,
                    Reachable = Directory.Exists(Path.GetDirectoryName(path) ?? string.Empty),
                    Status = AiLimitsSourceStatuses.SetupRequired,
                    ErrorCode = AiLimitsErrorCodes.NoDataYet,
                    StatusMessage = "Gemini CLI telemetry log not found. Enable local OpenTelemetry (`GEMINI_TELEMETRY_ENABLED=true`, local outfile) to count local daily requests.",
                    DetectedApiVersion = "gemini-otel",
                    Accounts = new List<AiLimitsAccountDto> { placeholder },
                });
            }

            try
            {
                var (todayRequests, lastObserved) = CountTodayRequests(path, now);
                var account = BuildAccount(source, alias, todayRequests, lastObserved, hasData: true, now);
                return Task.FromResult(new AiLimitsAdapterResult
                {
                    Ok = true,
                    Reachable = true,
                    Status = AiLimitsSourceStatuses.Connected,
                    StatusMessage = $"Observed {todayRequests} local Gemini CLI requests today.",
                    DetectedApiVersion = "gemini-otel",
                    CapabilitiesNote = "Local device request count only; authoritative server remaining RPD is not exposed by Gemini CLI.",
                    Accounts = new List<AiLimitsAccountDto> { account },
                });
            }
            catch
            {
                return Task.FromResult(new AiLimitsAdapterResult
                {
                    Ok = false,
                    Reachable = true,
                    Status = AiLimitsSourceStatuses.Error,
                    ErrorCode = AiLimitsErrorCodes.InternalError,
                    StatusMessage = "Could not read Gemini CLI local telemetry file.",
                });
            }
        }

        public static (int TodayRequests, DateTimeOffset? LastObserved) CountTodayRequests(string filePath, DateTimeOffset now)
        {
            var startOfDayUtc = new DateTimeOffset(now.UtcDateTime.Date, TimeSpan.Zero);
            var count = 0;
            DateTimeOffset? latest = null;

            using var fs = new FileStream(filePath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            // Telemetry outfiles grow without bound; today's events are at the end, so read only the tail.
            if (fs.Length > MaxTailBytes)
                fs.Seek(-MaxTailBytes, SeekOrigin.End);
            using var sr = new StreamReader(fs, Encoding.UTF8);
            if (fs.Position > 0) sr.ReadLine(); // drop the partial first line
            string? line;
            while ((line = sr.ReadLine()) != null)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                if (!line.Contains("api_request", StringComparison.OrdinalIgnoreCase) &&
                    !line.Contains("gemini_cli.api.request", StringComparison.OrdinalIgnoreCase) &&
                    !line.Contains("gen_ai.client.operation", StringComparison.OrdinalIgnoreCase))
                    continue;

                if (TryExtractTimestamp(line, out var ts))
                {
                    if (ts >= startOfDayUtc && ts <= now.AddMinutes(5))
                    {
                        count++;
                        if (!latest.HasValue || ts > latest.Value) latest = ts;
                    }
                }
            }

            if (!latest.HasValue)
            {
                try { latest = new DateTimeOffset(File.GetLastWriteTimeUtc(filePath), TimeSpan.Zero); } catch { }
            }

            return (count, latest);
        }

        private static bool TryExtractTimestamp(string line, out DateTimeOffset ts)
        {
            ts = default;
            try
            {
                using var doc = JsonDocument.Parse(line);
                var root = doc.RootElement;
                foreach (var prop in new[] { "timestamp", "time", "observedAt", "startTimeUnixNano", "timeUnixNano" })
                {
                    if (!root.TryGetProperty(prop, out var el)) continue;
                    if (el.ValueKind == JsonValueKind.String)
                    {
                        var s = el.GetString();
                        if (long.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var nanos) && nanos > 1_000_000_000_000_000L)
                        {
                            ts = DateTimeOffset.FromUnixTimeMilliseconds(nanos / 1_000_000L);
                            return true;
                        }
                        if (DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsed))
                        {
                            ts = parsed.ToUniversalTime();
                            return true;
                        }
                    }
                    else if (el.ValueKind == JsonValueKind.Number && el.TryGetInt64(out var num) && num > 0)
                    {
                        ts = num > 1_000_000_000_000_000L
                            ? DateTimeOffset.FromUnixTimeMilliseconds(num / 1_000_000L)
                            : num > 1_000_000_000_000L
                                ? DateTimeOffset.FromUnixTimeMilliseconds(num)
                                : DateTimeOffset.FromUnixTimeSeconds(num);
                        return true;
                    }
                }
            }
            catch { }
            return false;
        }

        private static AiLimitsAccountDto BuildAccount(
            AiLimitsSourceConfig source,
            string alias,
            int todayRequests,
            DateTimeOffset? observedAt,
            bool hasData,
            DateTimeOffset now)
        {
            var windows = new List<AiLimitsWindowDto>
            {
                AiLimitsNormalizer.BuildUnavailableWindow(
                    "five_hour",
                    AiLimitsWindowKinds.FiveHour,
                    "5h Limit",
                    300,
                    AiLimitsWindowStatuses.NotApplicable,
                    "Daily RPD model (no 5h window)"),
                AiLimitsNormalizer.BuildUnavailableWindow(
                    "weekly",
                    AiLimitsWindowKinds.Weekly,
                    "Weekly",
                    10080,
                    AiLimitsWindowStatuses.NotApplicable,
                    "Daily RPD model (no weekly window)"),
                new AiLimitsWindowDto
                {
                    Id = "daily_requests",
                    Kind = AiLimitsWindowKinds.Daily,
                    Label = "Daily Requests (Local)",
                    WindowMinutes = 1440,
                    Unit = AiLimitsWindowUnits.Requests,
                    Status = hasData ? AiLimitsWindowStatuses.Available : AiLimitsWindowStatuses.NotConnected,
                    // Invariant: NEVER pretend local OTel count is authoritative server remaining %!
                    UsedPercent = null,
                    RemainingPercent = null,
                    Used = hasData ? todayRequests : null,
                    Limit = source.DailyLimitHint is > 0 ? source.DailyLimitHint.Value : null,
                    // The provider's daily reset time isn't exposed locally; the count covers the current UTC day.
                    ResetsAt = null,
                    ModelPool = "all",
                    Note = hasData ? "Local device count since 00:00 UTC" : "Enable GEMINI_TELEMETRY_ENABLED=true",
                },
            };

            return new AiLimitsAccountDto
            {
                Id = AiLimitsConfigStore.DeriveOpaqueAccountId(source.Id, "otel|gemini_cli"),
                SourceId = source.Id,
                SourceKind = AiLimitsSourceKinds.GeminiLocalOtel,
                Provider = AiLimitsProviders.GeminiCli,
                Product = "gemini_cli",
                ProviderLabel = "Gemini CLI",
                Alias = alias,
                DefaultAlias = alias,
                Plan = source.PlanLabel,
                ModelPool = "all",
                Enabled = true,
                ConnectionStatus = hasData ? AiLimitsConnectionStatuses.Connected : AiLimitsConnectionStatuses.SetupRequired,
                QuotaStatus = hasData ? AiLimitsQuotaStatuses.LocalOnly : AiLimitsQuotaStatuses.AwaitingData,
                Freshness = hasData ? AiLimitsFreshness.LocalOnly : AiLimitsFreshness.Unavailable,
                SupportLevel = AiLimitsAccessModes.PassiveLocalFile,
                CoverageScope = AiLimitsCoverageScopes.LocalDeviceActivityOnly,
                ProvenanceLabel = "Gemini CLI · Local OTel",
                ProvenanceDetails = "Counts local requests emitted to Gemini CLI's official OpenTelemetry outfile. Does not know usage from other devices or authoritative server remaining RPD.",
                ObservedAt = observedAt,
                DashboardUrl = AiLimitsUrlValidator.ValidateDashboardUrl(source.DashboardUrl) ?? AiLimitsProviders.OfficialDashboardUrl(AiLimitsProviders.GeminiCli),
                StatusMessage = hasData ? null : "Configure GEMINI_TELEMETRY_ENABLED=true with a local outfile.",
                Windows = AiLimitsNormalizer.OrderWindows(windows),
            };
        }
    }

    /// <summary>
    /// Honest fallback adapter for providers/subscriptions without a safe, provider-supported
    /// programmatic quota API (e.g., Antigravity, Gemini Web, Cursor Personal, Windsurf Personal,
    /// GitHub Copilot Personal). Never fabricates percentages or polls undocumented endpoints.
    /// </summary>
    public sealed class ManualDashboardAdapter : IAiLimitsSourceAdapter
    {
        public string Kind => AiLimitsSourceKinds.ManualDashboard;

        public AiLimitsSourceKindDescriptorDto Descriptor => new()
        {
            Kind = Kind,
            Title = "Official Dashboard Link",
            Description = "Honest manual card with one-tap link to your provider's official usage page when no safe programmatic quota API exists.",
            AccessMode = AiLimitsAccessModes.ManualDashboard,
            RequiresCredential = false,
            SupportsMultiAccount = true,
            SupportsGuidedSetup = false,
            SupportsTestConnection = true,
            ProvenanceNote = "Zero API calls or credentials. Displays honest unavailable windows and links directly to the official provider billing/usage dashboard.",
        };

        public Task<AiLimitsAdapterResult> FetchAsync(
            AiLimitsSourceConfig source,
            string? secret,
            DateTimeOffset now,
            CancellationToken ct)
        {
            var provider = AiLimitsProviders.Normalize(source.Provider);
            var providerLabel = AiLimitsProviders.DisplayLabel(provider);
            var alias = string.IsNullOrWhiteSpace(source.Label) ? "Personal" : source.Label.Trim();
            var dashboardUrl = AiLimitsUrlValidator.ValidateDashboardUrl(source.DashboardUrl)
                ?? AiLimitsProviders.OfficialDashboardUrl(provider);

            var (fiveHourStatus, fiveHourNote, weeklyStatus, weeklyNote, detailNote) = provider switch
            {
                AiLimitsProviders.Antigravity => (
                    AiLimitsWindowStatuses.Unavailable, "No official quota API (check /quota)",
                    AiLimitsWindowStatuses.Unavailable, "No official quota API (check /quota)",
                    "Google Antigravity uses 5h and weekly pools on AI Pro/Ultra (weekly-only on Free) without a documented public quota API."),
                AiLimitsProviders.GeminiWeb => (
                    AiLimitsWindowStatuses.Unavailable, "Web UI only (gemini.google.com/usage)",
                    AiLimitsWindowStatuses.Unavailable, "Web UI only (gemini.google.com/usage)",
                    "Gemini consumer web apps expose usage only on gemini.google.com/usage."),
                AiLimitsProviders.Copilot => (
                    AiLimitsWindowStatuses.NotApplicable, "Monthly AI Credits model",
                    AiLimitsWindowStatuses.NotApplicable, "Monthly AI Credits model",
                    "GitHub Copilot uses monthly AI Credits rather than 5h/weekly caps. Check GitHub billing for remaining allowance."),
                AiLimitsProviders.Cursor => (
                    AiLimitsWindowStatuses.NotApplicable, "No 5h window",
                    AiLimitsWindowStatuses.Unavailable, "Teams/Enterprise API only",
                    "Personal Cursor subscriptions use a weekly Cursor/Grok pool plus prepaid 3P credits without a personal quota API."),
                AiLimitsProviders.Windsurf => (
                    AiLimitsWindowStatuses.NotApplicable, "Daily + weekly token budgets",
                    AiLimitsWindowStatuses.Unavailable, "Enterprise API only",
                    "Windsurf / Devin Desktop uses daily and weekly token budgets with official APIs limited to Enterprise plans."),
                _ => (
                    AiLimitsWindowStatuses.Unavailable, "No official programmatic API",
                    AiLimitsWindowStatuses.Unavailable, "No official programmatic API",
                    "No provider-supported quota API is configured for this account. Open the official dashboard to inspect live limits."),
            };

            var account = new AiLimitsAccountDto
            {
                Id = AiLimitsConfigStore.DeriveOpaqueAccountId(source.Id, $"manual|{provider}"),
                SourceId = source.Id,
                SourceKind = AiLimitsSourceKinds.ManualDashboard,
                Provider = provider,
                Product = AiLimitsProviders.DefaultProduct(provider),
                ProviderLabel = providerLabel,
                Alias = alias,
                DefaultAlias = alias,
                Plan = source.PlanLabel,
                ModelPool = "all",
                Enabled = true,
                ConnectionStatus = AiLimitsConnectionStatuses.Connected,
                QuotaStatus = AiLimitsQuotaStatuses.ManualOnly,
                Freshness = AiLimitsFreshness.ManualOnly,
                SupportLevel = AiLimitsAccessModes.ManualDashboard,
                CoverageScope = AiLimitsCoverageScopes.None,
                ProvenanceLabel = "Official dashboard",
                ProvenanceDetails = detailNote,
                ObservedAt = null,
                DashboardUrl = dashboardUrl,
                StatusMessage = "Open official dashboard to view current limits.",
                Windows = new List<AiLimitsWindowDto>
                {
                    AiLimitsNormalizer.BuildUnavailableWindow("five_hour", AiLimitsWindowKinds.FiveHour, "5h Limit", 300, fiveHourStatus, fiveHourNote),
                    AiLimitsNormalizer.BuildUnavailableWindow("weekly", AiLimitsWindowKinds.Weekly, "Weekly", 10080, weeklyStatus, weeklyNote),
                },
            };

            return Task.FromResult(new AiLimitsAdapterResult
            {
                Ok = true,
                Reachable = true,
                Status = AiLimitsSourceStatuses.Connected,
                StatusMessage = dashboardUrl != null
                    ? $"Manual dashboard card ready ({providerLabel})."
                    : $"Manual dashboard card ready ({providerLabel}); add an https:// dashboard URL if desired.",
                DetectedApiVersion = "manual",
                Accounts = new List<AiLimitsAccountDto> { account },
            });
        }
    }
}
