using System;
using System.Collections.Generic;

namespace DeckOS.Models
{
    public static class AiLimitsSourceKinds
    {
        public const string CliProxyPassive = "cliproxy_passive";
        public const string CodexLocal = "codex_local";
        public const string ClaudeStatusLine = "claude_statusline";
        public const string GeminiLocalOtel = "gemini_local_otel";
        public const string ManualDashboard = "manual_dashboard";
        public const string ExternalMonitorCache = "external_monitor_cache";

        public static bool IsKnown(string? kind) => kind is
            CliProxyPassive or CodexLocal or ClaudeStatusLine or GeminiLocalOtel or ManualDashboard or ExternalMonitorCache;
    }

    public static class AiLimitsAccessModes
    {
        public const string OfficialLocalRpc = "official_local_rpc";
        public const string OfficialLocalHook = "official_local_hook";
        public const string PassiveLocalFile = "passive_local_file";
        public const string PassiveLocalProxy = "passive_local_proxy";
        public const string PassiveLocalCache = "passive_local_cache";
        public const string ManualDashboard = "manual_dashboard";
    }

    public static class AiLimitsCoverageScopes
    {
        public const string AccountWideLive = "account_wide_live";
        public const string AccountWideLastLocalTurn = "account_wide_last_local_turn";
        public const string ProxyObservedOnly = "proxy_observed_only";
        public const string ExternalCacheOnly = "external_cache_only";
        public const string LocalDeviceActivityOnly = "local_device_activity_only";
        public const string None = "none";
    }

    public static class AiLimitsSourceStatuses
    {
        public const string Connected = "connected";
        public const string Degraded = "degraded";
        public const string AwaitingData = "awaiting_data";
        public const string AuthRequired = "auth_required";
        public const string RateLimited = "rate_limited";
        public const string Offline = "offline";
        public const string Disabled = "disabled";
        public const string SetupRequired = "setup_required";
        public const string Error = "error";
    }

    public static class AiLimitsConnectionStatuses
    {
        public const string Connected = "connected";
        public const string Disabled = "disabled";
        public const string Unavailable = "unavailable";
        public const string AuthRequired = "auth_required";
        public const string Offline = "offline";
        public const string SetupRequired = "setup_required";
    }

    public static class AiLimitsQuotaStatuses
    {
        public const string Ok = "ok";
        public const string Stale = "stale";
        public const string RateLimited = "rate_limited";
        public const string Cooldown = "cooldown";
        public const string AwaitingData = "awaiting_data";
        public const string Unavailable = "unavailable";
        public const string AuthRequired = "auth_required";
        public const string ManualOnly = "manual_only";
        public const string LocalOnly = "local_only";
    }

    public static class AiLimitsFreshness
    {
        public const string Fresh = "fresh";
        public const string Stale = "stale";
        public const string LocalOnly = "local_only";
        public const string ManualOnly = "manual_only";
        public const string Unavailable = "unavailable";
    }

    public static class AiLimitsWindowKinds
    {
        public const string FiveHour = "five_hour";
        public const string Weekly = "weekly";
        public const string Daily = "daily";
        public const string Monthly = "monthly";
        public const string SpendLimit = "spend_limit";
        public const string Credits = "credits";
        public const string Custom = "custom";
    }

    public static class AiLimitsWindowUnits
    {
        public const string Percent = "percent";
        public const string Requests = "requests";
        public const string Credits = "credits";
        public const string Usd = "usd";
        public const string Tokens = "tokens";
        public const string None = "none";
    }

    public static class AiLimitsWindowStatuses
    {
        public const string Available = "available";
        public const string NotApplicable = "not_applicable";
        public const string Unavailable = "unavailable";
        public const string Stale = "stale";
        public const string RateLimited = "rate_limited";
        public const string AuthRequired = "auth_required";
        public const string NotConnected = "not_connected";
    }

    public static class AiLimitsErrorCodes
    {
        public const string AuthFailed = "auth_failed";
        public const string RateLimited = "rate_limited";
        public const string CooldownActive = "cooldown_active";
        public const string Unreachable = "unreachable";
        public const string InvalidUrl = "invalid_url";
        public const string NonLoopbackBlocked = "non_loopback_blocked";
        public const string RedirectBlocked = "redirect_blocked";
        public const string ResponseTooLarge = "response_too_large";
        public const string CliNotFound = "cli_not_found";
        public const string HookNotInstalled = "hook_not_installed";
        public const string NoDataYet = "no_data_yet";
        public const string UnsupportedVersion = "unsupported_version";
        public const string LocalOnlyAction = "local_only_action";
        public const string Timeout = "timeout";
        public const string InternalError = "internal_error";
    }

