using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Models;

namespace DeckOS.Services.AiLimits
{
    public sealed class AiLimitsAdapterResult
    {
        public bool Ok { get; set; }
        public bool Reachable { get; set; }
        public string Status { get; set; } = AiLimitsSourceStatuses.AwaitingData;
        public string? ErrorCode { get; set; }
        public string? StatusMessage { get; set; }
        public string? DetectedApiVersion { get; set; }
        public string? CapabilitiesNote { get; set; }
        public TimeSpan? RetryAfter { get; set; }
        public bool AuthCircuitBreak { get; set; }
        public List<AiLimitsAccountDto> Accounts { get; set; } = new();
    }

    public interface IAiLimitsSourceAdapter
    {
        string Kind { get; }
        AiLimitsSourceKindDescriptorDto Descriptor { get; }
        Task<AiLimitsAdapterResult> FetchAsync(
            AiLimitsSourceConfig source,
            string? secret,
            DateTimeOffset now,
            CancellationToken ct);
    }

    public static class AiLimitsNormalizer
    {
        public const int DefaultStaleAfterSeconds = 900; // 15 minutes

        public static (string Kind, string Label) ClassifyWindowMinutes(int? minutes, string fallbackKind, string fallbackLabel)
        {
            if (minutes is not { } m || m <= 0)
                return (fallbackKind, fallbackLabel);

            if (m is >= 240 and <= 360)
                return (AiLimitsWindowKinds.FiveHour, "5h Limit");
            if (m is >= 9000 and <= 11520)
                return (AiLimitsWindowKinds.Weekly, "Weekly");
            if (m is >= 1200 and <= 1680)
                return (AiLimitsWindowKinds.Daily, "Daily");
            if (m >= 40000)
                return (AiLimitsWindowKinds.Monthly, "Monthly");

            var label = m % 60 == 0 ? $"{m / 60}h Window" : $"{m}m Window";
            return (AiLimitsWindowKinds.Custom, label);
        }

        public static string? SanitizeText(string? value, int maxLen = 120)
        {
            // Control-character stripping pattern inspired by shuv1337/shuvquota (MIT, lib/snapshot.js).
            if (string.IsNullOrWhiteSpace(value)) return null;
            var chars = value.Where(c => !char.IsControl(c)).ToArray();
            var clean = new string(chars).Trim();
            if (clean.Length == 0) return null;
            return clean.Length <= maxLen ? clean : clean[..maxLen];
        }

        public static AiLimitsWindowDto BuildPercentWindow(
            string id,
            string kind,
            string label,
            int? windowMinutes,
            double usedPercentRaw,
            DateTimeOffset? resetsAt,
            DateTimeOffset? observedAt,
            DateTimeOffset now,
            int staleAfterSeconds = DefaultStaleAfterSeconds,
            string? modelPool = "all",
            bool? ordinaryUsageAllowed = null,
            bool isRateLimited = false,
            string? note = null,
            bool allowOver100 = false,
            bool clampOverflow = false)
        {
            // Claude-Code-Usage-Monitor (MIT, output/official.py _clean_pct): a reading that is NaN,
            // negative or above 101 is a bad value (e.g. a leaked epoch), never a real 100%.
            // 100 < x <= 101 is a rounding artifact and clamps to 100. Spend limits may exceed 100.
            // Codex documents used_percent as able to exceed 100 when over the limit, so Codex
            // callers pass clampOverflow to show it as 100% used instead of discarding it.
            if (double.IsNaN(usedPercentRaw) || double.IsInfinity(usedPercentRaw) || usedPercentRaw < 0.0 ||
                (!allowOver100 && !clampOverflow && usedPercentRaw > 101.0) ||
                (clampOverflow && usedPercentRaw > 100_000.0))
            {
                return BuildUnavailableWindow(id, kind, label, windowMinutes, AiLimitsWindowStatuses.Unavailable,
                    "Invalid reading ignored", modelPool);
            }

            var used = Math.Round(allowOver100 ? usedPercentRaw : Math.Min(usedPercentRaw, 100.0), 1);
            var remaining = Math.Round(Math.Clamp(100.0 - used, 0.0, 100.0), 1);

            var pastReset = resetsAt.HasValue && resetsAt.Value <= now && (!observedAt.HasValue || observedAt.Value <= resetsAt.Value);
            var agedOut = observedAt.HasValue && staleAfterSeconds > 0 && (now - observedAt.Value).TotalSeconds > staleAfterSeconds;

            string status;
            string? resolvedNote = note;
            if (isRateLimited || ordinaryUsageAllowed == false)
            {
                status = AiLimitsWindowStatuses.RateLimited;
                resolvedNote ??= "Limit reached";
            }
            else if (pastReset)
            {
                // Invariant: NEVER auto-zero to 0% when passing resetsAt without a confirmed new reading!
                status = AiLimitsWindowStatuses.Stale;
                resolvedNote ??= "Past reset — awaiting fresh observation";
            }
            else if (agedOut)
            {
                status = AiLimitsWindowStatuses.Stale;
                resolvedNote ??= "Stale — awaiting fresh activity";
            }
            else
            {
                status = AiLimitsWindowStatuses.Available;
            }

            return new AiLimitsWindowDto
            {
                Id = id,
                Kind = kind,
                Label = label,
                WindowMinutes = windowMinutes,
                Unit = AiLimitsWindowUnits.Percent,
                Status = status,
                UsedPercent = used,
                RemainingPercent = remaining,
                Used = used,
                Limit = 100.0,
                ResetsAt = resetsAt,
                ModelPool = modelPool,
                OrdinaryUsageAllowed = ordinaryUsageAllowed,
                Note = resolvedNote,
            };
        }

