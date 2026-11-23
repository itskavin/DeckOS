using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Models;

namespace DeckOS.Services.AiLimits
{
    public readonly record struct CodexRpcCallResult(
        bool Ok,
        bool CliMissing,
        bool AuthRequired,
        string? RawResultJson,
        string? ErrorCode,
        string? ErrorMessage);

    public interface ICodexAppServerRunner
    {
        Task<CodexRpcCallResult> ReadRateLimitsAsync(string? codexHome, CancellationToken ct);
    }

    /// <summary>
    /// Official OpenAI Codex app-server stdio JSON-RPC client:
    /// runs `codex -s read-only -a never app-server` (stdio transport), waits for the `initialize`
    /// response, sends `initialized`, calls `account/rateLimits/read` with
    /// `excludeResetCreditDetails: true` (zero inference, no thread/turn), and always kills the
    /// process tree. Launch flags and handshake order follow steipete/CodexBar (MIT,
    /// UsageFetcher.swift CodexRPCClient); verified against `codex app-server generate-json-schema`
    /// (codex-cli 0.166.0).
    /// </summary>
    public sealed class ProcessCodexAppServerRunner : ICodexAppServerRunner
    {
        private static readonly TimeSpan InitializeTimeout = TimeSpan.FromSeconds(8);
        private static readonly TimeSpan RpcTimeout = TimeSpan.FromSeconds(8);
        private static readonly string[] CodexArgs = { "-s", "read-only", "-a", "never", "app-server" };