    public static class AiLimitsProviders
    {
        public const string Claude = "claude";
        public const string Codex = "codex";
        public const string GeminiCli = "gemini_cli";
        public const string Antigravity = "antigravity";
        public const string GeminiWeb = "gemini_web";
        public const string Copilot = "copilot";
        public const string Cursor = "cursor";
        public const string Windsurf = "windsurf";
        public const string Devin = "devin";
        public const string Other = "other";

        public static string Normalize(string? raw)
        {
            var s = (raw ?? string.Empty).Trim().ToLowerInvariant();
            return s switch
            {
                "claude" or "anthropic" or "claude_code" or "claude-code" => Claude,
                "codex" or "openai" or "chatgpt" or "openai_codex" => Codex,
                "gemini_cli" or "gemini-cli" or "geminicli" or "gemini" => GeminiCli,
                "antigravity" or "google_antigravity" or "google-antigravity" => Antigravity,
                "gemini_web" or "gemini-web" or "gemini_app" => GeminiWeb,
                "copilot" or "github_copilot" or "github-copilot" => Copilot,
                "cursor" => Cursor,
                "windsurf" or "codeium" or "devin_desktop" => Windsurf,
                "devin" => Devin,
                _ => Other,
            };
        }

        public static string DisplayLabel(string provider) => provider switch
        {
            Claude => "Claude",
            Codex => "Codex",
            GeminiCli => "Gemini CLI",
            Antigravity => "Antigravity",
            GeminiWeb => "Gemini",
            Copilot => "Copilot",
            Cursor => "Cursor",
            Windsurf => "Windsurf",
            Devin => "Devin",
            _ => "AI Account",
        };

        public static string DefaultProduct(string provider) => provider switch
        {
            Claude => "claude_code",
            Codex => "codex",
            GeminiCli => "gemini_cli",
            Antigravity => "antigravity",
            GeminiWeb => "gemini_web",
            Copilot => "copilot",
            Cursor => "cursor",
            Windsurf => "windsurf",
            Devin => "devin",
            _ => "subscription",
        };

        public static string? OfficialDashboardUrl(string provider) => provider switch
        {
            Claude => "https://claude.ai/settings/usage",
            Codex => "https://chatgpt.com/codex/settings/usage",
            GeminiCli => "https://github.com/google-gemini/gemini-cli/blob/main/docs/resources/quota-and-pricing.md",
            Antigravity => "https://antigravity.google/docs/plans",
            GeminiWeb => "https://gemini.google.com/usage",
            Copilot => "https://github.com/settings/billing",
            Cursor => "https://cursor.com/dashboard",
            Windsurf => "https://windsurf.com/subscription/manage-plan",
            Devin => "https://app.devin.ai/settings/billing",
            _ => null,
        };
    }

    // ---- Public Secret-Free DTOs ----

    public sealed class AiLimitsSnapshotResponse
    {
        public int SchemaVersion { get; set; } = 1;
        public DateTimeOffset GeneratedAt { get; set; } = DateTimeOffset.UtcNow;
        public AiLimitsCapabilitiesDto Capabilities { get; set; } = new();
        public AiLimitsRefreshPolicyDto Refresh { get; set; } = new();
        public bool HideAccountNames { get; set; }
        public List<AiLimitsSourceDto> Sources { get; set; } = new();
        public List<AiLimitsAccountDto> Accounts { get; set; } = new();
    }

    public sealed class AiLimitsCapabilitiesDto
    {
        public string Platform { get; set; } = "other";
        public bool ClaudeStatusLineInstallerAvailable { get; set; } = true;
        public AiLimitsDetectedEnvironmentDto Detected { get; set; } = new();
        public List<AiLimitsSourceKindDescriptorDto> SupportedSourceKinds { get; set; } = new();
    }

    public sealed class AiLimitsDetectedEnvironmentDto
    {
        public string? CliProxySuggestedUrl { get; set; }
        public bool CliProxyReachable { get; set; }
        public bool CodexCliAvailable { get; set; }
        public bool CodexDefaultHomeExists { get; set; }
        public bool ClaudeCliAvailable { get; set; }
        public bool ClaudeConfigDirExists { get; set; }
        public bool ClaudeStatusLineConfigured { get; set; }
        public bool GeminiDirExists { get; set; }
    }