        public static AiLimitsWindowDto BuildUnavailableWindow(
            string id,
            string kind,
            string label,
            int? windowMinutes,
            string status,
            string? note,
            string? modelPool = "all")
        {
            return new AiLimitsWindowDto
            {
                Id = id,
                Kind = kind,
                Label = label,
                WindowMinutes = windowMinutes,
                Unit = AiLimitsWindowUnits.None,
                Status = status,
                UsedPercent = null,
                RemainingPercent = null,
                Used = null,
                Limit = null,
                ResetsAt = null,
                ModelPool = modelPool,
                OrdinaryUsageAllowed = null,
                Note = note,
            };
        }

        public static List<AiLimitsWindowDto> OrderWindows(IEnumerable<AiLimitsWindowDto> windows)
        {
            var ordered = windows
                .OrderBy(w => WindowRank(w.Kind))
                .ThenBy(w => string.Equals(w.ModelPool, "all", StringComparison.OrdinalIgnoreCase) || string.IsNullOrEmpty(w.ModelPool) ? 0 : 1)
                .ThenBy(w => w.Id, StringComparer.Ordinal)
                .ToList();

            // Window ids are unique per account (two slots can classify to the same duration).
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var w in ordered)
            {
                var id = w.Id;
                for (var n = 2; !seen.Add(id); n++) id = $"{w.Id}_{n}";
                w.Id = id;
            }
            return ordered;
        }

        /// <summary>ChatGPT Pro tiers (pro, prolite, promax) have no 5-hour Codex window.</summary>
        public static bool IsCodexProPlan(string? planType) =>
            !string.IsNullOrWhiteSpace(planType) && planType.Trim().StartsWith("pro", StringComparison.OrdinalIgnoreCase);

        private static int WindowRank(string kind) => kind switch
        {
            AiLimitsWindowKinds.FiveHour => 0,
            AiLimitsWindowKinds.Weekly => 1,
            AiLimitsWindowKinds.Daily => 2,
            AiLimitsWindowKinds.Monthly => 3,
            AiLimitsWindowKinds.SpendLimit => 4,
            AiLimitsWindowKinds.Credits => 5,
            _ => 6,
        };