        /// <summary>
        /// Resolves `codex` on PATH. Windows npm installs ship `codex.cmd`, which CreateProcess
        /// cannot start directly, so batch shims run through `cmd.exe /d /c`.
        /// </summary>
        public static (string FileName, List<string> Args)? ResolveLaunch()
        {
            var pathVar = Environment.GetEnvironmentVariable("PATH");
            if (string.IsNullOrWhiteSpace(pathVar)) return null;
            var exts = OperatingSystem.IsWindows() ? new[] { ".exe", ".cmd", ".bat" } : new[] { "" };

            foreach (var ext in exts)
            {
                foreach (var dir in pathVar.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                {
                    string candidate;
                    try { candidate = Path.Combine(dir.Trim('"'), "codex" + ext); }
                    catch { continue; }
                    if (!File.Exists(candidate)) continue;

                    if (ext is ".cmd" or ".bat")
                    {
                        var cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
                        var args = new List<string> { "/d", "/c", candidate };
                        args.AddRange(CodexArgs);
                        return (cmd, args);
                    }
                    return (candidate, CodexArgs.ToList());
                }
            }
            return null;
        }

        public async Task<CodexRpcCallResult> ReadRateLimitsAsync(string? codexHome, CancellationToken ct)
        {
            var launch = ResolveLaunch();
            if (launch == null)
                return new(false, true, false, null, AiLimitsErrorCodes.CliNotFound, "Codex CLI was not found on PATH.");

            var psi = new ProcessStartInfo
            {
                FileName = launch.Value.FileName,
                UseShellExecute = false,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardInputEncoding = new UTF8Encoding(false),
                StandardOutputEncoding = Encoding.UTF8,
                StandardErrorEncoding = Encoding.UTF8,
            };
            foreach (var a in launch.Value.Args) psi.ArgumentList.Add(a);

            if (!string.IsNullOrWhiteSpace(codexHome))
                psi.Environment["CODEX_HOME"] = codexHome;

            Process? proc = null;
            try
            {
                proc = Process.Start(psi);
            }
            catch (System.ComponentModel.Win32Exception)
            {
                return new(false, true, false, null, AiLimitsErrorCodes.CliNotFound, "Codex CLI was not found on PATH.");
            }
            catch (Exception)
            {
                return new(false, true, false, null, AiLimitsErrorCodes.CliNotFound, "Could not start codex app-server.");
            }

            if (proc == null)
                return new(false, true, false, null, AiLimitsErrorCodes.CliNotFound, "Could not start codex app-server.");

            using (proc)
            {
                // stderr is never parsed or logged (it can carry account details); drain it so the pipe can't fill.
                proc.ErrorDataReceived += (_, _) => { };
                proc.BeginErrorReadLine();
                try
                {
                    // 1) initialize → wait for its response before anything else (CodexBar serializes requests).
                    await proc.StandardInput.WriteLineAsync("""{"id":1,"method":"initialize","params":{"clientInfo":{"name":"deckos","title":"DeckOS","version":"1.0.0"}}}""");
                    await proc.StandardInput.FlushAsync(ct);
                    var init = await ReadResponseAsync(proc, 1, InitializeTimeout, ct);
                    if (init.Error is { } initErr)
                        return FromRpcError(initErr);
                    if (init.Result == null)
                        return new(false, false, false, null, AiLimitsErrorCodes.Timeout, "codex app-server did not finish initialize.");

                    // 2) initialized notification, then the single read-only rate-limit request.
                    await proc.StandardInput.WriteLineAsync("""{"method":"initialized","params":{}}""");
                    await proc.StandardInput.WriteLineAsync("""{"id":2,"method":"account/rateLimits/read","params":{"excludeResetCreditDetails":true}}""");
                    await proc.StandardInput.FlushAsync(ct);
                    var read = await ReadResponseAsync(proc, 2, RpcTimeout, ct);
                    if (read.Error is { } readErr)
                        return FromRpcError(readErr);
                    if (read.Result != null)
                        return new(true, false, false, read.Result, null, null);

                    return new(false, false, false, null, AiLimitsErrorCodes.Timeout, "codex app-server closed without returning rate limits.");
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    return new(false, false, false, null, AiLimitsErrorCodes.Timeout, "Timed out waiting for codex app-server.");
                }
                catch (IOException)
                {
                    return new(false, false, false, null, AiLimitsErrorCodes.Unreachable, "codex app-server exited unexpectedly.");
                }
                finally
                {
                    try { if (!proc.HasExited) proc.Kill(entireProcessTree: true); } catch { }
                }
            }
        }

        private static async Task<(string? Result, string? Error)> ReadResponseAsync(Process proc, int id, TimeSpan timeout, CancellationToken ct)
        {
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(timeout);
            while (true)
            {
                var line = await proc.StandardOutput.ReadLineAsync(timeoutCts.Token);
                if (line == null) return (null, null);
                if (string.IsNullOrWhiteSpace(line)) continue;
                try
                {
                    using var doc = JsonDocument.Parse(line);
                    var root = doc.RootElement;
                    // Notifications (no id) and other responses are skipped.
                    if (!root.TryGetProperty("id", out var idEl) || idEl.ValueKind != JsonValueKind.Number ||
                        !idEl.TryGetInt32(out var gotId) || gotId != id)
                        continue;

                    if (root.TryGetProperty("error", out var errEl) && errEl.ValueKind == JsonValueKind.Object)
                        return (null, errEl.TryGetProperty("message", out var m) && m.ValueKind == JsonValueKind.String ? m.GetString() ?? "Codex RPC error" : "Codex RPC error");
                    if (root.TryGetProperty("result", out var resEl) && resEl.ValueKind == JsonValueKind.Object)
                        return (resEl.GetRawText(), null);
                    return (null, "Codex RPC returned no result.");
                }
                catch (JsonException)
                {
                    // Non-JSON line; ignore.
                }
            }
        }

        private static CodexRpcCallResult FromRpcError(string msg)
        {
            var isAuth = msg.Contains("auth", StringComparison.OrdinalIgnoreCase)
                || msg.Contains("login", StringComparison.OrdinalIgnoreCase)
                || msg.Contains("sign in", StringComparison.OrdinalIgnoreCase)
                || msg.Contains("unauthorized", StringComparison.OrdinalIgnoreCase);
            return new(false, false, isAuth, null,
                isAuth ? AiLimitsErrorCodes.AuthFailed : AiLimitsErrorCodes.InternalError,
                isAuth ? "Codex requires sign-in (run `codex login`)." : "codex app-server could not read rate limits.");
        }
    }

    /// <summary>
    /// Official OpenAI Codex adapter:
    /// 1. Primary: `codex app-server --listen stdio://` (`account/rateLimits/read`, zero inference).
    /// 2. Fallback: passive incremental scan of `CODEX_HOME/sessions/**/*.jsonl` (`token_count.rate_limits`).
    /// Multi-account is supported by configuring separate `configDir` (`CODEX_HOME`) sources.
    /// </summary>
    public sealed class CodexLocalAdapter : IAiLimitsSourceAdapter
    {
        public const string ModeRpcWithFallback = "rpc_with_log_fallback";
        public const string ModeLogsOnly = "logs_only";