    public sealed class AiLimitsSourceKindDescriptorDto
    {
        public string Kind { get; set; } = string.Empty;
        public string Title { get; set; } = string.Empty;
        public string Description { get; set; } = string.Empty;
        public string AccessMode { get; set; } = string.Empty;
        public bool RequiresCredential { get; set; }
        public bool SupportsMultiAccount { get; set; } = true;
        public bool SupportsGuidedSetup { get; set; }
        public bool SupportsTestConnection { get; set; } = true;
        public string ProvenanceNote { get; set; } = string.Empty;
    }

    public sealed class AiLimitsRefreshPolicyDto
    {
        public int CooldownSeconds { get; set; } = 15;
        public DateTimeOffset? NextRefreshAllowedAt { get; set; }
        public int AutoRefreshIntervalSeconds { get; set; } = 180;
        public bool IsRefreshing { get; set; }
    }

    public sealed class AiLimitsSourceDto
    {
        public string Id { get; set; } = string.Empty;
        public string Kind { get; set; } = string.Empty;
        public string Label { get; set; } = string.Empty;
        public bool Enabled { get; set; } = true;
        public string AccessMode { get; set; } = string.Empty;
        public string SupportLevel { get; set; } = string.Empty;
        public bool HasCredential { get; set; }
        public string? BaseUrl { get; set; }
        public bool AllowNonLoopback { get; set; }
        public string? ConfigDir { get; set; }
        public string? SnapshotFile { get; set; }
        public string? CodexMode { get; set; }
        public string? Provider { get; set; }
        public string? PlanLabel { get; set; }
        public string? DashboardUrl { get; set; }
        public int? DailyLimitHint { get; set; }
        public int PollIntervalSeconds { get; set; } = 180;
        public string Status { get; set; } = AiLimitsSourceStatuses.AwaitingData;
        public string? ErrorCode { get; set; }
        public string? StatusMessage { get; set; }
        public string? DetectedApiVersion { get; set; }
        public DateTimeOffset? LastCheckedAt { get; set; }
        public DateTimeOffset? LastSyncedAt { get; set; }
        public DateTimeOffset? BackoffUntil { get; set; }
        public int? RetryAfterSeconds { get; set; }
        public int AccountCount { get; set; }
    }

    public sealed class AiLimitsAccountDto
    {
        public string Id { get; set; } = string.Empty;
        public string SourceId { get; set; } = string.Empty;
        public string SourceKind { get; set; } = string.Empty;
        public string Provider { get; set; } = AiLimitsProviders.Other;
        public string Product { get; set; } = "subscription";
        public string ProviderLabel { get; set; } = "AI Account";
        public string Alias { get; set; } = string.Empty;
        public string DefaultAlias { get; set; } = string.Empty;
        public string? CustomAlias { get; set; }
        public string? AutomaticDisplayName { get; set; }
        public bool HasReportedName { get; set; }
        // Internal display metadata only; never serialize raw names outside the privacy resolver.
        [System.Text.Json.Serialization.JsonIgnore]
        public string? ReportedName { get; set; }
        public string? Plan { get; set; }
        public string? ModelPool { get; set; }
        public bool Enabled { get; set; } = true;
        public string ConnectionStatus { get; set; } = AiLimitsConnectionStatuses.Connected;
        public string QuotaStatus { get; set; } = AiLimitsQuotaStatuses.Unavailable;
        public string Freshness { get; set; } = AiLimitsFreshness.Unavailable;
        public string SupportLevel { get; set; } = string.Empty;
        public string CoverageScope { get; set; } = AiLimitsCoverageScopes.None;
        public string ProvenanceLabel { get; set; } = string.Empty;
        public string ProvenanceDetails { get; set; } = string.Empty;
        public DateTimeOffset? ObservedAt { get; set; }
        public int? StaleAfterSeconds { get; set; }
        public DateTimeOffset? CooldownUntil { get; set; }
        public DateTimeOffset? BackoffUntil { get; set; }
        public bool? OrdinaryUsageAllowed { get; set; }
        public string? DashboardUrl { get; set; }
        public string? ErrorCode { get; set; }
        public string? StatusMessage { get; set; }
        public List<AiLimitsWindowDto> Windows { get; set; } = new();
    }

    public sealed class AiLimitsWindowDto
    {
        public string Id { get; set; } = string.Empty;
        public string Kind { get; set; } = AiLimitsWindowKinds.Custom;
        public string Label { get; set; } = string.Empty;
        public int? WindowMinutes { get; set; }
        public string Unit { get; set; } = AiLimitsWindowUnits.Percent;
        public string Status { get; set; } = AiLimitsWindowStatuses.Unavailable;
        public double? UsedPercent { get; set; }
        public double? RemainingPercent { get; set; }
        public double? Used { get; set; }
        public double? Limit { get; set; }
        public DateTimeOffset? ResetsAt { get; set; }
        public string? ModelPool { get; set; }
        public bool? OrdinaryUsageAllowed { get; set; }
        public string? Note { get; set; }
    }