        /// <summary>
        /// Re-evaluates staleness against <paramref name="now"/> on cached snapshots without
        /// ever auto-zeroing usedPercent/remainingPercent.
        /// </summary>
        public static AiLimitsAccountDto CloneWithCurrentFreshness(AiLimitsAccountDto src, DateTimeOffset now)
        {
            var copy = new AiLimitsAccountDto
            {
                Id = src.Id,
                SourceId = src.SourceId,
                SourceKind = src.SourceKind,
                Provider = src.Provider,
                Product = src.Product,
                ProviderLabel = src.ProviderLabel,
                Alias = src.Alias,
                DefaultAlias = src.DefaultAlias,
                Plan = src.Plan,
                ModelPool = src.ModelPool,
                Enabled = src.Enabled,
                ConnectionStatus = src.ConnectionStatus,
                QuotaStatus = src.QuotaStatus,
                Freshness = src.Freshness,
                SupportLevel = src.SupportLevel,
                CoverageScope = src.CoverageScope,
                ProvenanceLabel = src.ProvenanceLabel,
                ProvenanceDetails = src.ProvenanceDetails,
                ObservedAt = src.ObservedAt,
                StaleAfterSeconds = src.StaleAfterSeconds,
                CooldownUntil = src.CooldownUntil,
                BackoffUntil = src.BackoffUntil,
                OrdinaryUsageAllowed = src.OrdinaryUsageAllowed,
                DashboardUrl = src.DashboardUrl,
                ErrorCode = src.ErrorCode,
                StatusMessage = src.StatusMessage,
                Windows = new List<AiLimitsWindowDto>(src.Windows.Count),
            };

            var anyStale = false;
            var anyAvailable = false;
            var anyRateLimited = false;
            var staleSeconds = src.StaleAfterSeconds ?? DefaultStaleAfterSeconds;
            var agedOut = src.ObservedAt.HasValue && staleSeconds > 0 && (now - src.ObservedAt.Value).TotalSeconds > staleSeconds;

            foreach (var w in src.Windows)
            {
                var wc = new AiLimitsWindowDto
                {
                    Id = w.Id,
                    Kind = w.Kind,
                    Label = w.Label,
                    WindowMinutes = w.WindowMinutes,
                    Unit = w.Unit,
                    Status = w.Status,
                    UsedPercent = w.UsedPercent,
                    RemainingPercent = w.RemainingPercent,
                    Used = w.Used,
                    Limit = w.Limit,
                    ResetsAt = w.ResetsAt,
                    ModelPool = w.ModelPool,
                    OrdinaryUsageAllowed = w.OrdinaryUsageAllowed,
                    Note = w.Note,
                };

                if (wc.Status == AiLimitsWindowStatuses.Available)
                {
                    var pastReset = wc.ResetsAt.HasValue && wc.ResetsAt.Value <= now && (!src.ObservedAt.HasValue || src.ObservedAt.Value <= wc.ResetsAt.Value);
                    if (pastReset)
                    {
                        wc.Status = AiLimitsWindowStatuses.Stale;
                        wc.Note = "Past reset — awaiting fresh observation";
                        anyStale = true;
                    }
                    else if (agedOut && src.CoverageScope != AiLimitsCoverageScopes.LocalDeviceActivityOnly)
                    {
                        wc.Status = AiLimitsWindowStatuses.Stale;
                        wc.Note ??= "Stale — awaiting fresh activity";
                        anyStale = true;
                    }
                    else
                    {
                        anyAvailable = true;
                    }
                }
                else if (wc.Status == AiLimitsWindowStatuses.Stale)
                {
                    anyStale = true;
                }
                else if (wc.Status == AiLimitsWindowStatuses.RateLimited)
                {
                    anyRateLimited = true;
                }

                copy.Windows.Add(wc);
            }

            if (copy.Freshness == AiLimitsFreshness.Fresh && anyStale && !anyAvailable && !anyRateLimited)
            {
                copy.Freshness = AiLimitsFreshness.Stale;
                if (copy.QuotaStatus == AiLimitsQuotaStatuses.Ok)
                    copy.QuotaStatus = AiLimitsQuotaStatuses.Stale;
            }
            else if (copy.Freshness == AiLimitsFreshness.Fresh && anyStale && copy.QuotaStatus == AiLimitsQuotaStatuses.Ok)
            {
                copy.Freshness = AiLimitsFreshness.Stale;
                copy.QuotaStatus = AiLimitsQuotaStatuses.Stale;
            }

            return copy;
        }
    }
}