        private readonly ICodexAppServerRunner _runner;

        public CodexLocalAdapter(ICodexAppServerRunner? runner = null)
        {
            _runner = runner ?? new ProcessCodexAppServerRunner();
        }

        public string Kind => AiLimitsSourceKinds.CodexLocal;

        public AiLimitsSourceKindDescriptorDto Descriptor => new()
        {
            Kind = Kind,
            Title = "OpenAI Codex (Official Local)",
            Description = "Uses official local `codex app-server` rate-limit RPC (zero inference) with automatic passive session-log fallback. Supports multiple accounts via separate CODEX_HOME directories.",
            AccessMode = AiLimitsAccessModes.OfficialLocalRpc,
            RequiresCredential = false,
            SupportsMultiAccount = true,
            SupportsGuidedSetup = true,
            SupportsTestConnection = true,
            ProvenanceNote = "Uses OpenAI's documented local app-server protocol (`account/rateLimits/read`) and never starts model generations or consumes reset credits.",
        };

        public static string ResolveCodexHome(string? configDir)
        {
            if (!string.IsNullOrWhiteSpace(configDir))
                return configDir.Trim();
            return AiUsageService.CodexDir;
        }

        public async Task<AiLimitsAdapterResult> FetchAsync(
            AiLimitsSourceConfig source,
            string? secret,
            DateTimeOffset now,
            CancellationToken ct)
        {
            var codexHome = ResolveCodexHome(source.ConfigDir);
            var mode = string.Equals(source.CodexMode, ModeLogsOnly, StringComparison.OrdinalIgnoreCase)
                ? ModeLogsOnly
                : ModeRpcWithFallback;

            if (mode == ModeRpcWithFallback)
            {
                var rpc = await _runner.ReadRateLimitsAsync(string.IsNullOrWhiteSpace(source.ConfigDir) ? null : codexHome, ct);
                if (rpc.Ok && !string.IsNullOrWhiteSpace(rpc.RawResultJson))
                {
                    try
                    {
                        var accounts = ParseAppServerResult(source, rpc.RawResultJson, now);
                        return new AiLimitsAdapterResult
                        {
                            Ok = true,
                            Reachable = true,
                            Status = accounts.Count > 0 ? AiLimitsSourceStatuses.Connected : AiLimitsSourceStatuses.AwaitingData,
                            StatusMessage = $"Connected via official codex app-server ({accounts.Count} quota bucket{(accounts.Count == 1 ? "" : "s")}).",
                            DetectedApiVersion = "codex-app-server",
                            CapabilitiesNote = "Live account-wide rate limits via official stdio RPC (zero inference).",
                            Accounts = accounts,
                        };
                    }
                    catch (JsonException)
                    {
                        // Fall through to passive log fallback if RPC schema was unexpected.
                    }
                }
                else if (rpc.AuthRequired)
                {
                    return new AiLimitsAdapterResult
                    {
                        Ok = false,
                        Reachable = true,
                        Status = AiLimitsSourceStatuses.AuthRequired,
                        ErrorCode = AiLimitsErrorCodes.AuthFailed,
                        StatusMessage = rpc.ErrorMessage ?? "Codex sign-in required.",
                        AuthCircuitBreak = true,
                    };
                }
            }

            // Passive zero-network fallback: CODEX_HOME/sessions/**/*.jsonl
            var sessionsDir = Path.Combine(codexHome, "sessions");
            var logAccount = await Task.Run(() => ReadLatestFromSessionLogs(source, sessionsDir, now), ct);
            if (logAccount != null)
            {
                return new AiLimitsAdapterResult
                {
                    Ok = true,
                    Reachable = true,
                    Status = AiLimitsSourceStatuses.Connected,
                    StatusMessage = mode == ModeLogsOnly
                        ? "Reading passive Codex session logs."
                        : "Codex app-server unavailable; showing latest passive session log snapshot.",
                    DetectedApiVersion = "codex-session-jsonl",
                    CapabilitiesNote = "Passive local session log observation; reflects your last local Codex CLI turn.",
                    Accounts = new List<AiLimitsAccountDto> { logAccount },
                };
            }

            return new AiLimitsAdapterResult
            {
                Ok = false,
                Reachable = Directory.Exists(codexHome),
                Status = Directory.Exists(codexHome) ? AiLimitsSourceStatuses.AwaitingData : AiLimitsSourceStatuses.SetupRequired,
                ErrorCode = Directory.Exists(codexHome) ? AiLimitsErrorCodes.NoDataYet : AiLimitsErrorCodes.CliNotFound,
                StatusMessage = Directory.Exists(codexHome)
                    ? "No Codex rate-limit snapshot found yet. Sign in to Codex CLI or run a normal local turn."
                    : "Codex CLI or CODEX_HOME directory was not found on this machine.",
            };
        }