    // ---- API Request / Response Contracts ----

    public class AiLimitsSourceTestRequest
    {
        public string? SourceId { get; set; }
        public string Kind { get; set; } = string.Empty;
        public string? Label { get; set; }
        public string? BaseUrl { get; set; }
        public bool AllowNonLoopback { get; set; }
        public string? Credential { get; set; }
        public string? ConfigDir { get; set; }
        public string? SnapshotFile { get; set; }
        public string? CodexMode { get; set; }
        public string? Provider { get; set; }
        public string? PlanLabel { get; set; }
        public string? DashboardUrl { get; set; }
        public int? DailyLimitHint { get; set; }
    }

    public sealed class AiLimitsSourceUpsertRequest : AiLimitsSourceTestRequest
    {
        public bool Enabled { get; set; } = true;
        public int? PollIntervalSeconds { get; set; }
        public bool ClearCredential { get; set; }
    }

    public sealed class AiLimitsSourceTestResponse
    {
        public bool Ok { get; set; }
        public bool Reachable { get; set; }
        public string Status { get; set; } = AiLimitsSourceStatuses.Error;
        public string? ErrorCode { get; set; }
        public string Message { get; set; } = string.Empty;
        public string? DetectedApiVersion { get; set; }
        public string? CapabilitiesNote { get; set; }
        public List<AiLimitsAccountDto> Accounts { get; set; } = new();
    }

    public sealed class AiLimitsRefreshRequest
    {
        public string? SourceId { get; set; }
    }

    public sealed class AiLimitsPrivacyUpdateRequest
    {
        public bool HideAccountNames { get; set; }
    }

    public sealed class AiLimitsAccountUpdateRequest
    {
        public string? Alias { get; set; }
        public bool? Enabled { get; set; }
        public string? Plan { get; set; }
        public string? DashboardUrl { get; set; }
    }

    public sealed class AiLimitsSetupGuideResponse
    {
        public string SourceId { get; set; } = string.Empty;
        public string Kind { get; set; } = string.Empty;
        public bool Supported { get; set; }
        public bool IsInstalled { get; set; }
        public bool HasExistingUserHook { get; set; }
        public bool CanAutoInstall { get; set; }
        public List<string> Steps { get; set; } = new();
        public List<string> Caveats { get; set; } = new();
        public string? CommandPreview { get; set; }
        /// <summary>Set when a setup action was refused (e.g. settings.json could not be parsed safely).</summary>
        public string? ErrorCode { get; set; }
        public string? Message { get; set; }
    }

    // ---- Internal Persistent Config Models (Secret-Free; stored in AppPaths.LocalDir) ----

    public sealed class AiLimitsConfigDocument
    {
        public int SchemaVersion { get; set; } = 1;
        public int AutoRefreshIntervalSeconds { get; set; } = 180;
        public int ManualCooldownSeconds { get; set; } = 15;
        public bool HideAccountNames { get; set; }
        public List<AiLimitsSourceConfig> Sources { get; set; } = new();
        public Dictionary<string, AiLimitsAccountOverride> AccountOverrides { get; set; } = new(StringComparer.Ordinal);
        public HashSet<string> HiddenAccountIds { get; set; } = new(StringComparer.Ordinal);
    }

    public sealed class AiLimitsSourceConfig
    {
        public string Id { get; set; } = string.Empty;
        public string Kind { get; set; } = string.Empty;
        public string Label { get; set; } = string.Empty;
        public bool Enabled { get; set; } = true;
        public string? BaseUrl { get; set; }
        public bool AllowNonLoopback { get; set; }
        public string? ConfigDir { get; set; }
        public string? SnapshotFile { get; set; }
        public string? CodexMode { get; set; }
        public string? Provider { get; set; }
        public string? PlanLabel { get; set; }
        public string? DashboardUrl { get; set; }
        public int? DailyLimitHint { get; set; }
        public int PollIntervalSeconds { get; set; } = 180;
        public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    }

    public sealed class AiLimitsAccountOverride
    {
        public string? Alias { get; set; }
        public bool? Enabled { get; set; }
        public string? Plan { get; set; }
        public string? DashboardUrl { get; set; }
    }
}
