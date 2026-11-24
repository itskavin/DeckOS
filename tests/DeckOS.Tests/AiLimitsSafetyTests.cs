using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Models;
using DeckOS.Services.AiLimits;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace DeckOS.Tests
{
    /// <summary>
    /// Account-safety rules for AI Limits: rejected CLIProxyAPI keys are never resent, Retry-After is
    /// honored, Codex/Claude payloads map to honest windows, and Claude settings are never clobbered.
    /// Every upstream payload here is a fixture in the real wire format; nothing talks to a live proxy,
    /// Codex backend or Anthropic.
    /// </summary>
    public class AiLimitsSafetyTests : IDisposable
    {
        private readonly string _dir = Path.Combine(Path.GetTempPath(), "deckos-ailimits-safety-" + Guid.NewGuid().ToString("N"));

        public AiLimitsSafetyTests() => Directory.CreateDirectory(_dir);

        public void Dispose()
        {
            try { Directory.Delete(_dir, recursive: true); } catch { }
        }

        /// <summary>Fake CLIProxyAPI management endpoint: accepts one key, records every request.</summary>
        private sealed class FakeProxy : HttpMessageHandler
        {
            public string GoodKey { get; set; } = "good-key";
            public Func<HttpResponseMessage>? Override { get; set; }
            public List<string> SentKeys { get; } = new();
            public string Body { get; set; } = """{"observed_at":"2026-11-23T12:00:00Z","files":[]}""";

            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
            {
                var key = request.Headers.TryGetValues("X-Management-Key", out var v) ? v.First() : "";
                SentKeys.Add(key);
                if (Override != null) return Task.FromResult(Override());
                if (key != GoodKey)
                    return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized)
                    {
                        Content = new StringContent("""{"error":"invalid management key"}"""),
                    });
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent(Body, Encoding.UTF8, "application/json"),
                });
            }
        }

        private sealed class NoCodex : ICodexAppServerRunner
        {
            public Task<CodexRpcCallResult> ReadRateLimitsAsync(string? codexHome, CancellationToken ct) =>
                Task.FromResult(new CodexRpcCallResult(false, true, false, null, AiLimitsErrorCodes.CliNotFound, "not installed"));
        }

        private sealed class NoEnv : IAiLimitsEnvironmentDetector
        {
            public Task<AiLimitsDetectedEnvironmentDto> DetectAsync(CancellationToken ct) => Task.FromResult(new AiLimitsDetectedEnvironmentDto());
        }

        private (AiLimitsService Svc, AiLimitsConfigStore Store, Func<DateTimeOffset> Now, Action<TimeSpan> Advance) NewService(FakeProxy proxy, string name)
        {
            var now = new DateTimeOffset(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);
            var store = new AiLimitsConfigStore(Path.Combine(_dir, name));
            var claude = new ClaudeStatusLineAdapter(store);
            var svc = new AiLimitsService(
                NullLogger<AiLimitsService>.Instance,
                store,
                new IAiLimitsSourceAdapter[] { new CliProxyPassiveAdapter(proxy), claude, new CodexLocalAdapter(new NoCodex()), new GeminiOtelAdapter(), new ManualDashboardAdapter() },
                claude,
                new NoEnv(),
                hub: null,
                clock: () => now,
                connectedClientsCount: () => 1);
            return (svc, store, () => now, d => now = now.Add(d));
        }

        [Fact]
        public async Task IdentityPrivacy_AliasClear_Restart_HubAndPreview_KeepStableIdsAndDoNotRefetch()
        {
            var proxy = new FakeProxy { Body = """{"files":[{"auth_index":"fixture-slot","provider":"codex","display_name":"Fixture Person","email":"fixture@example.test","name":"do-not-display.json","id_token":"SECRET_FIXTURE"}]}""" };
            var (svc, store, _, _) = NewService(proxy, "identity");
            var created = await svc.CreateSourceAsync(new AiLimitsSourceUpsertRequest { Kind = AiLimitsSourceKinds.CliProxyPassive, BaseUrl = "http://127.0.0.1:8317", Credential = "good-key" });
            var account = Assert.Single(created.Accounts);
            Assert.Equal("Fixture Person", account.Alias);
            Assert.True(account.HasReportedName);
            var stableId = account.Id;
            var calls = proxy.SentKeys.Count;
            var hidden = await svc.UpdatePrivacyAsync(true);
            Assert.Equal(calls, proxy.SentKeys.Count);
            Assert.Equal("Codex #1", Assert.Single(hidden.Accounts).Alias);
            Assert.DoesNotContain("Fixture Person", JsonSerializer.Serialize(hidden));
            Assert.DoesNotContain("fixture@example.test", JsonSerializer.Serialize(svc.GetCachedSnapshotForHub()));
            var renamed = await svc.UpdateAccountAsync(stableId, new AiLimitsAccountUpdateRequest { Alias = "Travel" });
            Assert.Equal("Travel", renamed.Account!.Alias);
            Assert.Equal(stableId, renamed.Account.Id);
            var preview = await svc.TestSourceAsync(new AiLimitsSourceTestRequest { SourceId = created.Source!.Id, Kind = AiLimitsSourceKinds.CliProxyPassive, BaseUrl = "http://127.0.0.1:8317" });
            Assert.Equal("Travel", Assert.Single(preview.Accounts).Alias);
            Assert.DoesNotContain("Fixture Person", JsonSerializer.Serialize(preview));
            Assert.DoesNotContain("SECRET_FIXTURE", JsonSerializer.Serialize(preview));
            Assert.DoesNotContain("do-not-display.json", JsonSerializer.Serialize(preview));
            Assert.DoesNotContain("Fixture Person", File.ReadAllText(store.ConfigPath));
            var (restarted, _, _, _) = NewService(proxy, "identity");
            var refreshed = await restarted.ManualRefreshAsync(created.Source.Id);
            Assert.True(refreshed.Snapshot.HideAccountNames);
            Assert.Equal("Travel", Assert.Single(refreshed.Snapshot.Accounts).Alias);
            Assert.Equal(stableId, Assert.Single(refreshed.Snapshot.Accounts).Id);
            var cleared = await restarted.UpdateAccountAsync(stableId, new AiLimitsAccountUpdateRequest { Alias = "" });
            Assert.Null(cleared.Account!.CustomAlias);
            Assert.Equal("Codex #1", cleared.Account.Alias);
            var revealed = await restarted.UpdatePrivacyAsync(false);
            Assert.Equal("Fixture Person", Assert.Single(revealed.Accounts).Alias);
        }

        [Fact]
        public void IdentityAllowlist_RejectsTokenClaimsFilenameControlsAndOversizedAliases()
        {
            var accounts = CliProxyPassiveAdapter.ParseCredentialsPayload("fixture", """{"files":[{"provider":"claude","name":"person@example.test.json","path":"/fixture/person","id_token":{"email":"hidden@example.test"}},{"provider":"codex","display_name":"Good\u202eBad","email":"fixture@example.test"}]}""", DateTimeOffset.UtcNow);
            Assert.Null(accounts[0].ReportedName);
            Assert.Equal("fixture@example.test", accounts[1].ReportedName);
            Assert.Throws<ArgumentException>(() => AiAccountDisplay.ValidateAlias("A\nB"));
            Assert.Throws<ArgumentException>(() => AiAccountDisplay.ValidateAlias("A\u202eB"));
            Assert.Throws<ArgumentException>(() => AiAccountDisplay.ValidateAlias(new string('x', 61)));
            Assert.Equal("Work", AiAccountDisplay.ValidateAlias(" Work "));
            Assert.Null(AiAccountDisplay.ValidateAlias(" "));
            Assert.DoesNotContain("fixture@example.test", JsonSerializer.Serialize(accounts));
        }

        [Fact]
        public async Task RejectedKey_IsNeverResent_ByManualRefresh_Test_OrUnchangedUpdate_OnlyANewKeyRetries()
        {
            var proxy = new FakeProxy();
            var (svc, _, _, advance) = NewService(proxy, "circuit");

            var (src, _, _, err, _) = await svc.CreateSourceAsync(new AiLimitsSourceUpsertRequest
            {
                Kind = AiLimitsSourceKinds.CliProxyPassive,
                BaseUrl = "http://127.0.0.1:8317",
                Credential = "wrong-key",
            });
            Assert.Null(err);
            Assert.Single(proxy.SentKeys);
            Assert.Equal(AiLimitsSourceStatuses.AuthRequired, src!.Status);
            Assert.Equal(AiLimitsErrorCodes.AuthFailed, src.ErrorCode);

            // Global and per-source manual refresh after the cooldown: the rejected key is not sent again.
            advance(TimeSpan.FromSeconds(30));
            await svc.ManualRefreshAsync(null);
            advance(TimeSpan.FromSeconds(30));
            var perSource = await svc.ManualRefreshAsync(src.Id);
            Assert.Equal(AiLimitsSourceStatuses.AuthRequired, perSource.Snapshot.Sources.Single().Status);

            // "Test connection" on the saved source with its stored key: blocked locally.
            var test = await svc.TestSourceAsync(new AiLimitsSourceTestRequest
            {
                SourceId = src.Id,
                Kind = AiLimitsSourceKinds.CliProxyPassive,
                BaseUrl = "http://127.0.0.1:8317",
            });
            Assert.False(test.Ok);
            Assert.Equal(AiLimitsErrorCodes.AuthFailed, test.ErrorCode);

            // Renaming without a new key keeps the circuit closed, even long after CPA's ban window.
            advance(TimeSpan.FromHours(2));
            await svc.UpdateSourceAsync(src.Id, new AiLimitsSourceUpsertRequest
            {
                Kind = AiLimitsSourceKinds.CliProxyPassive,
                Label = "Renamed",
                BaseUrl = "http://127.0.0.1:8317",
            });
            Assert.Single(proxy.SentKeys);

            // A corrected key is tried exactly once and reconnects.
            var (fixedSrc, _, _, fixErr, _, _) = await svc.UpdateSourceAsync(src.Id, new AiLimitsSourceUpsertRequest
            {
                Kind = AiLimitsSourceKinds.CliProxyPassive,
                Label = "Renamed",
                BaseUrl = "http://127.0.0.1:8317",
                Credential = "good-key",
            });
            Assert.Null(fixErr);
            Assert.Equal(new[] { "wrong-key", "good-key" }, proxy.SentKeys);
            Assert.NotEqual(AiLimitsSourceStatuses.AuthRequired, fixedSrc!.Status);
            Assert.Null(fixedSrc.ErrorCode);
        }

        [Fact]
        public async Task EndpointFailureBudget_StopsBeforeCliProxyApisFiveStrikeBan_EvenWithDifferentKeys()
        {
            var proxy = new FakeProxy();
            var adapter = new CliProxyPassiveAdapter(proxy);
            var now = new DateTimeOffset(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);
            var src = new AiLimitsSourceConfig { Id = "src_budget", Kind = AiLimitsSourceKinds.CliProxyPassive, BaseUrl = "http://127.0.0.1:8317" };

            for (var i = 0; i < 5; i++)
            {
                var r = await adapter.FetchAsync(src, "guess-" + i, now.AddSeconds(i), CancellationToken.None);
                Assert.True(r.AuthCircuitBreak);
            }
            Assert.Equal(CliProxyPassiveAdapter.MaxAuthFailuresPerEndpoint, proxy.SentKeys.Count);
            Assert.True(proxy.SentKeys.Count < 5);

            // Even the right key waits out the window; afterwards it goes through.
            var blocked = await adapter.FetchAsync(src, "good-key", now.AddMinutes(10), CancellationToken.None);
            Assert.False(blocked.Ok);
            Assert.Equal(2, proxy.SentKeys.Count);

            var ok = await adapter.FetchAsync(src, "good-key", now + CliProxyPassiveAdapter.AuthFailureWindow + TimeSpan.FromMinutes(1), CancellationToken.None);
            Assert.True(ok.Ok);
            Assert.Equal(3, proxy.SentKeys.Count);

            // A banned-IP 403 also counts and never falls back to the legacy v0 route.
            var banned = new FakeProxy { Override = () => new HttpResponseMessage(HttpStatusCode.Forbidden) };
            var r403 = await new CliProxyPassiveAdapter(banned).FetchAsync(src, "good-key", now, CancellationToken.None);
            Assert.True(r403.AuthCircuitBreak);
            Assert.Single(banned.SentKeys);
        }

        [Fact]
        public async Task RetryAfter_FromProxy_BlocksPerSourceManualRefresh_WithoutContactingIt()
        {
            var proxy = new FakeProxy();
            var (svc, _, _, advance) = NewService(proxy, "retry-after");
            var (src, _, _, _, _) = await svc.CreateSourceAsync(new AiLimitsSourceUpsertRequest
            {
                Kind = AiLimitsSourceKinds.CliProxyPassive,
                BaseUrl = "http://127.0.0.1:8317",
                Credential = "good-key",
            });
            Assert.Single(proxy.SentKeys);

            proxy.Override = () =>
            {
                var resp = new HttpResponseMessage((HttpStatusCode)429);
                resp.Headers.RetryAfter = new System.Net.Http.Headers.RetryConditionHeaderValue(TimeSpan.FromSeconds(600));
                return resp;
            };
            advance(TimeSpan.FromSeconds(30));
            var limited = await svc.ManualRefreshAsync(src!.Id);
            Assert.False(limited.CooldownBlocked);
            Assert.Equal(2, proxy.SentKeys.Count);
            Assert.Equal(AiLimitsSourceStatuses.RateLimited, limited.Snapshot.Sources.Single().Status);

            advance(TimeSpan.FromSeconds(30));
            var blocked = await svc.ManualRefreshAsync(src.Id);
            Assert.True(blocked.CooldownBlocked);
            Assert.True(blocked.RetryAfterSeconds > 400); // 600s ±15% jitter, minus 30s
            Assert.Equal(2, proxy.SentKeys.Count);
        }

        [Fact]
        public void CliProxy_UnknownCaptureTime_IsStale_AndEpochLeakIsDiscarded_NotShownAs100()
        {
            var now = new DateTimeOffset(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);
            // CLIProxyAPI v8 credentials entry (PII fields present on purpose; they must not leak).
            var json = """
            {
              "observed_at": "2026-11-23T12:00:00Z",
              "files": [
                {
                  "auth_index": "a1", "provider": "claude", "email": "person@example.com",
                  "name": "claude-person@example.com.json", "path": "C:/Users/x/.cli-proxy-api/claude-person.json",
                  "id_token": { "email": "person@example.com" }, "status": "active",
                  "quota": { "signals": {
                    "Anthropic-Ratelimit-Unified-5h-Utilization": "0.42",
                    "Anthropic-Ratelimit-Unified-7d-Utilization": "1738425600"
                  } }
                }
              ]
            }
            """;
            var acct = Assert.Single(CliProxyPassiveAdapter.ParseCredentialsPayload("src_x", json, now));
            var five = acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour);
            Assert.Equal(42.0, five.UsedPercent);
            Assert.Equal(AiLimitsWindowStatuses.Stale, five.Status); // no quota.observed_at
            var weekly = acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Weekly);
            Assert.Null(weekly.UsedPercent);
            Assert.Equal(AiLimitsWindowStatuses.Unavailable, weekly.Status);

            var dto = JsonSerializer.Serialize(acct);
            Assert.DoesNotContain("person@example.com", dto);
            Assert.DoesNotContain("cli-proxy-api", dto);
            Assert.StartsWith("acct_", acct.Id);
            Assert.Equal("Claude #1", acct.Alias);
        }

        [Fact]
        public void UrlValidator_KeepsOnlyProxyBase_WhenAFullManagementUrlIsPasted()
        {
            var r = AiLimitsUrlValidator.ValidateSourceUrl("http://127.0.0.1:8317/v8/management/credentials?x=1", allowNonLoopback: false);
            Assert.True(r.Ok);
            Assert.Equal("http://127.0.0.1:8317/", r.NormalizedUri!.ToString());
            Assert.False(AiLimitsUrlValidator.ValidateSourceUrl("http://192.168.1.5:8317", allowNonLoopback: false).Ok);
            Assert.True(AiLimitsUrlValidator.ValidateSourceUrl("http://192.168.1.5:8317", allowNonLoopback: true).IsNonLoopbackHttp);
        }

        // Shape from `codex app-server generate-json-schema` (codex-cli 0.166.0): GetAccountRateLimitsResponse.
        private static string CodexRpcFixture(long reset5h, long resetWk) => $$"""
            {
              "accountId": "user-secret-account-id",
              "ordinaryUsageAllowed": true,
              "rateLimits": {
                "limitId": "codex", "limitName": null, "planType": "plus",
                "primary": { "usedPercent": 40, "windowDurationMins": 300, "resetsAt": {{reset5h}} },
                "secondary": { "usedPercent": 103, "windowDurationMins": 10080, "resetsAt": {{resetWk}} },
                "credits": { "hasCredits": true, "unlimited": false, "balance": "12.5" },
                "rateLimitReachedType": null
              },
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex", "planType": "plus",
                  "primary": { "usedPercent": 40, "windowDurationMins": 300, "resetsAt": {{reset5h}} },
                  "secondary": { "usedPercent": 103, "windowDurationMins": 10080, "resetsAt": {{resetWk}} }
                },
                "codex_bengalfox": {
                  "limitId": "codex_bengalfox", "limitName": "GPT-5.3-Codex-Spark",
                  "primary": { "usedPercent": 10, "windowDurationMins": 300, "resetsAt": {{reset5h}} },
                  "secondary": null
                }
              },
              "rateLimitResetCredits": { "availableCount": 1, "credits": null }
            }
            """;

        [Fact]
        public void CodexRpc_OneAccountPerHome_ExtraBucketsAreModelPoolWindows_NoIdsOrBalancesInvented()
        {
            var now = new DateTimeOffset(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);
            var src = new AiLimitsSourceConfig { Id = "src_codex", Kind = AiLimitsSourceKinds.CodexLocal, Label = "Work" };
            var accounts = CodexLocalAdapter.ParseAppServerResult(src, CodexRpcFixture(now.AddHours(2).ToUnixTimeSeconds(), now.AddDays(4).ToUnixTimeSeconds()), now);

            var acct = Assert.Single(accounts);
            Assert.Equal(CodexLocalAdapter.AccountIdFor(src), acct.Id);
            Assert.Equal("Plus", acct.Plan);
            Assert.True(acct.OrdinaryUsageAllowed);

            var main5h = acct.Windows.Single(w => w.Id == "five_hour");
            Assert.Equal(40.0, main5h.UsedPercent);
            Assert.Equal("all", main5h.ModelPool);
            var weekly = acct.Windows.Single(w => w.Id == "weekly");
            Assert.Equal(100.0, weekly.UsedPercent); // Codex used_percent can exceed 100; shown as fully used
            var spark = acct.Windows.Single(w => w.Id == "pool:codex_bengalfox:five_hour");
            Assert.Equal("GPT-5.3-Codex-Spark", spark.ModelPool);
            Assert.Equal(10.0, spark.UsedPercent);
            Assert.Null(spark.OrdinaryUsageAllowed);

            var credits = acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Credits);
            Assert.Null(credits.Limit);
            Assert.Null(credits.UsedPercent);

            Assert.Equal(acct.Windows.Count, acct.Windows.Select(w => w.Id).Distinct().Count());
            Assert.DoesNotContain("user-secret-account-id", JsonSerializer.Serialize(acct));
        }

        [Theory]
        [InlineData("plus", null, 10080, AiLimitsWindowStatuses.Unavailable)]    // primary missing: unknown, not "no cap"
        [InlineData("prolite", 10080, null, AiLimitsWindowStatuses.NotApplicable)] // Pro family, single weekly primary
        [InlineData("team", 10080, null, AiLimitsWindowStatuses.NotApplicable)]    // weekly-length primary, by duration
        public void CodexRpc_MissingFiveHour_IsOnlyNotApplicableWhenTheProtocolSaysSo(string plan, int? primaryMins, int? secondaryMins, string expected)
        {
            var now = new DateTimeOffset(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);
            string Win(int? mins) => mins is { } m ? $"{{\"usedPercent\":20,\"windowDurationMins\":{m}}}" : "null";
            var json = $"{{\"rateLimits\":{{\"limitId\":\"codex\",\"planType\":\"{plan}\",\"primary\":{Win(primaryMins)},\"secondary\":{Win(secondaryMins)}}}}}";
            var acct = Assert.Single(CodexLocalAdapter.ParseAppServerResult(new AiLimitsSourceConfig { Id = "s", Label = "x" }, json, now));
            Assert.Equal(expected, acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour).Status);
            Assert.Equal(20.0, acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Weekly).UsedPercent);
        }

        [Fact]
        public async Task CodexLogFallback_KeepsTheSameAccountId_SoTilesStayBound()
        {
            var now = new DateTimeOffset(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);
            var home = Path.Combine(_dir, "codex-home");
            var sessions = Path.Combine(home, "sessions", "2026", "11", "23");
            Directory.CreateDirectory(sessions);
            // Real Codex rollout `token_count` event line (snake_case, window_minutes).
            File.WriteAllText(Path.Combine(sessions, "rollout-test.jsonl"),
                "{\"timestamp\":\"" + now.AddMinutes(-3).ToString("O") + "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":null," +
                "\"rate_limits\":{\"primary\":{\"used_percent\":12.0,\"window_minutes\":300,\"resets_at\":" + now.AddHours(3).ToUnixTimeSeconds() + "}," +
                "\"secondary\":{\"used_percent\":33.0,\"window_minutes\":10080,\"resets_at\":" + now.AddDays(2).ToUnixTimeSeconds() + "}}}}\n");
            File.SetLastWriteTimeUtc(Path.Combine(sessions, "rollout-test.jsonl"), now.UtcDateTime.AddMinutes(-3));

            var src = new AiLimitsSourceConfig { Id = "src_codex_fb", Kind = AiLimitsSourceKinds.CodexLocal, Label = "Me", ConfigDir = home };
            var res = await new CodexLocalAdapter(new NoCodex()).FetchAsync(src, null, now, CancellationToken.None);
            var acct = Assert.Single(res.Accounts);
            Assert.Equal(CodexLocalAdapter.AccountIdFor(src), acct.Id);
            Assert.Equal(AiLimitsAccessModes.PassiveLocalFile, acct.SupportLevel);
            Assert.Equal(12.0, acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour).UsedPercent);
        }

        [Fact]
        public void ClaudeHook_ChainsExistingCommand_KeepsItsSettings_AndUninstallRestoresItExactly()
        {
            var store = new AiLimitsConfigStore(Path.Combine(_dir, "claude-local"));
            var adapter = new ClaudeStatusLineAdapter(store);
            var claudeDir = Path.Combine(_dir, "claude-config");
            Directory.CreateDirectory(claudeDir);
            var settingsPath = Path.Combine(claudeDir, "settings.json");
            const string original = """{"theme":"dark","statusLine":{"type":"command","command":"bash ~/.claude/my-line.sh","padding":2},"hooks":{"Stop":[]}}""";
            File.WriteAllText(settingsPath, original);
            var src = new AiLimitsSourceConfig { Id = "src_cl", Kind = AiLimitsSourceKinds.ClaudeStatusLine, ConfigDir = claudeDir };

            var guide = adapter.InstallHook(src);
            Assert.True(guide.IsInstalled);
            Assert.Null(guide.ErrorCode);

            var installed = JsonNode.Parse(File.ReadAllText(settingsPath))!.AsObject();
            var cmd = installed["statusLine"]!["command"]!.GetValue<string>();
            Assert.Contains("deckos-claude-statusline-src_cl", cmd);
            Assert.EndsWith("| bash ~/.claude/my-line.sh", cmd);
            Assert.DoesNotContain("\\", cmd); // forward slashes only (Git Bash on Windows)
            Assert.Equal(2, installed["statusLine"]!["padding"]!.GetValue<int>());
            Assert.Equal("dark", installed["theme"]!.GetValue<string>());
            Assert.NotNull(installed["hooks"]);

            // Re-installing does not wrap the wrapper.
            adapter.InstallHook(src);
            var again = JsonNode.Parse(File.ReadAllText(settingsPath))!["statusLine"]!["command"]!.GetValue<string>();
            Assert.Equal(cmd, again);

            adapter.UninstallHook(src);
            var restored = JsonNode.Parse(File.ReadAllText(settingsPath))!;
            Assert.True(JsonNode.DeepEquals(JsonNode.Parse(original), restored));
        }

        [Fact]
        public void ClaudeHook_RefusesToRewriteSettingsItCannotParse()
        {
            var store = new AiLimitsConfigStore(Path.Combine(_dir, "claude-bad"));
            var adapter = new ClaudeStatusLineAdapter(store);
            var claudeDir = Path.Combine(_dir, "claude-bad-config");
            Directory.CreateDirectory(claudeDir);
            var settingsPath = Path.Combine(claudeDir, "settings.json");
            const string withComments = "{\n  // my settings\n  \"statusLine\": {\"type\":\"command\",\"command\":\"echo hi\"},\n}\n";
            File.WriteAllText(settingsPath, withComments);

            var guide = adapter.InstallHook(new AiLimitsSourceConfig { Id = "src_bad", Kind = AiLimitsSourceKinds.ClaudeStatusLine, ConfigDir = claudeDir });
            Assert.Equal(AiLimitsErrorCodes.InternalError, guide.ErrorCode);
            Assert.False(string.IsNullOrEmpty(guide.Message));
            Assert.False(guide.IsInstalled);
            Assert.Equal(withComments, File.ReadAllText(settingsPath));
            Assert.Empty(Directory.GetFiles(claudeDir, "settings.json.deckos-backup-*"));
        }

        // Claude Code statusLine stdin as documented (code.claude.com/docs/en/statusline): includes
        // workspace paths and session ids that must never be stored.
        private static string StatusLineInput(string? rateLimits, double apiMs) =>
            "{\"hook_event_name\":\"Status\",\"session_id\":\"sess-private-123\",\"transcript_path\":\"C:/Users/me/.claude/projects/x/sess.jsonl\"," +
            "\"cwd\":\"C:/Users/me/secret-project\",\"model\":{\"id\":\"claude-opus-5-5\",\"display_name\":\"Opus\"}," +
            "\"workspace\":{\"current_dir\":\"C:/Users/me/secret-project\",\"project_dir\":\"C:/Users/me/secret-project\"},\"version\":\"2.1.300\"," +
            "\"cost\":{\"total_cost_usd\":0.01,\"total_duration_ms\":45000,\"total_api_duration_ms\":" + apiMs.ToString(System.Globalization.CultureInfo.InvariantCulture) + "}" +
            (rateLimits != null ? ",\"rate_limits\":" + rateLimits : "") + "}";

        [Fact]
        public void ClaudeIngest_SessionStartKeepsLastReading_ApiSessionWithoutLimitsIsATombstone()
        {
            var store = new AiLimitsConfigStore(Path.Combine(_dir, "ingest"));
            var adapter = new ClaudeStatusLineAdapter(store);
            var src = new AiLimitsSourceConfig { Id = "src_ing", Kind = AiLimitsSourceKinds.ClaudeStatusLine };
            var now = new DateTimeOffset(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);
            var reset = now.AddHours(2).ToUnixTimeSeconds();

            var path = adapter.IngestSanitizedPayload(src, StatusLineInput("{\"five_hour\":{\"used_percentage\":37,\"resets_at\":" + reset + "},\"seven_day\":{\"used_percentage\":12.5,\"resets_at\":" + reset + "}}", 1200), now);
            var stored = File.ReadAllText(path);
            Assert.DoesNotContain("secret-project", stored);
            Assert.DoesNotContain("sess-private-123", stored);
            Assert.Contains("\"used_percentage\":37", stored);

            // New session, no API response yet: Claude Code omits rate_limits — keep the reading.
            adapter.IngestSanitizedPayload(src, StatusLineInput(null, 0), now.AddMinutes(5));
            Assert.Equal(stored, File.ReadAllText(path));

            // Session that already called the API and still has no rate_limits (API key / plan change): clear.
            adapter.IngestSanitizedPayload(src, StatusLineInput(null, 900), now.AddMinutes(6));
            var acct = ClaudeStatusLineAdapter.ParseSnapshot(src, File.ReadAllText(path), now, now.AddMinutes(6));
            Assert.All(acct.Windows, w => Assert.Null(w.UsedPercent));
        }

        [Fact]
        public async Task ClaudeWrapperScript_RealPowerShellRun_PassesInputThrough_AndStoresOnlyRateLimits()
        {
            if (!OperatingSystem.IsWindows()) return; // the POSIX variant is the sh/python3 script

            var store = new AiLimitsConfigStore(Path.Combine(_dir, "ps1"));
            var adapter = new ClaudeStatusLineAdapter(store);
            var claudeDir = Path.Combine(_dir, "ps1-claude");
            Directory.CreateDirectory(claudeDir);
            var src = new AiLimitsSourceConfig { Id = "src_ps1", Kind = AiLimitsSourceKinds.ClaudeStatusLine, ConfigDir = claudeDir };
            adapter.InstallHook(src);
            var script = Path.Combine(store.ScriptsDir, "deckos-claude-statusline-src_ps1.ps1");
            Assert.True(File.Exists(script));
            var snapshot = adapter.ResolveSnapshotPath(src);

            async Task<string> Run(string input)
            {
                var psi = new ProcessStartInfo("powershell.exe")
                {
                    RedirectStandardInput = true,
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    StandardInputEncoding = new UTF8Encoding(false),
                    StandardOutputEncoding = Encoding.UTF8,
                };
                foreach (var a in new[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script, "-PassThru" }) psi.ArgumentList.Add(a);
                using var p = Process.Start(psi)!;
                await p.StandardInput.WriteAsync(input);
                p.StandardInput.Close();
                var outText = await p.StandardOutput.ReadToEndAsync();
                using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(60));
                await p.WaitForExitAsync(cts.Token);
                return outText;
            }

            var withLimits = StatusLineInput("{\"five_hour\":{\"used_percentage\":61,\"resets_at\":1795000000},\"seven_day\":{\"used_percentage\":20,\"resets_at\":1795400000}}", 1500);
            Assert.Equal(withLimits, await Run(withLimits));
            var stored = File.ReadAllText(snapshot);
            Assert.DoesNotContain("secret-project", stored);
            Assert.DoesNotContain("sess-private", stored);
            var acct = ClaudeStatusLineAdapter.ParseSnapshot(src, stored, DateTimeOffset.UtcNow, DateTimeOffset.UtcNow);
            Assert.Equal(61.0, acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour).UsedPercent);

            await Run(StatusLineInput(null, 0)); // session start: snapshot untouched
            Assert.Equal(stored, File.ReadAllText(snapshot));
        }

        [Fact]
        public void ConfigStore_KeepsAnUnreadableConfigAside_InsteadOfLosingIt()
        {
            var store = new AiLimitsConfigStore(Path.Combine(_dir, "corrupt"));
            Directory.CreateDirectory(store.BaseDir);
            File.WriteAllText(store.ConfigPath, "{ not json");

            var doc = store.LoadConfig();
            Assert.Empty(doc.Sources);
            Assert.Single(Directory.GetFiles(store.BaseDir, "ai-limits.json.corrupt-*"));
        }

        [Fact]
        public void Normalizer_InvalidPercentIsUnavailable_AndWindowIdsStayUnique()
        {
            var now = DateTimeOffset.UtcNow;
            var bad = AiLimitsNormalizer.BuildPercentWindow("five_hour", AiLimitsWindowKinds.FiveHour, "5h", 300, 250, null, now, now);
            Assert.Null(bad.UsedPercent);
            Assert.Equal(AiLimitsWindowStatuses.Unavailable, bad.Status);
            Assert.Equal(100.0, AiLimitsNormalizer.BuildPercentWindow("w", AiLimitsWindowKinds.Weekly, "W", 10080, 100.6, null, now, now).UsedPercent);

            var ordered = AiLimitsNormalizer.OrderWindows(new[]
            {
                AiLimitsNormalizer.BuildPercentWindow("weekly", AiLimitsWindowKinds.Weekly, "W", 10080, 10, null, now, now),
                AiLimitsNormalizer.BuildPercentWindow("weekly", AiLimitsWindowKinds.Weekly, "W", 10080, 20, null, now, now),
            });
            Assert.Equal(new[] { "weekly", "weekly_2" }, ordered.Select(w => w.Id));
        }
    }
}