        /// <summary>Stable per-source account id shared by the RPC and session-log paths, so tiles keep
        /// their binding when the adapter falls back between them. One CODEX_HOME = one account.</summary>
        public static string AccountIdFor(AiLimitsSourceConfig source) =>
            AiLimitsConfigStore.DeriveOpaqueAccountId(source.Id, "codex|account");

        /// <summary>
        /// Parses official OpenAI Codex app-server `account/rateLimits/read` responses
        /// (GetAccountRateLimitsResponse: rateLimits, rateLimitsByLimitId, ordinaryUsageAllowed, accountId).
        /// Attribution: duration-based window classification (a single 10080-min Pro primary window lands in
        /// weekly, 5h marked not applicable), extra-bucket model-pool mapping and camelCase/snake_case decoding
        /// adapted from steipete/CodexBar (CodexRateWindowNormalizer.swift, CodexAdditionalRateLimitMapper.swift,
        /// UsageFetcher.swift; MIT).
        /// </summary>
        public static List<AiLimitsAccountDto> ParseAppServerResult(AiLimitsSourceConfig source, string resultJson, DateTimeOffset now)
        {
            using var doc = JsonDocument.Parse(resultJson);
            var root = doc.RootElement;

            // "Null means unavailable; clients must not infer recovery from percentages or reset times."
            bool? ordinaryAllowed = TryGetBool(root, "ordinaryUsageAllowed", "ordinary_usage_allowed");

            JsonElement? main = TryGetObject(root, out var singleEl, "rateLimits", "rate_limits") ? singleEl : null;
            var mainKey = main is { } m0 ? TryGetString(m0, "limitId", "limit_id") ?? "codex" : "codex";

            var extras = new List<(string Key, JsonElement Bucket)>();
            if (TryGetObject(root, out var mapEl, "rateLimitsByLimitId", "rate_limits_by_limit_id"))
            {
                foreach (var prop in mapEl.EnumerateObject())
                {
                    if (prop.Value.ValueKind != JsonValueKind.Object) continue;
                    if (string.Equals(prop.Name, mainKey, StringComparison.OrdinalIgnoreCase))
                    {
                        main ??= prop.Value;
                        continue;
                    }
                    extras.Add((prop.Name, prop.Value));
                }
            }
            if (main == null && extras.Count > 0)
            {
                main = extras[0].Bucket;
                mainKey = extras[0].Key;
                extras.RemoveAt(0);
            }
            if (main == null)
                return new List<AiLimitsAccountDto>();

            var bucket = main.Value;
            var planRaw = TryGetString(bucket, "planType", "plan_type");
            var plan = FormatPlan(AiLimitsNormalizer.SanitizeText(planRaw ?? source.PlanLabel, 32));
            var reached = TryGetString(bucket, "rateLimitReachedType", "rate_limit_reached_type") != null;

            var windows = new List<AiLimitsWindowDto>();
            var primaryKind = AddRpcWindow(bucket, "primary", AiLimitsWindowKinds.FiveHour, "5h Limit", 300, now, ordinaryAllowed, reached, "all", null, windows);
            AddRpcWindow(bucket, "secondary", AiLimitsWindowKinds.Weekly, "Weekly", 10080, now, ordinaryAllowed, reached, "all", null, windows);

            if (windows.All(w => w.Kind != AiLimitsWindowKinds.FiveHour))
            {
                // Pro plans have no 5h cap (OpenAI pricing; CodexBar normalizer). Otherwise it simply wasn't reported.
                var isPro = AiLimitsNormalizer.IsCodexProPlan(planRaw);
                var weeklyOnly = isPro || primaryKind == AiLimitsWindowKinds.Weekly;
                windows.Add(AiLimitsNormalizer.BuildUnavailableWindow(
                    "five_hour",
                    AiLimitsWindowKinds.FiveHour,
                    "5h Limit",
                    300,
                    weeklyOnly ? AiLimitsWindowStatuses.NotApplicable : AiLimitsWindowStatuses.Unavailable,
                    isPro ? "No 5h cap on Pro" : weeklyOnly ? "Weekly-only plan" : "Not reported by Codex"));
            }
            if (windows.All(w => w.Kind != AiLimitsWindowKinds.Weekly))
            {
                windows.Add(AiLimitsNormalizer.BuildUnavailableWindow(
                    "weekly", AiLimitsWindowKinds.Weekly, "Weekly", 10080, AiLimitsWindowStatuses.Unavailable, "Not reported by Codex"));
            }

            AddCreditsWindow(bucket, "all", "credits", windows);
            AddSpendControlWindow(bucket, "all", "spend_limit", now, windows);

            // CodexBar CodexAdditionalRateLimitMapper: extra metered buckets (e.g. codex_bengalfox /
            // "GPT-5.3-Codex-Spark") become named model-pool windows on the same account.
            foreach (var (key, extra) in extras)
            {
                var poolName = AiLimitsNormalizer.SanitizeText(TryGetString(extra, "limitName", "limit_name"), 48) ?? key;
                var slug = Slugify(key);
                var extraReached = TryGetString(extra, "rateLimitReachedType", "rate_limit_reached_type") != null;
                AddRpcWindow(extra, "primary", AiLimitsWindowKinds.FiveHour, "5h", 300, now, ordinaryAllowed, extraReached, poolName, "pool:" + slug, windows);
                AddRpcWindow(extra, "secondary", AiLimitsWindowKinds.Weekly, "Weekly", 10080, now, ordinaryAllowed, extraReached, poolName, "pool:" + slug, windows);
            }

            var isLimited = ordinaryAllowed == false || reached || windows.Any(w => w.Status == AiLimitsWindowStatuses.RateLimited);
            var hasAnyWindow = windows.Any(w => w.Status is AiLimitsWindowStatuses.Available or AiLimitsWindowStatuses.RateLimited);
            var alias = AiLimitsNormalizer.SanitizeText(source.Label, 64) ?? "Personal";

            return new List<AiLimitsAccountDto>
            {
                new AiLimitsAccountDto
                {
                    Id = AccountIdFor(source),
                    SourceId = source.Id,
                    SourceKind = AiLimitsSourceKinds.CodexLocal,
                    Provider = AiLimitsProviders.Codex,
                    Product = "codex",
                    ProviderLabel = "Codex",
                    Alias = alias,
                    DefaultAlias = alias,
                    Plan = plan,
                    ModelPool = "all",
                    Enabled = true,
                    ConnectionStatus = AiLimitsConnectionStatuses.Connected,
                    QuotaStatus = isLimited
                        ? AiLimitsQuotaStatuses.RateLimited
                        : hasAnyWindow ? AiLimitsQuotaStatuses.Ok : AiLimitsQuotaStatuses.AwaitingData,
                    Freshness = hasAnyWindow || isLimited ? AiLimitsFreshness.Fresh : AiLimitsFreshness.Unavailable,
                    SupportLevel = AiLimitsAccessModes.OfficialLocalRpc,
                    CoverageScope = AiLimitsCoverageScopes.AccountWideLive,
                    ProvenanceLabel = "Codex · app-server",
                    ProvenanceDetails = "Account-wide rate limits read via the official local `codex app-server` (`account/rateLimits/read`) with zero model inference.",
                    ObservedAt = now,
                    StaleAfterSeconds = 600,
                    OrdinaryUsageAllowed = ordinaryAllowed,
                    DashboardUrl = AiLimitsUrlValidator.ValidateDashboardUrl(source.DashboardUrl) ?? AiLimitsProviders.OfficialDashboardUrl(AiLimitsProviders.Codex),
                    StatusMessage = ordinaryAllowed == false ? "Ordinary usage currently limited by Codex." : null,
                    Windows = AiLimitsNormalizer.OrderWindows(windows),
                },
            };
        }

