using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Models;

namespace DeckOS.Services.AiLimits
{
    /// <summary>
    /// Official Anthropic Claude Code `statusLine` passive local observer.
    /// Reads ONLY redacted `rate_limits` snapshots written by Claude Code's documented
    /// `statusLine` hook (zero extra API probes, never reads ~/.claude/.credentials.json).
    ///
    /// Includes an opt-in, non-destructive wrapper installer that preserves any existing
    /// user `statusLine` command and backs up `settings.json` before atomic writes.
    /// </summary>
    public sealed class ClaudeStatusLineAdapter : IAiLimitsSourceAdapter
    {
        private const string WrapperMarker = "deckos-claude-statusline-";
        private readonly AiLimitsConfigStore _store;

        public ClaudeStatusLineAdapter(AiLimitsConfigStore store)
        {
            _store = store;
        }

        public string Kind => AiLimitsSourceKinds.ClaudeStatusLine;

        public AiLimitsSourceKindDescriptorDto Descriptor => new()
        {
            Kind = Kind,
            Title = "Claude Code (statusLine Hook)",
            Description = "Passively captures official 5h and 7d percentages from Claude Code's documented `statusLine` hook with zero extra API requests.",
            AccessMode = AiLimitsAccessModes.OfficialLocalHook,
            RequiresCredential = false,
            SupportsMultiAccount = true,
            SupportsGuidedSetup = true,
            SupportsTestConnection = true,
            ProvenanceNote = "Uses Claude Code's official local statusLine stdin JSON (`rate_limits`). Updates during active local CLI sessions without touching OAuth credentials or polling Anthropic APIs.",
        };

        public string ResolveSnapshotPath(AiLimitsSourceConfig source) =>
            !string.IsNullOrWhiteSpace(source.SnapshotFile)
                ? source.SnapshotFile.Trim()
                : _store.DefaultClaudeSnapshotPath(source.Id);

        public static string ResolveClaudeConfigDir(string? configDir) =>
            !string.IsNullOrWhiteSpace(configDir)
                ? configDir.Trim()
                : AiUsageService.ClaudeDir;

        public Task<AiLimitsAdapterResult> FetchAsync(
            AiLimitsSourceConfig source,
            string? secret,
            DateTimeOffset now,
            CancellationToken ct)
        {
            var snapshotPath = ResolveSnapshotPath(source);
            var settingsPath = Path.Combine(ResolveClaudeConfigDir(source.ConfigDir), "settings.json");
            var hookInstalled = IsDeckOsWrapperConfigured(settingsPath, source.Id);

            if (!File.Exists(snapshotPath))
            {
                var status = hookInstalled ? AiLimitsSourceStatuses.AwaitingData : AiLimitsSourceStatuses.SetupRequired;
                var errCode = hookInstalled ? AiLimitsErrorCodes.NoDataYet : AiLimitsErrorCodes.HookNotInstalled;
                var msg = hookInstalled
                    ? "Claude Code statusLine wrapper is installed. Run any normal Claude Code turn to populate limits."
                    : "Install the non-destructive Claude Code statusLine wrapper (or point to an existing snapshot file) to observe limits passively.";

                var placeholder = BuildPlaceholderAccount(source, hookInstalled, msg);
                return Task.FromResult(new AiLimitsAdapterResult
                {
                    Ok = hookInstalled,
                    Reachable = Directory.Exists(ResolveClaudeConfigDir(source.ConfigDir)),
                    Status = status,
                    ErrorCode = errCode,
                    StatusMessage = msg,
                    DetectedApiVersion = "statusline",
                    Accounts = new List<AiLimitsAccountDto> { placeholder },
                });
            }

            try
            {
                var rawJson = File.ReadAllText(snapshotPath, Encoding.UTF8);
                var lastWrite = new DateTimeOffset(File.GetLastWriteTimeUtc(snapshotPath), TimeSpan.Zero);
                var account = ParseSnapshot(source, rawJson, lastWrite, now);
                return Task.FromResult(new AiLimitsAdapterResult
                {
                    Ok = true,
                    Reachable = true,
                    Status = account.Windows.Any(w => w.UsedPercent.HasValue)
                        ? AiLimitsSourceStatuses.Connected
                        : AiLimitsSourceStatuses.AwaitingData,
                    StatusMessage = account.Windows.Any(w => w.UsedPercent.HasValue)
                        ? "Observing Claude Code statusLine snapshot."
                        : "Snapshot file found, awaiting Claude Code rate_limits fields.",
                    DetectedApiVersion = "statusline",
                    CapabilitiesNote = "Passive local observation from Claude Code statusLine stdin JSON (zero extra API probes).",
                    Accounts = new List<AiLimitsAccountDto> { account },
                });
            }
            catch (Exception)
            {
                return Task.FromResult(new AiLimitsAdapterResult
                {
                    Ok = false,
                    Reachable = true,
                    Status = AiLimitsSourceStatuses.Error,
                    ErrorCode = AiLimitsErrorCodes.InternalError,
                    StatusMessage = "Could not parse Claude statusLine snapshot file.",
                });
            }
        }