        /// <summary>Adds a primary/secondary window; returns its classified kind, or null when absent.</summary>
        private static string? AddRpcWindow(
            JsonElement bucket,
            string propName,
            string fallbackKind,
            string fallbackLabel,
            int fallbackMinutes,
            DateTimeOffset now,
            bool? ordinaryAllowed,
            bool reached,
            string modelPool,
            string? idPrefix,
            List<AiLimitsWindowDto> windows)
        {
            if (!bucket.TryGetProperty(propName, out var w) || w.ValueKind != JsonValueKind.Object)
                return null;
            var pct = TryGetDouble(w, "usedPercent", "used_percent");
            if (!pct.HasValue)
                return null;

            var mins = TryGetInt(w, "windowDurationMins", "window_duration_mins", "window_minutes") ?? fallbackMinutes;
            DateTimeOffset? resetsAt = TryGetLong(w, "resetsAt", "resets_at") is { } unix && unix > 0
                ? DateTimeOffset.FromUnixTimeSeconds(unix)
                : null;

            var (kind, label) = AiLimitsNormalizer.ClassifyWindowMinutes(mins, fallbackKind, fallbackLabel);
            var baseId = kind == AiLimitsWindowKinds.Custom ? propName : kind;
            var isPool = idPrefix != null;
            windows.Add(AiLimitsNormalizer.BuildPercentWindow(
                isPool ? idPrefix + ":" + baseId : baseId,
                kind,
                isPool ? modelPool + " " + label : label,
                mins,
                pct.Value,
                resetsAt,
                now,
                now,
                staleAfterSeconds: 600,
                modelPool: modelPool,
                // Only the main pool carries the account-level permission flag.
                ordinaryUsageAllowed: isPool ? null : ordinaryAllowed,
                isRateLimited: reached && pct.Value >= 99.5,
                clampOverflow: true));
            return kind;
        }

        private static void AddCreditsWindow(JsonElement bucket, string modelPool, string id, List<AiLimitsWindowDto> windows)
        {
            if (!TryGetObject(bucket, out var credEl, "credits")) return;
            var hasCredits = TryGetBool(credEl, "hasCredits", "has_credits") == true;
            var unlimited = TryGetBool(credEl, "unlimited") == true;
            if (!hasCredits || unlimited || !credEl.TryGetProperty("balance", out var balEl)) return;

            // Schema: CreditsSnapshot.balance is a string (a number in older builds).
            double? bal = balEl.ValueKind switch
            {
                JsonValueKind.Number => balEl.GetDouble(),
                JsonValueKind.String when double.TryParse(balEl.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var d) => d,
                _ => null,
            };
            if (bal is not { } balance || double.IsNaN(balance) || double.IsInfinity(balance)) return;

            // A balance is not an allowance: no limit or percentage is implied.
            windows.Add(new AiLimitsWindowDto
            {
                Id = id,
                Kind = AiLimitsWindowKinds.Credits,
                Label = "Credits",
                Unit = AiLimitsWindowUnits.Credits,
                Status = AiLimitsWindowStatuses.Available,
                ModelPool = modelPool,
                Note = "Balance: " + balance.ToString("0.##", CultureInfo.InvariantCulture),
            });
        }

        private static void AddSpendControlWindow(JsonElement bucket, string modelPool, string id, DateTimeOffset now, List<AiLimitsWindowDto> windows)
        {
            // SpendControlLimitSnapshot { limit, used, remainingPercent, resetsAt } (workspace spend controls).
            if (!TryGetObject(bucket, out var sc, "individualLimit", "individual_limit")) return;
            var remaining = TryGetDouble(sc, "remainingPercent", "remaining_percent");
            if (!remaining.HasValue) return;
            DateTimeOffset? resetsAt = TryGetLong(sc, "resetsAt", "resets_at") is { } unix && unix > 0
                ? DateTimeOffset.FromUnixTimeSeconds(unix)
                : null;
            var spendReached = TryGetBool(bucket, "spendControlReached", "spend_control_reached") == true;
            windows.Add(AiLimitsNormalizer.BuildPercentWindow(
                id, AiLimitsWindowKinds.SpendLimit, "Spend Limit", null,
                100.0 - Math.Clamp(remaining.Value, 0.0, 100.0), resetsAt, now, now,
                staleAfterSeconds: 600, modelPool: modelPool, isRateLimited: spendReached));
        }