        /// <summary>
        /// Whitelists ONLY `rate_limits` and `observedAt` from an incoming Claude Code statusLine payload
        /// and atomically writes the sanitized snapshot file. Never persists workspace/session/transcript PII.
        /// Attribution: Plan-downgrade tombstone (`rate_limits: null`) and >101 epoch-leak guard adapted from
        /// Maciek-roboblog/Claude-Code-Usage-Monitor (`src/claude_monitor/output/official.py`, MIT).
        /// </summary>
        public string IngestSanitizedPayload(AiLimitsSourceConfig source, string rawJson, DateTimeOffset now)
        {
            using var doc = JsonDocument.Parse(rawJson);
            var root = doc.RootElement;

            JsonNode? sanitizedRateLimits;
            if (root.TryGetProperty("rate_limits", out var inner))
            {
                sanitizedRateLimits = inner.ValueKind == JsonValueKind.Object
                    ? ExtractSanitizedRateLimits(inner)
                    : null; // Explicit tombstone when rate_limits is null
            }
            else if (root.TryGetProperty("five_hour", out _) || root.TryGetProperty("seven_day", out _) || root.TryGetProperty("spend_limit", out _))
            {
                sanitizedRateLimits = ExtractSanitizedRateLimits(root);
            }
            else
            {
                // Claude Code omits rate_limits until the session's first API response; only a session that
                // already made API calls without rate_limits is a plan-downgrade tombstone.
                if (!SessionMadeApiCall(root))
                    return ResolveSnapshotPath(source);
                sanitizedRateLimits = null;
            }

            var sanitized = new JsonObject
            {
                ["schemaVersion"] = 1,
                ["observedAt"] = now.ToString("O", CultureInfo.InvariantCulture),
                ["rate_limits"] = sanitizedRateLimits,
            };

            var path = ResolveSnapshotPath(source);
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var tmp = path + ".tmp." + Guid.NewGuid().ToString("N")[..8];
            try
            {
                File.WriteAllText(tmp, sanitized.ToJsonString(new JsonSerializerOptions { WriteIndented = false }), new UTF8Encoding(false));
                if (!OperatingSystem.IsWindows())
                {
                    try { File.SetUnixFileMode(tmp, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch { }
                }
                File.Move(tmp, path, overwrite: true);
            }
            catch
            {
                try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
                throw;
            }
            return path;
        }

        private static bool SessionMadeApiCall(JsonElement root) =>
            root.TryGetProperty("cost", out var cost) && cost.ValueKind == JsonValueKind.Object &&
            cost.TryGetProperty("total_api_duration_ms", out var ms) && ms.ValueKind == JsonValueKind.Number &&
            ms.GetDouble() > 0;

        private static JsonObject ExtractSanitizedRateLimits(JsonElement rl)
        {
            var outObj = new JsonObject();
            CopyWindow(rl, "five_hour", outObj, includeUsd: false);
            CopyWindow(rl, "seven_day", outObj, includeUsd: false);
            CopyWindow(rl, "spend_limit", outObj, includeUsd: true);
            return outObj;
        }

        private static void CopyWindow(JsonElement rl, string key, JsonObject dest, bool includeUsd)
        {
            if (!rl.TryGetProperty(key, out var w) || w.ValueKind != JsonValueKind.Object) return;
            var copy = new JsonObject();
            if (w.TryGetProperty("used_percentage", out var up) && up.ValueKind == JsonValueKind.Number)
                copy["used_percentage"] = up.GetDouble();
            if (w.TryGetProperty("resets_at", out var ra))
            {
                if (ra.ValueKind == JsonValueKind.Number && ra.TryGetInt64(out var unix))
                    copy["resets_at"] = unix;
                else if (ra.ValueKind == JsonValueKind.String && ra.GetString() is { } rs)
                    copy["resets_at"] = rs;
            }
            if (includeUsd)
            {
                if (w.TryGetProperty("used_usd", out var u) && u.ValueKind == JsonValueKind.Number) copy["used_usd"] = u.GetDouble();
                if (w.TryGetProperty("limit_usd", out var l) && l.ValueKind == JsonValueKind.Number) copy["limit_usd"] = l.GetDouble();
                if (w.TryGetProperty("period", out var p) && p.ValueKind == JsonValueKind.String) copy["period"] = p.GetString();
            }
            if (copy.Count > 0) dest[key] = copy;
        }

        public static AiLimitsAccountDto ParseSnapshot(
            AiLimitsSourceConfig source,
            string json,
            DateTimeOffset fallbackObservedAt,
            DateTimeOffset now)
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;

            var observedAt = fallbackObservedAt;
            if (root.TryGetProperty("observedAt", out var obsEl) && obsEl.ValueKind == JsonValueKind.String &&
                DateTimeOffset.TryParse(obsEl.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsedObs))
                observedAt = parsedObs.ToUniversalTime();
            else if (root.TryGetProperty("observed_at", out var obsEl2) && obsEl2.ValueKind == JsonValueKind.String &&
                DateTimeOffset.TryParse(obsEl2.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var parsedObs2))
                observedAt = parsedObs2.ToUniversalTime();

            var hasRateLimitsObject = false;
            JsonElement rl = default;
            if (root.TryGetProperty("rate_limits", out var rlEl))
            {
                hasRateLimitsObject = rlEl.ValueKind == JsonValueKind.Object;
                rl = rlEl;
            }
            else if (root.TryGetProperty("five_hour", out _) || root.TryGetProperty("seven_day", out _) || root.TryGetProperty("spend_limit", out _))
            {
                hasRateLimitsObject = true;
                rl = root;
            }

            var windows = new List<AiLimitsWindowDto>();

            if (hasRateLimitsObject && TryReadStatusLineWindow(rl, "five_hour", out var pct5h, out var reset5h))
            {
                windows.Add(AiLimitsNormalizer.BuildPercentWindow(
                    "five_hour",
                    AiLimitsWindowKinds.FiveHour,
                    "5h Limit",
                    300,
                    pct5h,
                    reset5h,
                    observedAt,
                    now));
            }

            if (hasRateLimitsObject && TryReadStatusLineWindow(rl, "seven_day", out var pct7d, out var reset7d))
            {
                windows.Add(AiLimitsNormalizer.BuildPercentWindow(
                    "weekly",
                    AiLimitsWindowKinds.Weekly,
                    "Weekly",
                    10080,
                    pct7d,
                    reset7d,
                    observedAt,
                    now));
            }

            if (hasRateLimitsObject && rl.TryGetProperty("spend_limit", out var sl) && sl.ValueKind == JsonValueKind.Object)
            {
                double? usedUsd = sl.TryGetProperty("used_usd", out var uu) && uu.ValueKind == JsonValueKind.Number ? uu.GetDouble() : null;
                double? limitUsd = sl.TryGetProperty("limit_usd", out var lu) && lu.ValueKind == JsonValueKind.Number ? lu.GetDouble() : null;
                double? rawPct = sl.TryGetProperty("used_percentage", out var up) && up.ValueKind == JsonValueKind.Number ? up.GetDouble() : null;
                // spend_limit can legitimately exceed 100%, only reject obvious Unix-epoch leaks (>1,000,000) or negative/NaN.
                double? pct = rawPct is { } rp && !double.IsNaN(rp) && !double.IsInfinity(rp) && rp >= 0 && rp <= 1_000_000 ? rp : null;
                var resetsAt = ParseReset(sl);
                if (pct.HasValue || usedUsd.HasValue)
                {
                    var w = pct.HasValue
                        ? AiLimitsNormalizer.BuildPercentWindow("spend_limit", AiLimitsWindowKinds.SpendLimit, "Spend Limit", null, pct.Value, resetsAt, observedAt, now, allowOver100: true)
                        : new AiLimitsWindowDto
                        {
                            Id = "spend_limit",
                            Kind = AiLimitsWindowKinds.SpendLimit,
                            Label = "Spend Limit",
                            Unit = AiLimitsWindowUnits.Usd,
                            Status = AiLimitsWindowStatuses.Available,
                            ResetsAt = resetsAt,
                        };
                    if (usedUsd.HasValue)
                    {
                        w.Unit = AiLimitsWindowUnits.Usd;
                        w.Used = Math.Round(usedUsd.Value, 2);
                        w.Limit = limitUsd.HasValue ? Math.Round(limitUsd.Value, 2) : null;
                    }
                    windows.Add(w);
                }
            }

            if (windows.Count == 0)
            {
                // Tombstone or non-subscription session: surface honest unavailable windows.
                windows.Add(AiLimitsNormalizer.BuildUnavailableWindow(
                    "five_hour",
                    AiLimitsWindowKinds.FiveHour,
                    "5h Limit",
                    300,
                    AiLimitsWindowStatuses.Unavailable,
                    "Not reported in latest Claude Code session"));
                windows.Add(AiLimitsNormalizer.BuildUnavailableWindow(
                    "weekly",
                    AiLimitsWindowKinds.Weekly,
                    "Weekly",
                    10080,
                    AiLimitsWindowStatuses.Unavailable,
                    "Not reported in latest Claude Code session"));
            }
            // Claude Ultra drops 5h while keeping 7d; represent absent 5h honestly when 7d exists.
            else if (windows.All(w => w.Kind != AiLimitsWindowKinds.FiveHour) && windows.Any(w => w.Kind == AiLimitsWindowKinds.Weekly))
            {
                windows.Add(AiLimitsNormalizer.BuildUnavailableWindow(
                    "five_hour",
                    AiLimitsWindowKinds.FiveHour,
                    "5h Limit",
                    300,
                    AiLimitsWindowStatuses.Unavailable,
                    "Not reported by Claude Code (absent or expired)"));
            }

            var alias = string.IsNullOrWhiteSpace(source.Label) ? "Personal" : source.Label.Trim();
            var anyAvailable = windows.Any(w => w.Status == AiLimitsWindowStatuses.Available);
            var anyStale = windows.Any(w => w.Status == AiLimitsWindowStatuses.Stale);
            var anyPercent = windows.Any(w => w.UsedPercent.HasValue);

            return new AiLimitsAccountDto
            {
                Id = AiLimitsConfigStore.DeriveOpaqueAccountId(source.Id, "statusline|claude"),
                SourceId = source.Id,
                SourceKind = AiLimitsSourceKinds.ClaudeStatusLine,
                Provider = AiLimitsProviders.Claude,
                Product = "claude_code",
                ProviderLabel = "Claude",
                Alias = alias,
                DefaultAlias = alias,
                Plan = source.PlanLabel,
                ModelPool = "all",
                Enabled = true,
                ConnectionStatus = AiLimitsConnectionStatuses.Connected,
                QuotaStatus = !anyPercent
                    ? AiLimitsQuotaStatuses.AwaitingData
                    : anyAvailable ? AiLimitsQuotaStatuses.Ok : anyStale ? AiLimitsQuotaStatuses.Stale : AiLimitsQuotaStatuses.Unavailable,
                Freshness = !anyPercent
                    ? AiLimitsFreshness.Unavailable
                    : anyAvailable ? AiLimitsFreshness.Fresh : AiLimitsFreshness.Stale,
                SupportLevel = AiLimitsAccessModes.OfficialLocalHook,
                CoverageScope = AiLimitsCoverageScopes.AccountWideLastLocalTurn,
                ProvenanceLabel = "Claude · statusLine",
                ProvenanceDetails = "Captured passively via Claude Code's documented `statusLine` stdin JSON (`rate_limits`). Updates during active local CLI sessions with zero extra API calls.",
                ObservedAt = observedAt,
                StaleAfterSeconds = AiLimitsNormalizer.DefaultStaleAfterSeconds,
                DashboardUrl = AiLimitsUrlValidator.ValidateDashboardUrl(source.DashboardUrl) ?? AiLimitsProviders.OfficialDashboardUrl(AiLimitsProviders.Claude),
                StatusMessage = anyPercent ? null : "Awaiting first Claude Code API response with rate_limits.",
                Windows = AiLimitsNormalizer.OrderWindows(windows),
            };
        }

        private static AiLimitsAccountDto BuildPlaceholderAccount(AiLimitsSourceConfig source, bool hookInstalled, string message)
        {
            var alias = string.IsNullOrWhiteSpace(source.Label) ? "Personal" : source.Label.Trim();
            return new AiLimitsAccountDto
            {
                Id = AiLimitsConfigStore.DeriveOpaqueAccountId(source.Id, "statusline|claude"),
                SourceId = source.Id,
                SourceKind = AiLimitsSourceKinds.ClaudeStatusLine,
                Provider = AiLimitsProviders.Claude,
                Product = "claude_code",
                ProviderLabel = "Claude",
                Alias = alias,
                DefaultAlias = alias,
                Plan = source.PlanLabel,
                ModelPool = "all",
                Enabled = true,
                ConnectionStatus = hookInstalled ? AiLimitsConnectionStatuses.Connected : AiLimitsConnectionStatuses.SetupRequired,
                QuotaStatus = AiLimitsQuotaStatuses.AwaitingData,
                Freshness = AiLimitsFreshness.Unavailable,
                SupportLevel = AiLimitsAccessModes.OfficialLocalHook,
                CoverageScope = AiLimitsCoverageScopes.AccountWideLastLocalTurn,
                ProvenanceLabel = "Claude · statusLine",
                ProvenanceDetails = "Official local Claude Code statusLine passive bridge. Never reads OAuth credential files or polls Anthropic usage APIs.",
                DashboardUrl = AiLimitsUrlValidator.ValidateDashboardUrl(source.DashboardUrl) ?? AiLimitsProviders.OfficialDashboardUrl(AiLimitsProviders.Claude),
                ErrorCode = hookInstalled ? AiLimitsErrorCodes.NoDataYet : AiLimitsErrorCodes.HookNotInstalled,
                StatusMessage = message,
                Windows = new List<AiLimitsWindowDto>
                {
                    AiLimitsNormalizer.BuildUnavailableWindow("five_hour", AiLimitsWindowKinds.FiveHour, "5h Limit", 300,
                        hookInstalled ? AiLimitsWindowStatuses.Unavailable : AiLimitsWindowStatuses.NotConnected,
                        hookInstalled ? "Run a Claude Code turn" : "Setup statusLine wrapper"),
                    AiLimitsNormalizer.BuildUnavailableWindow("weekly", AiLimitsWindowKinds.Weekly, "Weekly", 10080,
                        hookInstalled ? AiLimitsWindowStatuses.Unavailable : AiLimitsWindowStatuses.NotConnected,
                        hookInstalled ? "Run a Claude Code turn" : "Setup statusLine wrapper"),
                },
            };
        }

        // ---- Guided Non-Destructive Hook Setup / Install / Uninstall ----

        public AiLimitsSetupGuideResponse GetSetupGuide(AiLimitsSourceConfig source, bool isLocalRequest)
        {
            var settingsPath = Path.Combine(ResolveClaudeConfigDir(source.ConfigDir), "settings.json");
            var existingCmd = ReadExistingStatusLineCommand(settingsPath);
            var isInstalled = !string.IsNullOrEmpty(existingCmd) && existingCmd.Contains(WrapperMarker + AiLimitsConfigStore.SanitizeFileSegment(source.Id), StringComparison.OrdinalIgnoreCase);
            var hasOtherUserHook = !string.IsNullOrEmpty(existingCmd) && !isInstalled;
            var captureAvailable = CaptureRuntimeAvailable();
            var commandPreview = isInstalled
                ? existingCmd
                : BuildWrapperCommand(source.Id, hasOtherUserHook ? existingCmd : null);

            var caveats = new List<string>
            {
                "Updates only during active local Claude Code sessions (not while idle or using claude.ai web/mobile only).",
                "Claude Code hides some built-in footer hints (such as shortcut tips) whenever any custom statusLine is configured.",
                "Disabled if Claude Code settings set disableAllHooks=true or enterprise allowManagedHooksOnly.",
            };
            if (!captureAvailable)
                caveats.Insert(0, "python3 is required on macOS/Linux to capture rate_limits (on macOS, install the Xcode Command Line Tools first).");

            return new AiLimitsSetupGuideResponse
            {
                SourceId = source.Id,
                Kind = Kind,
                Supported = true,
                IsInstalled = isInstalled,
                HasExistingUserHook = hasOtherUserHook,
                CanAutoInstall = isLocalRequest && captureAvailable,
                CommandPreview = isLocalRequest ? commandPreview : null,
                Steps = new List<string>
                {
                    "Install the non-destructive DeckOS statusLine wrapper in Claude Code settings.json (from this PC).",
                    "If you already have a custom statusLine command, DeckOS pipes Claude Code's input through to it unchanged, so your existing footer keeps working.",
                    "Use Claude Code normally — Claude Code passes official rate_limits JSON on stdin with zero extra API requests.",
                },
                Caveats = caveats,
            };
        }

        public AiLimitsSetupGuideResponse InstallHook(AiLimitsSourceConfig source)
        {
            var configDir = ResolveClaudeConfigDir(source.ConfigDir);
            var settingsPath = Path.Combine(configDir, "settings.json");

            // Never rewrite a settings.json we can't parse exactly (comments, trailing commas, invalid JSON).
            if (!TryLoadSettingsJsonObject(settingsPath, out var root))
                return SettingsRefused(source, "Claude Code settings.json could not be read as plain JSON, so DeckOS left it unchanged. Fix the file or add the command below manually.");

            Directory.CreateDirectory(configDir);
            var snapshotPath = ResolveSnapshotPath(source);
            Directory.CreateDirectory(Path.GetDirectoryName(snapshotPath)!);
            Directory.CreateDirectory(_store.ScriptsDir);

            var existingCmd = ExtractStatusLineCommand(root);
            var marker = WrapperMarker + AiLimitsConfigStore.SanitizeFileSegment(source.Id);

            // Preserve the user's original statusLine entry (command + padding/refreshInterval) for uninstall.
            JsonNode? original;
            if (!string.IsNullOrWhiteSpace(existingCmd) && existingCmd.Contains(marker, StringComparison.OrdinalIgnoreCase))
            {
                original = LoadPreservedStatusLine(source.Id);
            }
            else
            {
                original = root.TryGetPropertyValue("statusLine", out var node) ? node?.DeepClone() : null;
                SavePreservedStatusLine(source.Id, original);
            }

            var previousCommand = original is JsonObject po && po.TryGetPropertyValue("command", out var pc) && pc is JsonValue pcv && pcv.TryGetValue<string>(out var pcs)
                ? pcs
                : original is JsonValue ov && ov.TryGetValue<string>(out var os) ? os : null;

            WriteWrapperScript(source.Id, snapshotPath);

            // Backup settings.json before modification
            if (File.Exists(settingsPath))
            {
                var backupPath = settingsPath + ".deckos-backup-" + DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmss", CultureInfo.InvariantCulture);
                try { File.Copy(settingsPath, backupPath, overwrite: false); } catch { }
            }

            var statusLine = original is JsonObject keep ? (JsonObject)keep.DeepClone() : new JsonObject();
            statusLine["type"] = "command";
            statusLine["command"] = BuildWrapperCommand(source.Id, previousCommand);
            root["statusLine"] = statusLine;

            SaveSettingsJsonAtomic(settingsPath, root);
            return GetSetupGuide(source, isLocalRequest: true);
        }

        public AiLimitsSetupGuideResponse UninstallHook(AiLimitsSourceConfig source)
        {
            var configDir = ResolveClaudeConfigDir(source.ConfigDir);
            var settingsPath = Path.Combine(configDir, "settings.json");
            if (File.Exists(settingsPath))
            {
                if (!TryLoadSettingsJsonObject(settingsPath, out var root))
                    return SettingsRefused(source, "Claude Code settings.json could not be read as plain JSON, so DeckOS left it unchanged. Remove the DeckOS statusLine command manually.");

                var existingCmd = ExtractStatusLineCommand(root);
                var marker = WrapperMarker + AiLimitsConfigStore.SanitizeFileSegment(source.Id);
                if (!string.IsNullOrWhiteSpace(existingCmd) && existingCmd.Contains(marker, StringComparison.OrdinalIgnoreCase))
                {
                    var original = LoadPreservedStatusLine(source.Id);
                    if (original != null)
                        root["statusLine"] = original;
                    else
                        root.Remove("statusLine");
                    SaveSettingsJsonAtomic(settingsPath, root);
                }
            }

            DeleteWrapperArtifacts(source.Id);
            return GetSetupGuide(source, isLocalRequest: true);
        }

        private AiLimitsSetupGuideResponse SettingsRefused(AiLimitsSourceConfig source, string message)
        {
            var guide = GetSetupGuide(source, isLocalRequest: true);
            guide.ErrorCode = AiLimitsErrorCodes.InternalError;
            guide.Message = message;
            return guide;
        }

        private string WrapperScriptPath(string sourceId)
        {
            var seg = AiLimitsConfigStore.SanitizeFileSegment(sourceId);
            var ext = OperatingSystem.IsWindows() ? ".ps1" : ".sh";
            return Path.Combine(_store.ScriptsDir, $"{WrapperMarker}{seg}{ext}");
        }

        private string PreservedStatusLinePath(string sourceId) =>
            Path.Combine(_store.ScriptsDir, $"{WrapperMarker}{AiLimitsConfigStore.SanitizeFileSegment(sourceId)}.prev.json");

        // Earlier builds kept only the previous command string.
        private string LegacyPreservedPrevPath(string sourceId) =>
            Path.Combine(_store.ScriptsDir, $"{WrapperMarker}{AiLimitsConfigStore.SanitizeFileSegment(sourceId)}.prev.txt");

        /// <summary>
        /// The statusLine command. With an existing user command, DeckOS captures stdin and passes it
        /// through unchanged into that command (`capture | previous`), so the previous command still runs
        /// in whichever shell Claude Code uses (Git Bash or PowerShell on Windows, sh elsewhere).
        /// </summary>
        public string BuildWrapperCommand(string sourceId, string? previousCommand)
        {
            var scriptPath = WrapperScriptPath(sourceId).Replace('\\', '/');
            // Official Claude Code Windows guidance: use forward slashes so Git Bash never strips backslashes.
            var capture = OperatingSystem.IsWindows()
                ? $"powershell -NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\""
                : $"sh \"{scriptPath}\"";
            if (string.IsNullOrWhiteSpace(previousCommand))
                return capture;
            return capture + (OperatingSystem.IsWindows() ? " -PassThru | " : " --passthru | ") + previousCommand.Trim();
        }

        /// <summary>
        /// Writes the capture script. It keeps only rate_limits.{five_hour,seven_day,spend_limit} fields
        /// and writes them atomically (pid temp + rename). Tombstone rule adapted from
        /// Maciek-roboblog/Claude-Code-Usage-Monitor (MIT, output/official.py capture_statusline): a payload
        /// without rate_limits clears the snapshot, but only once the session has made an API call —
        /// Claude Code omits rate_limits before the first response, which must not wipe the last reading.
        /// </summary>
        private void WriteWrapperScript(string sourceId, string snapshotPath)
        {
            var scriptPath = WrapperScriptPath(sourceId);
            if (OperatingSystem.IsWindows())
            {
                var snapEscaped = snapshotPath.Replace("'", "''");
                var ps1 = $$"""
                    # DeckOS non-destructive Claude Code statusLine passive bridge (keeps rate_limits only)
                    param([switch]$PassThru)
                    $ErrorActionPreference = 'SilentlyContinue'
                    try { [Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
                    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch {}
                    $raw = [Console]::In.ReadToEnd()
                    if ($raw) {
                      try {
                        $obj = $raw | ConvertFrom-Json
                        $rl = $obj.rate_limits
                        $apiMs = 0
                        try { $apiMs = [double]$obj.cost.total_api_duration_ms } catch {}
                        $write = $true
                        $clean = $null
                        if ($null -ne $rl) {
                          $clean = [ordered]@{}
                          foreach ($k in @('five_hour', 'seven_day', 'spend_limit')) {
                            $w = $rl.$k
                            if ($null -ne $w) {
                              $c = [ordered]@{}
                              foreach ($f in @('used_percentage', 'resets_at', 'used_usd', 'limit_usd', 'period')) {
                                if ($null -ne $w.$f) { $c[$f] = $w.$f }
                              }
                              if ($c.Count -gt 0) { $clean[$k] = $c }
                            }
                          }
                        } elseif (-not ($apiMs -gt 0)) {
                          $write = $false
                        }
                        if ($write) {
                          $out = [ordered]@{ schemaVersion = 1; observedAt = [DateTimeOffset]::UtcNow.ToString('O'); rate_limits = $clean } | ConvertTo-Json -Depth 6 -Compress
                          $dest = '{{snapEscaped}}'
                          $tmp = "$dest.$PID.tmp"
                          [System.IO.File]::WriteAllText($tmp, $out, [System.Text.UTF8Encoding]::new($false))
                          Move-Item -LiteralPath $tmp -Destination $dest -Force
                        }
                      } catch {}
                    }
                    if ($PassThru) { [Console]::Out.Write($raw) }

                    """;

                File.WriteAllText(scriptPath, ps1, new UTF8Encoding(false));
            }
            else
            {
                var snapEscaped = snapshotPath.Replace("'", "'\\''");
                var sh = $$"""
                    #!/bin/sh
                    # DeckOS non-destructive Claude Code statusLine passive bridge (keeps rate_limits only)
                    RAW="$(cat)"
                    DEST='{{snapEscaped}}'
                    PY=""
                    if command -v python3 >/dev/null 2>&1; then
                      PY="python3"
                      # macOS ships a /usr/bin/python3 stub that opens an installer dialog without the CLT.
                      if [ "$(uname -s)" = "Darwin" ] && [ "$(command -v python3)" = "/usr/bin/python3" ] && ! xcode-select -p >/dev/null 2>&1; then
                        PY=""
                      fi
                    fi
                    if [ -n "$RAW" ] && [ -n "$PY" ]; then
                      printf '%s' "$RAW" | "$PY" -c '
                    import json, os, sys, datetime
                    try:
                        d = json.load(sys.stdin)
                        rl = d.get("rate_limits")
                        cost = d.get("cost") if isinstance(d.get("cost"), dict) else dict()
                        api_ms = cost.get("total_api_duration_ms") or 0
                        if not isinstance(rl, dict) and not (isinstance(api_ms, (int, float)) and api_ms > 0):
                            sys.exit(0)
                        clean = None
                        if isinstance(rl, dict):
                            clean = dict()
                            for k in ("five_hour", "seven_day", "spend_limit"):
                                w = rl.get(k)
                                if isinstance(w, dict):
                                    c = dict((f, w[f]) for f in ("used_percentage", "resets_at", "used_usd", "limit_usd", "period") if f in w)
                                    if c:
                                        clean[k] = c
                        out = dict(schemaVersion=1, observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(), rate_limits=clean)
                        dest = sys.argv[1]
                        tmp = dest + "." + str(os.getpid()) + ".tmp"
                        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
                        with os.fdopen(fd, "w", encoding="utf-8") as f:
                            json.dump(out, f, separators=(",", ":"))
                        os.replace(tmp, dest)
                    except Exception:
                        pass
                    ' "$DEST" 2>/dev/null || true
                    fi
                    if [ "$1" = "--passthru" ]; then
                      printf '%s' "$RAW"
                    fi

                    """;

                File.WriteAllText(scriptPath, sh.Replace("\r\n", "\n"), new UTF8Encoding(false));
                try
                {
                    File.SetUnixFileMode(scriptPath,
                        UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
                }
                catch { }
            }
        }

        private static bool CaptureRuntimeAvailable()
        {
            if (OperatingSystem.IsWindows()) return true; // Windows PowerShell 5.1 ships with Windows.
            var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
            string? python = null;
            foreach (var dir in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            {
                try
                {
                    var candidate = Path.Combine(dir, "python3");
                    if (File.Exists(candidate)) { python = candidate; break; }
                }
                catch { }
            }
            if (python == null) return false;
            if (OperatingSystem.IsMacOS() && python == "/usr/bin/python3")
                return Directory.Exists("/Library/Developer/CommandLineTools") || Directory.Exists("/Applications/Xcode.app");
            return true;
        }

        private void SavePreservedStatusLine(string sourceId, JsonNode? statusLine)
        {
            var doc = new JsonObject { ["statusLine"] = statusLine?.DeepClone() };
            File.WriteAllText(PreservedStatusLinePath(sourceId), doc.ToJsonString(), new UTF8Encoding(false));
            try { var legacy = LegacyPreservedPrevPath(sourceId); if (File.Exists(legacy)) File.Delete(legacy); } catch { }
        }

        private JsonNode? LoadPreservedStatusLine(string sourceId)
        {
            try
            {
                var p = PreservedStatusLinePath(sourceId);
                if (File.Exists(p) && JsonNode.Parse(File.ReadAllText(p, Encoding.UTF8)) is JsonObject doc &&
                    doc.TryGetPropertyValue("statusLine", out var node))
                    return node?.DeepClone();

                var legacy = LegacyPreservedPrevPath(sourceId);
                if (File.Exists(legacy))
                {
                    var cmd = File.ReadAllText(legacy, Encoding.UTF8).Trim();
                    if (cmd.Length > 0)
                        return new JsonObject { ["type"] = "command", ["command"] = cmd };
                }
            }
            catch { }
            return null;
        }

        private void DeleteWrapperArtifacts(string sourceId)
        {
            try { var s = WrapperScriptPath(sourceId); if (File.Exists(s)) File.Delete(s); } catch { }
            try { var p = PreservedStatusLinePath(sourceId); if (File.Exists(p)) File.Delete(p); } catch { }
            try { var p = LegacyPreservedPrevPath(sourceId); if (File.Exists(p)) File.Delete(p); } catch { }
        }

        public static bool IsDeckOsWrapperConfigured(string settingsPath, string sourceId)
        {
            var cmd = ReadExistingStatusLineCommand(settingsPath);
            var marker = WrapperMarker + AiLimitsConfigStore.SanitizeFileSegment(sourceId);
            return !string.IsNullOrEmpty(cmd) && cmd.Contains(marker, StringComparison.OrdinalIgnoreCase);
        }

        public static string? ReadExistingStatusLineCommand(string settingsPath)
        {
            if (!File.Exists(settingsPath)) return null;
            try
            {
                var root = LoadSettingsJsonObject(settingsPath);
                return ExtractStatusLineCommand(root);
            }
            catch
            {
                return null;
            }
        }

        private static string? ExtractStatusLineCommand(JsonObject root)
        {
            if (!root.TryGetPropertyValue("statusLine", out var node) || node == null) return null;
            if (node is JsonValue v && v.TryGetValue<string>(out var s)) return s;
            if (node is JsonObject obj && obj.TryGetPropertyValue("command", out var cmdNode) && cmdNode is JsonValue cv && cv.TryGetValue<string>(out var cs))
                return cs;
            return null;
        }

        private static JsonObject LoadSettingsJsonObject(string settingsPath)
        {
            if (!File.Exists(settingsPath)) return new JsonObject();
            var parsed = JsonNode.Parse(File.ReadAllText(settingsPath, Encoding.UTF8));
            return parsed as JsonObject ?? new JsonObject();
        }

        private static bool TryLoadSettingsJsonObject(string settingsPath, out JsonObject root)
        {
            root = new JsonObject();
            if (!File.Exists(settingsPath)) return true;
            try
            {
                var text = File.ReadAllText(settingsPath, Encoding.UTF8);
                if (string.IsNullOrWhiteSpace(text)) return true;
                if (JsonNode.Parse(text) is not JsonObject obj) return false;
                root = obj;
                return true;
            }
            catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
            {
                return false;
            }
        }

        private static void SaveSettingsJsonAtomic(string settingsPath, JsonObject root)
        {
            var tmp = settingsPath + ".tmp." + Guid.NewGuid().ToString("N")[..8];
            var json = root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
            try
            {
                File.WriteAllText(tmp, json, new UTF8Encoding(false));
                File.Move(tmp, settingsPath, overwrite: true);
            }
            catch
            {
                try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
                throw;
            }
        }

        private static bool TryReadStatusLineWindow(JsonElement rl, string key, out double usedPercent, out DateTimeOffset? resetsAt)
        {
            usedPercent = 0;
            resetsAt = null;
            if (!rl.TryGetProperty(key, out var w) || w.ValueKind != JsonValueKind.Object) return false;
            if (!w.TryGetProperty("used_percentage", out var up) || up.ValueKind != JsonValueKind.Number) return false;

            // Guard against Claude Code bug #52326 (leaking Unix epoch timestamp in used_percentage):
            // adapted from Maciek-roboblog/Claude-Code-Usage-Monitor (_clean_pct, MIT).
            var cleaned = CleanSubscriptionPercent(up.GetDouble());
            if (!cleaned.HasValue) return false;

            usedPercent = cleaned.Value;
            resetsAt = ParseReset(w);
            return true;
        }

        public static double? CleanSubscriptionPercent(double raw)
        {
            if (double.IsNaN(raw) || double.IsInfinity(raw) || raw < 0.0) return null;
            if (raw > 101.0) return null; // Drop epoch-timestamp leaks rather than clamping to bogus 100%!
            return raw > 100.0 ? 100.0 : raw;
        }

        private static DateTimeOffset? ParseReset(JsonElement w)
        {
            if (!w.TryGetProperty("resets_at", out var ra)) return null;
            if (ra.ValueKind == JsonValueKind.Number && ra.TryGetInt64(out var unix) && unix > 0)
                return unix > 1_000_000_000_000L ? DateTimeOffset.FromUnixTimeMilliseconds(unix) : DateTimeOffset.FromUnixTimeSeconds(unix);
            if (ra.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(ra.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dt))
                return dt.ToUniversalTime();
            return null;
        }
    }
}