        private static string Slugify(string key)
        {
            var sb = new StringBuilder(key.Length);
            foreach (var c in key.ToLowerInvariant())
                sb.Append(char.IsLetterOrDigit(c) ? c : '_');
            var s = sb.ToString().Trim('_');
            return s.Length == 0 ? "pool" : (s.Length > 40 ? s[..40] : s);
        }

        private static bool TryGetObject(JsonElement obj, out JsonElement found, params string[] names)
        {
            foreach (var n in names)
            {
                if (obj.TryGetProperty(n, out found) && found.ValueKind == JsonValueKind.Object)
                    return true;
            }
            found = default;
            return false;
        }

        private static string? TryGetString(JsonElement obj, params string[] names)
        {
            foreach (var n in names)
            {
                if (obj.TryGetProperty(n, out var el) && el.ValueKind == JsonValueKind.String)
                    return el.GetString();
            }
            return null;
        }

        private static bool? TryGetBool(JsonElement obj, params string[] names)
        {
            foreach (var n in names)
            {
                if (obj.TryGetProperty(n, out var el) && (el.ValueKind == JsonValueKind.True || el.ValueKind == JsonValueKind.False))
                    return el.GetBoolean();
            }
            return null;
        }

        private static double? TryGetDouble(JsonElement obj, params string[] names)
        {
            foreach (var n in names)
            {
                if (obj.TryGetProperty(n, out var el) && el.ValueKind == JsonValueKind.Number)
                    return el.GetDouble();
            }
            return null;
        }

        private static int? TryGetInt(JsonElement obj, params string[] names)
        {
            foreach (var n in names)
            {
                if (obj.TryGetProperty(n, out var el) && el.ValueKind == JsonValueKind.Number && el.TryGetInt32(out var v))
                    return v;
            }
            return null;
        }

        private static long? TryGetLong(JsonElement obj, params string[] names)
        {
            foreach (var n in names)
            {
                if (obj.TryGetProperty(n, out var el) && el.ValueKind == JsonValueKind.Number && el.TryGetInt64(out var v))
                    return v;
            }
            return null;
        }

        public static AiLimitsAccountDto? ReadLatestFromSessionLogs(AiLimitsSourceConfig source, string sessionsDir, DateTimeOffset now)
        {
            if (!Directory.Exists(sessionsDir)) return null;

            var cutoff = now.AddDays(-8);
            DateTimeOffset? bestAt = null;
            List<AiLimitsWindowDto>? bestWindows = null;

            IEnumerable<FileInfo> files;
            try
            {
                files = Directory.EnumerateFiles(sessionsDir, "*.jsonl", SearchOption.AllDirectories)
                    .Select(p => { try { return new FileInfo(p); } catch { return null; } })
                    .Where(fi => fi != null && fi.LastWriteTimeUtc >= cutoff.UtcDateTime)
                    .OrderByDescending(fi => fi!.LastWriteTimeUtc)
                    .Take(12)!;
            }
            catch
            {
                return null;
            }

            foreach (var fi in files)
            {
                try
                {
                    using var fs = new FileStream(fi.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    using var sr = new StreamReader(fs, Encoding.UTF8);
                    string? line;
                    while ((line = sr.ReadLine()) != null)
                    {
                        if (!line.Contains("\"token_count\"", StringComparison.Ordinal)) continue;
                        if (!TryParseCodexLogLine(line, now, out var at, out var parsedWindows)) continue;
                        if (!bestAt.HasValue || at > bestAt.Value)
                        {
                            bestAt = at;
                            bestWindows = parsedWindows;
                        }
                    }
                }
                catch
                {
                    // Skip unreadable/rotating files safely.
                }
            }

            if (bestAt == null || bestWindows == null || bestWindows.Count == 0)
                return null;

            var alias = string.IsNullOrWhiteSpace(source.Label) ? "Personal" : source.Label.Trim();
            var anyAvailable = bestWindows.Any(w => w.Status == AiLimitsWindowStatuses.Available);

            return new AiLimitsAccountDto
            {
                Id = AccountIdFor(source),
                SourceId = source.Id,
                SourceKind = AiLimitsSourceKinds.CodexLocal,
                Provider = AiLimitsProviders.Codex,
                Product = "codex",
                ProviderLabel = "Codex",
                Alias = alias,
                DefaultAlias = alias,
                Plan = FormatPlan(source.PlanLabel),
                ModelPool = "all",
                Enabled = true,
                ConnectionStatus = AiLimitsConnectionStatuses.Connected,
                QuotaStatus = anyAvailable ? AiLimitsQuotaStatuses.Ok : AiLimitsQuotaStatuses.Stale,
                Freshness = anyAvailable ? AiLimitsFreshness.Fresh : AiLimitsFreshness.Stale,
                SupportLevel = AiLimitsAccessModes.PassiveLocalFile,
                CoverageScope = AiLimitsCoverageScopes.AccountWideLastLocalTurn,
                ProvenanceLabel = "Codex · Session logs",
                ProvenanceDetails = "Passively parsed from local Codex session rollout logs (`token_count.rate_limits`). Zero network requests; reflects your last local CLI turn.",
                ObservedAt = bestAt,
                StaleAfterSeconds = AiLimitsNormalizer.DefaultStaleAfterSeconds,
                DashboardUrl = AiLimitsUrlValidator.ValidateDashboardUrl(source.DashboardUrl) ?? AiLimitsProviders.OfficialDashboardUrl(AiLimitsProviders.Codex),
                Windows = AiLimitsNormalizer.OrderWindows(bestWindows),
            };
        }

        private static bool TryParseCodexLogLine(string line, DateTimeOffset now, out DateTimeOffset observedAt, out List<AiLimitsWindowDto> windows)
        {
            observedAt = default;
            windows = new List<AiLimitsWindowDto>();
            try
            {
                using var doc = JsonDocument.Parse(line);
                var root = doc.RootElement;
                if (!root.TryGetProperty("payload", out var payload) || payload.ValueKind != JsonValueKind.Object) return false;
                if (!payload.TryGetProperty("type", out var t) || t.GetString() != "token_count") return false;
                if (!root.TryGetProperty("timestamp", out var ts) || !DateTimeOffset.TryParse(ts.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out observedAt))
                    return false;
                observedAt = observedAt.ToUniversalTime();

                if (!payload.TryGetProperty("rate_limits", out var rl) || rl.ValueKind != JsonValueKind.Object)
                    return false;

                ReadLogWindow(rl, "primary", AiLimitsWindowKinds.FiveHour, "5h Limit", 300, observedAt, now, windows);
                ReadLogWindow(rl, "secondary", AiLimitsWindowKinds.Weekly, "Weekly", 10080, observedAt, now, windows);
                return windows.Count > 0;
            }
            catch
            {
                return false;
            }
        }

        private static void ReadLogWindow(
            JsonElement rl,
            string prop,
            string fallbackKind,
            string fallbackLabel,
            int fallbackMins,
            DateTimeOffset observedAt,
            DateTimeOffset now,
            List<AiLimitsWindowDto> windows)
        {
            if (!rl.TryGetProperty(prop, out var w) || w.ValueKind != JsonValueKind.Object) return;
            if (!w.TryGetProperty("used_percent", out var u) || u.ValueKind != JsonValueKind.Number) return;

            var mins = w.TryGetProperty("window_minutes", out var wm) && wm.ValueKind == JsonValueKind.Number
                ? wm.GetInt32()
                : fallbackMins;
            DateTimeOffset? resetsAt = null;
            if (w.TryGetProperty("resets_at", out var ra) && ra.TryGetInt64(out var unix) && unix > 0)
                resetsAt = DateTimeOffset.FromUnixTimeSeconds(unix);
            else if (w.TryGetProperty("resets_in_seconds", out var ris) && ris.TryGetInt64(out var secs) && secs > 0)
                resetsAt = observedAt.AddSeconds(secs);

            var (kind, label) = AiLimitsNormalizer.ClassifyWindowMinutes(mins, fallbackKind, fallbackLabel);
            var id = kind == AiLimitsWindowKinds.Custom ? prop : kind;
            windows.Add(AiLimitsNormalizer.BuildPercentWindow(id, kind, label, mins, u.GetDouble(), resetsAt, observedAt, now, clampOverflow: true));
        }

        private static string? FormatPlan(string? raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return null;
            var t = raw.Trim();
            return char.ToUpperInvariant(t[0]) + t[1..];
        }
    }
}
