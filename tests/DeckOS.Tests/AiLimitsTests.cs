using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Auth;
using DeckOS.Models;
using DeckOS.Services;
using DeckOS.Services.AiLimits;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace DeckOS.Tests
{
    public class AiLimitsAdapterTests : IDisposable
    {
        private readonly string _tempDir = Path.Combine(Path.GetTempPath(), "deckos-ailimits-" + Guid.NewGuid().ToString("N"));

        public AiLimitsAdapterTests() => Directory.CreateDirectory(_tempDir);

        public void Dispose()
        {
            try { Directory.Delete(_tempDir, recursive: true); } catch { }
        }

        private sealed class StubHttpHandler : HttpMessageHandler
        {
            public Func<HttpRequestMessage, HttpResponseMessage> Handler { get; set; } =
                _ => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{}") };
            public List<Uri?> RequestedUris { get; } = new();
            public int CallCount => RequestedUris.Count;

            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                RequestedUris.Add(request.RequestUri);
                return Task.FromResult(Handler(request));
            }
        }

        private sealed class FakeCodexRunner : ICodexAppServerRunner
        {
            public CodexRpcCallResult NextResult { get; set; }
            public int Calls { get; private set; }
            public string? LastCodexHome { get; private set; }

            public Task<CodexRpcCallResult> ReadRateLimitsAsync(string? codexHome, CancellationToken ct)
            {
                Calls++;
                LastCodexHome = codexHome;
                return Task.FromResult(NextResult);
            }
        }

        private sealed class FakeEnvDetector : IAiLimitsEnvironmentDetector
        {
            public AiLimitsDetectedEnvironmentDto Value { get; set; } = new()
            {
                CliProxyReachable = true,
                CliProxySuggestedUrl = "http://127.0.0.1:8317",
                CodexCliAvailable = true,
                CodexDefaultHomeExists = true,
                ClaudeCliAvailable = true,
                ClaudeConfigDirExists = true,
                ClaudeStatusLineConfigured = false,
                GeminiDirExists = true,
            };

            public Task<AiLimitsDetectedEnvironmentDto> DetectAsync(CancellationToken ct) => Task.FromResult(Value);
        }

        [Fact]
        public async Task CliProxyPassive_ParsesRealV8Signals_RedactsPii_AndKeepsEmptyUnavailable()
        {
            var now = new DateTimeOffset(2026, 11, 23, 6, 30, 0, TimeSpan.Zero);
            var reset5h = now.AddHours(2).ToUnixTimeSeconds();
            var reset7d = now.AddDays(4).ToUnixTimeSeconds();
            var pastReset = now.AddMinutes(-10).ToUnixTimeSeconds();

            var fixture = $$"""
            {
              "observed_at": "2026-11-23T06:29:00Z",
              "files": [
                {
                  "id": "secret-raw-id-1",
                  "auth_index": "auth_idx_claude_primary",
                  "provider": "claude",
                  "type": "claude",
                  "email": "private-user@example.com",
                  "id_token": "eyJhbGciOiJSUzI1NiJ9.SECRET_TOKEN_PAYLOAD",
                  "name": "claude-private-user@example.com.json",
                  "path": "C:/Users/kavin/secret-auth.json",
                  "status": "active",
                  "disabled": false,
                  "unavailable": false,
                  "quota_blocked": false,
                  "quota": {
                    "observed_at": "2026-11-23T06:25:00Z",
                    "signals": {
                      "Anthropic-Ratelimit-Unified-5h-Utilization": "0.42",
                      "Anthropic-Ratelimit-Unified-5h-Reset": "{{reset5h}}",
                      "Anthropic-Ratelimit-Unified-5h-Status": "allowed_warning",
                      "Anthropic-Ratelimit-Unified-7d-Utilization": "0.61",
                      "Anthropic-Ratelimit-Unified-7d-Reset": "{{reset7d}}",
                      "Anthropic-Ratelimit-Unified-7d-Status": "allowed",
                      "Anthropic-Ratelimit-Unified-Status": "allowed_warning"
                    }
                  }
                },
                {
                  "id": "secret-raw-id-2",
                  "auth_index": "auth_idx_codex_plus",
                  "provider": "codex",
                  "email": "second-user@example.com",
                  "status": "active",
                  "disabled": false,
                  "unavailable": false,
                  "quota": {
                    "observed_at": "2026-11-23T06:20:00Z",
                    "signals": {
                      "X-Codex-Plan-Type": "plus",
                      "X-Codex-Primary-Used-Percent": "35",
                      "X-Codex-Primary-Window-Minutes": "300",
                      "X-Codex-Primary-Reset-At": "{{pastReset}}",
                      "X-Codex-Secondary-Used-Percent": "22",
                      "X-Codex-Secondary-Window-Minutes": "10080",
                      "X-Codex-Secondary-Reset-At": "{{reset7d}}"
                    }
                  }
                },
                {
                  "id": "secret-raw-id-3",
                  "auth_index": "auth_idx_antigravity",
                  "provider": "antigravity",
                  "email": "ag-user@example.com",
                  "status": "active",
                  "disabled": false,
                  "unavailable": false,
                  "quota": { "signals": {} }
                },
                {
                  "id": "secret-raw-id-4",
                  "auth_index": "auth_idx_claude_disabled",
                  "provider": "claude",
                  "status": "disabled",
                  "disabled": true,
                  "quota": { "signals": {} }
                }
              ]
            }
            """;

            var handler = new StubHttpHandler
            {
                Handler = req =>
                {
                    Assert.Equal("/v8/management/credentials", req.RequestUri!.AbsolutePath);
                    Assert.Equal("Bearer super-secret-mgmt-key", req.Headers.Authorization?.ToString());
                    return new HttpResponseMessage(HttpStatusCode.OK)
                    {
                        Content = new StringContent(fixture, Encoding.UTF8, "application/json"),
                    };
                }
            };

            var adapter = new CliProxyPassiveAdapter(handler);
            var src = new AiLimitsSourceConfig
            {
                Id = "src_cpa1",
                Kind = AiLimitsSourceKinds.CliProxyPassive,
                BaseUrl = "http://127.0.0.1:8317",
            };

            var result = await adapter.FetchAsync(src, "super-secret-mgmt-key", now, CancellationToken.None);
            Assert.True(result.Ok);
            Assert.Equal("v8", result.DetectedApiVersion);
            Assert.Equal(4, result.Accounts.Count);

            // Verify strict PII & secret redaction across entire serialized DTO output.
            var serialized = JsonSerializer.Serialize(result.Accounts);
            Assert.DoesNotContain("private-user@example.com", serialized);
            Assert.DoesNotContain("second-user@example.com", serialized);
            Assert.DoesNotContain("ag-user@example.com", serialized);
            Assert.DoesNotContain("SECRET_TOKEN_PAYLOAD", serialized);
            Assert.DoesNotContain("secret-auth.json", serialized);
            Assert.DoesNotContain("auth_idx_claude_primary", serialized);
            Assert.DoesNotContain("super-secret-mgmt-key", serialized);

            // Claude #1: 0.42 -> 42.0%, remaining 58.0%; 0.61 -> 61.0%, remaining 39.0%.
            var claude1 = result.Accounts[0];
            Assert.Equal("Claude #1", claude1.Alias);
            Assert.Equal(AiLimitsQuotaStatuses.Ok, claude1.QuotaStatus);
            var c5 = claude1.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour);
            Assert.Equal(42.0, c5.UsedPercent);
            Assert.Equal(58.0, c5.RemainingPercent);
            Assert.Equal(AiLimitsWindowStatuses.Available, c5.Status);
            var c7 = claude1.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Weekly);
            Assert.Equal(61.0, c7.UsedPercent);
            Assert.Equal(39.0, c7.RemainingPercent);

            // Codex #1: pastReset MUST NOT auto-zero to 0%! Must stay 35% marked stale!
            var codex1 = result.Accounts[1];
            Assert.Equal("Plus", codex1.Plan);
            var x5 = codex1.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour);
            Assert.Equal(35.0, x5.UsedPercent);
            Assert.Equal(AiLimitsWindowStatuses.Stale, x5.Status);

            // Antigravity #1: empty signals -> NEVER 0%, honestly unavailable!
            var ag = result.Accounts[2];
            Assert.Equal(AiLimitsProviders.Antigravity, ag.Provider);
            Assert.Equal(AiLimitsQuotaStatuses.Unavailable, ag.QuotaStatus);
            Assert.All(ag.Windows, w =>
            {
                Assert.Equal(AiLimitsWindowStatuses.Unavailable, w.Status);
                Assert.Null(w.UsedPercent);
                Assert.Null(w.RemainingPercent);
            });

            // Disabled Claude #2 -> disabled connection status, no fabricated 0%
            var claude2 = result.Accounts[3];
            Assert.Equal(AiLimitsConnectionStatuses.Disabled, claude2.ConnectionStatus);
            Assert.False(claude2.Enabled);
        }

        [Fact]
        public async Task CliProxyPassive_Handles401_429RetryAfter_Redirects_AndV0Fallback()
        {
            var now = new DateTimeOffset(2026, 11, 23, 7, 0, 0, TimeSpan.Zero);
            var src = new AiLimitsSourceConfig
            {
                Id = "src_cpa2",
                Kind = AiLimitsSourceKinds.CliProxyPassive,
                BaseUrl = "http://127.0.0.1:8317",
            };

            // 401 -> circuit break
            var h401 = new StubHttpHandler { Handler = _ => new HttpResponseMessage(HttpStatusCode.Unauthorized) };
            var r401 = await new CliProxyPassiveAdapter(h401).FetchAsync(src, "bad-key", now, CancellationToken.None);
            Assert.False(r401.Ok);
            Assert.True(r401.AuthCircuitBreak);
            Assert.Equal(AiLimitsSourceStatuses.AuthRequired, r401.Status);

            // 429 with Retry-After
            var h429 = new StubHttpHandler
            {
                Handler = _ =>
                {
                    var m = new HttpResponseMessage((HttpStatusCode)429);
                    m.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromSeconds(95));
                    return m;
                }
            };
            var r429 = await new CliProxyPassiveAdapter(h429).FetchAsync(src, "key", now, CancellationToken.None);
            Assert.False(r429.Ok);
            Assert.Equal(AiLimitsSourceStatuses.RateLimited, r429.Status);
            Assert.Equal(TimeSpan.FromSeconds(95), r429.RetryAfter);

            // 302 redirect -> blocked so secret is never forwarded
            var h302 = new StubHttpHandler
            {
                Handler = _ =>
                {
                    var m = new HttpResponseMessage(HttpStatusCode.Found);
                    m.Headers.Location = new Uri("https://evil.example/steal");
                    return m;
                }
            };
            var r302 = await new CliProxyPassiveAdapter(h302).FetchAsync(src, "key", now, CancellationToken.None);
            Assert.False(r302.Ok);
            Assert.Equal(AiLimitsErrorCodes.RedirectBlocked, r302.ErrorCode);

            // v8 404 -> falls back cleanly to /v0/management/auth-files
            var hV0 = new StubHttpHandler
            {
                Handler = req => req.RequestUri!.AbsolutePath == "/v8/management/credentials"
                    ? new HttpResponseMessage(HttpStatusCode.NotFound)
                    : new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"files":[]}""") }
            };
            var rV0 = await new CliProxyPassiveAdapter(hV0).FetchAsync(src, "key", now, CancellationToken.None);
            Assert.True(rV0.Ok);
            Assert.Equal("v0", rV0.DetectedApiVersion);
            Assert.Equal(new[] { "/v8/management/credentials", "/v0/management/auth-files" }, hV0.RequestedUris.Select(u => u!.AbsolutePath));
        }

        [Fact]
        public void UrlValidator_EnforcesLoopbackByDefault_AndRejectsUserinfo()
        {
            Assert.True(AiLimitsUrlValidator.ValidateSourceUrl("http://127.0.0.1:8317", allowNonLoopback: false).Ok);
            Assert.True(AiLimitsUrlValidator.ValidateSourceUrl("http://localhost:8317/sub?secret=1", allowNonLoopback: false).NormalizedUri!.ToString() == "http://localhost:8317/sub");
            Assert.Equal(AiLimitsErrorCodes.NonLoopbackBlocked, AiLimitsUrlValidator.ValidateSourceUrl("http://192.168.1.20:8317", allowNonLoopback: false).ErrorCode);
            Assert.True(AiLimitsUrlValidator.ValidateSourceUrl("https://192.168.1.20:8317", allowNonLoopback: true).Ok);
            Assert.Equal(AiLimitsErrorCodes.InvalidUrl, AiLimitsUrlValidator.ValidateSourceUrl("http://user:pass@127.0.0.1:8317", allowNonLoopback: false).ErrorCode);
            Assert.Equal(AiLimitsErrorCodes.InvalidUrl, AiLimitsUrlValidator.ValidateSourceUrl("ftp://127.0.0.1:8317", allowNonLoopback: false).ErrorCode);
        }

        [Fact]
        public async Task CodexLocal_ParsesProWeeklyOnly_OrdinaryUsageAllowedFalse_AndFallsBackToJsonl()
        {
            var now = new DateTimeOffset(2026, 11, 23, 8, 0, 0, TimeSpan.Zero);
            var resetWk = now.AddDays(3).ToUnixTimeSeconds();
            var rpcJson = $$"""
            {
              "ordinaryUsageAllowed": false,
              "accountId": "raw-openai-account-uuid-1234",
              "rateLimitsByLimitId": {
                "codex": {
                  "limitId": "codex",
                  "planType": "pro",
                  "primary": null,
                  "secondary": { "usedPercent": 88, "windowDurationMins": 10080, "resetsAt": {{resetWk}} }
                }
              }
            }
            """;

            var runner = new FakeCodexRunner
            {
                NextResult = new CodexRpcCallResult(true, false, false, rpcJson, null, null),
            };
            var adapter = new CodexLocalAdapter(runner);
            var src = new AiLimitsSourceConfig
            {
                Id = "src_codex1",
                Kind = AiLimitsSourceKinds.CodexLocal,
                Label = "Work Pro",
                ConfigDir = _tempDir,
            };

            var res = await adapter.FetchAsync(src, null, now, CancellationToken.None);
            Assert.True(res.Ok);
            Assert.Equal("codex-app-server", res.DetectedApiVersion);
            var acct = Assert.Single(res.Accounts);
            Assert.Equal("Pro", acct.Plan);
            Assert.Equal(false, acct.OrdinaryUsageAllowed);
            Assert.Equal(AiLimitsQuotaStatuses.RateLimited, acct.QuotaStatus);
            Assert.DoesNotContain("raw-openai-account-uuid-1234", JsonSerializer.Serialize(acct));

            // Pro plan: 5h is honestly not_applicable, weekly is rate_limited because ordinaryUsageAllowed=false
            var w5 = acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour);
            Assert.Equal(AiLimitsWindowStatuses.NotApplicable, w5.Status);
            Assert.Null(w5.UsedPercent);
            var w7 = acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Weekly);
            Assert.Equal(88.0, w7.UsedPercent);
            Assert.Equal(AiLimitsWindowStatuses.RateLimited, w7.Status);

            // Now test fallback to passive JSONL when CLI is missing
            var sessionsDir = Path.Combine(_tempDir, "sessions");
            Directory.CreateDirectory(sessionsDir);
            var logReset = now.AddHours(3).ToUnixTimeSeconds();
            File.WriteAllText(Path.Combine(sessionsDir, "rollout.jsonl"),
                "{\"timestamp\":\"" + now.AddMinutes(-2).ToString("O") + "\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\","
                + "\"rate_limits\":{\"primary\":{\"used_percent\":19.5,\"window_minutes\":300,\"resets_at\":" + logReset + "},"
                + "\"secondary\":{\"used_percent\":41.0,\"window_minutes\":10080,\"resets_at\":" + resetWk + "}}}}\n");

            runner.NextResult = new CodexRpcCallResult(false, true, false, null, AiLimitsErrorCodes.CliNotFound, "missing");
            var fallbackRes = await adapter.FetchAsync(src, null, now, CancellationToken.None);
            Assert.True(fallbackRes.Ok);
            Assert.Equal("codex-session-jsonl", fallbackRes.DetectedApiVersion);
            var fbAcct = Assert.Single(fallbackRes.Accounts);
            Assert.Equal(AiLimitsAccessModes.PassiveLocalFile, fbAcct.SupportLevel);
            Assert.Equal(19.5, fbAcct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour).UsedPercent);
            Assert.Equal(41.0, fbAcct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Weekly).UsedPercent);
        }

        [Fact]
        public async Task ClaudeStatusLine_IngestRedactsPii_AndHookInstallPreservesExistingCommand()
        {
            var store = new AiLimitsConfigStore(Path.Combine(_tempDir, "deckos-local"));
            var adapter = new ClaudeStatusLineAdapter(store);
            var claudeDir = Path.Combine(_tempDir, "claude-home");
            Directory.CreateDirectory(claudeDir);
            var settingsPath = Path.Combine(claudeDir, "settings.json");

            // Pre-existing user statusLine command MUST be preserved!
            File.WriteAllText(settingsPath, """{"theme":"dark","statusLine":{"type":"command","command":"echo my-custom-footer"}}""");

            var src = new AiLimitsSourceConfig
            {
                Id = "src_claude1",
                Kind = AiLimitsSourceKinds.ClaudeStatusLine,
                Label = "Personal",
                ConfigDir = claudeDir,
            };

            var beforeGuide = adapter.GetSetupGuide(src, isLocalRequest: true);
            Assert.False(beforeGuide.IsInstalled);
            Assert.True(beforeGuide.HasExistingUserHook);

            var installed = adapter.InstallHook(src);
            Assert.True(installed.IsInstalled);
            Assert.False(installed.HasExistingUserHook);

            // Verify backup was created and settings.json still has "theme": "dark"
            Assert.NotEmpty(Directory.GetFiles(claudeDir, "settings.json.deckos-backup-*"));
            var settingsAfter = File.ReadAllText(settingsPath);
            Assert.Contains("\"theme\": \"dark\"", settingsAfter);
            if (OperatingSystem.IsWindows())
            {
                // Official Claude Code Windows guidance: forward slashes in statusLine command!
                Assert.DoesNotContain("\\\\", installed.CommandPreview ?? "");
            }

            // Test passive ingest: strips workspace/transcript/session PII completely!
            var now = new DateTimeOffset(2026, 11, 23, 9, 0, 0, TimeSpan.Zero);
            var rawPayload = $$"""
            {
              "session_id": "sess_secret_123",
              "transcript_path": "C:/Users/kavin/private/transcript.jsonl",
              "cwd": "C:/Users/kavin/secret-repo",
              "rate_limits": {
                "five_hour": { "used_percentage": 23.5, "resets_at": {{now.AddHours(3).ToUnixTimeSeconds()}} },
                "seven_day": { "used_percentage": 55.0, "resets_at": {{now.AddDays(5).ToUnixTimeSeconds()}} }
              }
            }
            """;

            var snapPath = adapter.IngestSanitizedPayload(src, rawPayload, now);
            var written = File.ReadAllText(snapPath);
            Assert.DoesNotContain("sess_secret_123", written);
            Assert.DoesNotContain("transcript.jsonl", written);
            Assert.DoesNotContain("secret-repo", written);

            var fetchRes = await adapter.FetchAsync(src, null, now, CancellationToken.None);
            Assert.True(fetchRes.Ok);
            var acct = Assert.Single(fetchRes.Accounts);
            Assert.Equal(23.5, acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour).UsedPercent);
            Assert.Equal(76.5, acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour).RemainingPercent);
            Assert.Equal(55.0, acct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Weekly).UsedPercent);

            // Uninstall MUST restore original user statusLine command verbatim!
            var uninstalled = adapter.UninstallHook(src);
            Assert.False(uninstalled.IsInstalled);
            Assert.True(uninstalled.HasExistingUserHook);
            Assert.Equal("echo my-custom-footer", ClaudeStatusLineAdapter.ReadExistingStatusLineCommand(settingsPath));
        }

        [Fact]
        public async Task GeminiOtel_AndManualDashboard_RemainHonestWithoutFakePercentages()
        {
            var now = new DateTimeOffset(2026, 11, 23, 10, 0, 0, TimeSpan.Zero);
            var otelPath = Path.Combine(_tempDir, "telemetry.log");
            File.WriteAllText(otelPath,
                "{\"timestamp\":\"" + now.AddMinutes(-30).ToString("O") + "\",\"name\":\"gemini_cli.api.request\"}\n" +
                "{\"timestamp\":\"" + now.AddMinutes(-5).ToString("O") + "\",\"name\":\"gemini_cli.api.request\"}\n" +
                "{\"timestamp\":\"" + now.AddDays(-2).ToString("O") + "\",\"name\":\"gemini_cli.api.request\"}\n");

            var geminiRes = await new GeminiOtelAdapter().FetchAsync(new AiLimitsSourceConfig
            {
                Id = "src_gem1",
                Kind = AiLimitsSourceKinds.GeminiLocalOtel,
                Label = "Personal",
                SnapshotFile = otelPath,
                DailyLimitHint = 1500,
            }, null, now, CancellationToken.None);

            Assert.True(geminiRes.Ok);
            var gAcct = Assert.Single(geminiRes.Accounts);
            Assert.Equal(AiLimitsCoverageScopes.LocalDeviceActivityOnly, gAcct.CoverageScope);
            Assert.Equal(AiLimitsWindowStatuses.NotApplicable, gAcct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour).Status);
            var daily = gAcct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Daily);
            Assert.Equal(2.0, daily.Used);
            Assert.Equal(1500.0, daily.Limit);
            Assert.Null(daily.UsedPercent);
            Assert.Null(daily.RemainingPercent);

            var manualRes = await new ManualDashboardAdapter().FetchAsync(new AiLimitsSourceConfig
            {
                Id = "src_man1",
                Kind = AiLimitsSourceKinds.ManualDashboard,
                Label = "Personal",
                Provider = "antigravity",
                PlanLabel = "AI Pro",
            }, null, now, CancellationToken.None);

            Assert.True(manualRes.Ok);
            var mAcct = Assert.Single(manualRes.Accounts);
            Assert.Equal(AiLimitsQuotaStatuses.ManualOnly, mAcct.QuotaStatus);
            Assert.StartsWith("https://", mAcct.DashboardUrl);
            Assert.All(mAcct.Windows, w => Assert.Null(w.UsedPercent));
        }

        [Fact]
        public async Task Service_EnforcesManualCooldown_SecretIsolation_And401CircuitBreaker()
        {
            var now = new DateTimeOffset(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);
            var store = new AiLimitsConfigStore(Path.Combine(_tempDir, "svc-local"));
            var httpCalls = 0;
            var statusToReturn = HttpStatusCode.OK;
            var handler = new StubHttpHandler
            {
                Handler = _ =>
                {
                    httpCalls++;
                    return new HttpResponseMessage(statusToReturn)
                    {
                        Content = new StringContent("""{"files":[]}""", Encoding.UTF8, "application/json"),
                    };
                }
            };

            var cpa = new CliProxyPassiveAdapter(handler);
            var claude = new ClaudeStatusLineAdapter(store);
            var svc = new AiLimitsService(
                NullLogger<AiLimitsService>.Instance,
                store,
                new IAiLimitsSourceAdapter[] { cpa, claude, new CodexLocalAdapter(new FakeCodexRunner()), new GeminiOtelAdapter(), new ManualDashboardAdapter() },
                claude,
                new FakeEnvDetector(),
                hub: null,
                clock: () => now,
                connectedClientsCount: () => 1);

            var (src, _, _, errCode, _) = await svc.CreateSourceAsync(new AiLimitsSourceUpsertRequest
            {
                Kind = AiLimitsSourceKinds.CliProxyPassive,
                Label = "Local CPA",
                BaseUrl = "http://127.0.0.1:8317",
                Credential = "top-secret-key-999",
            });
            Assert.Null(errCode);
            Assert.NotNull(src);
            Assert.True(src!.HasCredential);
            Assert.Equal(1, httpCalls);

            // Secret must NEVER appear in ai-limits.json or snapshot JSON
            var configDisk = File.ReadAllText(store.ConfigPath);
            Assert.DoesNotContain("top-secret-key-999", configDisk);
            var snapJson = JsonSerializer.Serialize(await svc.GetSnapshotAsync());
            Assert.DoesNotContain("top-secret-key-999", snapJson);

            // Manual refresh #1 succeeds; immediate #2 is blocked by cooldown (15s)
            var r1 = await svc.ManualRefreshAsync(null);
            Assert.False(r1.CooldownBlocked);
            Assert.Equal(2, httpCalls);

            var r2 = await svc.ManualRefreshAsync(null);
            Assert.True(r2.CooldownBlocked);
            Assert.True(r2.RetryAfterSeconds >= 14);
            Assert.Equal(2, httpCalls);

            // Advance past cooldown and simulate 401 -> circuit breaker stops auto retries
            now = now.AddSeconds(20);
            statusToReturn = HttpStatusCode.Unauthorized;
            var r3 = await svc.ManualRefreshAsync(null);
            Assert.False(r3.CooldownBlocked);
            Assert.Equal(AiLimitsSourceStatuses.AuthRequired, r3.Snapshot.Sources.Single().Status);

            // Updating source without sending credential preserves existing secret
            var (updated, _, _, updErr, _, notFound) = await svc.UpdateSourceAsync(src.Id, new AiLimitsSourceUpsertRequest
            {
                Kind = AiLimitsSourceKinds.CliProxyPassive,
                Label = "Renamed CPA",
                BaseUrl = "http://127.0.0.1:8317",
                Credential = "", // omit -> preserve!
            });
            Assert.False(notFound);
            Assert.Null(updErr);
            Assert.True(updated!.HasCredential);
            Assert.Equal("Renamed CPA", updated.Label);
        }

        [Fact]
        public async Task CliProxyPassive_GuardsAgainstIpBan_ParsesDevinRemainingInvert_ArrayCooldowns_AndModelPools()
        {
            var now = new DateTimeOffset(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);
            var src = new AiLimitsSourceConfig
            {
                Id = "src_cpa_audit",
                Kind = AiLimitsSourceKinds.CliProxyPassive,
                BaseUrl = "http://127.0.0.1:8317",
            };

            // 1. Repeated rejected management key MUST be blocked locally after 1st 401/403 (avoiding CPA's 5-strike 30m IP ban).
            var badHandler = new StubHttpHandler { Handler = _ => new HttpResponseMessage(HttpStatusCode.Unauthorized) };
            var guardAdapter = new CliProxyPassiveAdapter(badHandler);
            var firstBad = await guardAdapter.FetchAsync(src, "wrong-key", now, CancellationToken.None);
            var secondBad = await guardAdapter.FetchAsync(src, "wrong-key", now.AddSeconds(5), CancellationToken.None);
            Assert.True(firstBad.AuthCircuitBreak);
            Assert.True(secondBad.AuthCircuitBreak);
            Assert.Equal(1, badHandler.CallCount); // 2nd call did NOT hit CLIProxyAPI!

            // 2. Devin remaining-% inversion, []CooldownView array schema, and Codex additional model-pool headers
            var resetIso = now.AddHours(6).ToString("O");
            var resetUnix = now.AddHours(4).ToUnixTimeSeconds();
            var fixture = $$"""
            {
              "files": [
                {
                  "id": "devin-1",
                  "auth_index": "idx_devin",
                  "provider": "devin",
                  "status": "active",
                  "cooldowns": [
                    { "scope": "credential", "reason": "rate_limit", "retry_at": "{{resetIso}}", "remaining_seconds": 300, "http_status": 429 }
                  ],
                  "quota": {
                    "observed_at": "{{now.AddMinutes(-2).ToString("O")}}",
                    "signals": {
                      "plan": "team",
                      "daily_quota_remaining_percent": "85%",
                      "weekly_quota_remaining_percent": "60%",
                      "daily_quota_reset_at": "{{resetIso}}",
                      "weekly_quota_reset_at": "{{now.AddDays(3).ToString("O")}}"
                    }
                  }
                },
                {
                  "id": "codex-pool-1",
                  "auth_index": "idx_codex_pool",
                  "provider": "codex",
                  "status": "active",
                  "quota": {
                    "observed_at": "{{now.AddMinutes(-1).ToString("O")}}",
                    "signals": {
                      "X-Codex-Plan-Type": "plus",
                      "X-Codex-Primary-Used-Percent": "25",
                      "X-Codex-Primary-Window-Minutes": "300",
                      "X-Codex-Primary-Reset-At": "{{resetUnix}}",
                      "X-Codex-Bengalfox-Limit-Name": "GPT-5.3-Codex-Spark",
                      "X-Codex-Bengalfox-Primary-Used-Percent": "48",
                      "X-Codex-Bengalfox-Primary-Window-Minutes": "300",
                      "X-Codex-Bengalfox-Primary-Reset-At": "{{resetUnix}}"
                    }
                  }
                }
              ]
            }
            """;

            var okHandler = new StubHttpHandler
            {
                Handler = _ => new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent(fixture, Encoding.UTF8, "application/json"),
                }
            };
            var res = await new CliProxyPassiveAdapter(okHandler).FetchAsync(src, "valid-key", now, CancellationToken.None);
            Assert.True(res.Ok);
            Assert.Equal(2, res.Accounts.Count);

            var devin = res.Accounts[0];
            Assert.Equal(AiLimitsProviders.Devin, devin.Provider);
            Assert.Equal("team", devin.Plan);
            Assert.NotNull(devin.CooldownUntil);
            var devinDaily = devin.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Daily);
            Assert.Equal(15.0, devinDaily.UsedPercent);
            Assert.Equal(85.0, devinDaily.RemainingPercent);
            var devinWeekly = devin.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Weekly);
            Assert.Equal(40.0, devinWeekly.UsedPercent);
            Assert.Equal(60.0, devinWeekly.RemainingPercent);

            var codex = res.Accounts[1];
            var sparkWin = codex.Windows.Single(w => w.ModelPool == "GPT-5.3-Codex-Spark");
            Assert.Equal(48.0, sparkWin.UsedPercent);
            Assert.Equal(52.0, sparkWin.RemainingPercent);
        }

        [Fact]
        public void UpstreamMitPatterns_CodexProPrimaryReslotSnakeCase_AndClaudeBug52326AndTombstone()
        {
            var now = new DateTimeOffset(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);
            var resetWk = now.AddDays(5).ToUnixTimeSeconds();

            // CodexBar MIT pattern: snake_case decode + Pro plan putting single 10080-min weekly window in `primary` with `secondary: null`.
            var snakeProJson = $$"""
            {
              "ordinary_usage_allowed": true,
              "rate_limits": {
                "limit_id": "codex",
                "plan_type": "pro",
                "primary": { "used_percent": 31, "window_duration_mins": 10080, "resets_at": {{resetWk}} },
                "secondary": null
              }
            }
            """;
            var codexSrc = new AiLimitsSourceConfig { Id = "src_c_pro", Kind = AiLimitsSourceKinds.CodexLocal, Label = "Pro" };
            var codexAcct = Assert.Single(CodexLocalAdapter.ParseAppServerResult(codexSrc, snakeProJson, now));
            Assert.Equal(AiLimitsWindowStatuses.NotApplicable, codexAcct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour).Status);
            Assert.Equal(31.0, codexAcct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Weekly).UsedPercent);

            // Claude-Code-Usage-Monitor MIT pattern: bug #52326 drops epoch-timestamp leak (>101) instead of clamping to 100%,
            // clamps 100.4 to 100.0, and respects plan-downgrade tombstone (`rate_limits: null`).
            Assert.Equal(100.0, ClaudeStatusLineAdapter.CleanSubscriptionPercent(100.4));
            Assert.Null(ClaudeStatusLineAdapter.CleanSubscriptionPercent(1738425600));
            Assert.Null(ClaudeStatusLineAdapter.CleanSubscriptionPercent(-5));

            var claudeSrc = new AiLimitsSourceConfig { Id = "src_cl_guard", Kind = AiLimitsSourceKinds.ClaudeStatusLine, Label = "Personal" };
            var bugPayload = "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":1738425600,\"resets_at\":" + resetWk + "},\"seven_day\":{\"used_percentage\":44.5,\"resets_at\":" + resetWk + "}}}";
            var bugAcct = ClaudeStatusLineAdapter.ParseSnapshot(claudeSrc, bugPayload, now, now);
            Assert.Null(bugAcct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.FiveHour).UsedPercent);
            Assert.Equal(44.5, bugAcct.Windows.Single(w => w.Kind == AiLimitsWindowKinds.Weekly).UsedPercent);

            var tombstoneAcct = ClaudeStatusLineAdapter.ParseSnapshot(claudeSrc, """{"observedAt":"2026-11-23T12:00:00Z","rate_limits":null}""", now, now);
            Assert.Equal(AiLimitsQuotaStatuses.AwaitingData, tombstoneAcct.QuotaStatus);
            Assert.All(tombstoneAcct.Windows, w => Assert.Null(w.UsedPercent));
        }
    }

    /// <summary>
    /// End-to-end ASP.NET Core integration tests for /api/ai-limits using isolated TestServer DI
    /// (never starts real adb or touches developer profiles/secrets).
    /// </summary>
    public class AiLimitsEndpointTests : IClassFixture<WebApplicationFactory<DeckOS.Program>>, IDisposable
    {
        private readonly string _tempDir = Path.Combine(Path.GetTempPath(), "deckos-ailimits-http-" + Guid.NewGuid().ToString("N"));
        private readonly WebApplicationFactory<DeckOS.Program> _factory;
        private DateTimeOffset _now = new(2026, 11, 23, 12, 0, 0, TimeSpan.Zero);

        private sealed class StaticEnvDetector : IAiLimitsEnvironmentDetector
        {
            public Task<AiLimitsDetectedEnvironmentDto> DetectAsync(CancellationToken ct) =>
                Task.FromResult(new AiLimitsDetectedEnvironmentDto
                {
                    CliProxyReachable = false,
                    CodexCliAvailable = true,
                    CodexDefaultHomeExists = false,
                    ClaudeCliAvailable = true,
                    ClaudeConfigDirExists = false,
                });
        }

        private sealed class NoOpCodexRunner : ICodexAppServerRunner
        {
            public Task<CodexRpcCallResult> ReadRateLimitsAsync(string? codexHome, CancellationToken ct) =>
                Task.FromResult(new CodexRpcCallResult(false, true, false, null, AiLimitsErrorCodes.CliNotFound, "not installed"));
        }

        public AiLimitsEndpointTests(WebApplicationFactory<DeckOS.Program> factory)
        {
            Directory.CreateDirectory(_tempDir);
            _factory = factory.WithWebHostBuilder(b => b.ConfigureTestServices(services =>
            {
            // Replace UsbBridge with a no-op findAdb stub so TestServer never launches real adb.
            services.RemoveAll<DeckOS.Lib.UsbBridge>();
            services.AddSingleton(_ => new DeckOS.Lib.UsbBridge(
                NullLogger<DeckOS.Lib.UsbBridge>.Instance,
                () => null,
                TimeSpan.FromHours(1),
                TimeSpan.FromSeconds(1)));

            services.RemoveAll<AiLimitsConfigStore>();
                services.RemoveAll<IAiLimitsEnvironmentDetector>();
                services.RemoveAll<ICodexAppServerRunner>();

                services.AddSingleton(_ => new AiLimitsConfigStore(_tempDir));
                services.AddSingleton<IAiLimitsEnvironmentDetector, StaticEnvDetector>();
                services.AddSingleton<ICodexAppServerRunner, NoOpCodexRunner>();
                // CI may take longer than the cooldown to finish a request. Control service
                // time so the HTTP assertions cover the cooldown independently of runner speed.
                services.AddSingleton<Func<DateTimeOffset>>(_ => () => _now);
            }));
        }

        public void Dispose()
        {
            try { Directory.Delete(_tempDir, recursive: true); } catch { }
        }

        private HttpClient Client(bool withKey = true)
        {
            var c = _factory.CreateClient();
            if (withKey) c.DefaultRequestHeaders.Add("X-API-KEY", ApiKeyProvider.GetKey());
            return c;
        }

        [Fact]
        public async Task Endpoints_RequireAuth_AndSupportFullCrudAndRefreshCooldown()
        {
            // Unauthenticated -> 401
            var unauth = await Client(withKey: false).GetAsync("/api/ai-limits");
            Assert.Equal(HttpStatusCode.Unauthorized, unauth.StatusCode);

            var client = Client();
            var getResp = await client.GetAsync("/api/ai-limits");
            Assert.Equal(HttpStatusCode.OK, getResp.StatusCode);
            using var initialDoc = JsonDocument.Parse(await getResp.Content.ReadAsStringAsync());
            Assert.Equal(1, initialDoc.RootElement.GetProperty("schemaVersion").GetInt32());
            Assert.True(initialDoc.RootElement.GetProperty("capabilities").GetProperty("supportedSourceKinds").GetArrayLength() >= 5);

            // Create manual_dashboard source
            var createBody = new StringContent(
                """{"kind":"manual_dashboard","label":"Antigravity Main","provider":"antigravity","planLabel":"AI Pro"}""",
                Encoding.UTF8, "application/json");
            var createResp = await client.PostAsync("/api/ai-limits/sources", createBody);
            Assert.Equal(HttpStatusCode.Created, createResp.StatusCode);
            using var createDoc = JsonDocument.Parse(await createResp.Content.ReadAsStringAsync());
            var sourceId = createDoc.RootElement.GetProperty("source").GetProperty("id").GetString()!;
            var accountId = createDoc.RootElement.GetProperty("accounts")[0].GetProperty("id").GetString()!;
            Assert.StartsWith("src_", sourceId);
            Assert.StartsWith("acct_", accountId);

            // Rename account alias via PUT (also verifies PATCH/PUT compatibility)
            var renameResp = await client.PutAsync($"/api/ai-limits/accounts/{accountId}",
                new StringContent("""{"alias":"Personal AG","enabled":true}""", Encoding.UTF8, "application/json"));
            Assert.Equal(HttpStatusCode.OK, renameResp.StatusCode);
            using var renameDoc = JsonDocument.Parse(await renameResp.Content.ReadAsStringAsync());
            Assert.Equal("Personal AG", renameDoc.RootElement.GetProperty("account").GetProperty("alias").GetString());

            // Manual refresh #1 -> 200; immediate #2 -> 429 cooldown_active with Retry-After
            var ref1 = await client.PostAsync("/api/ai-limits/refresh", new StringContent("{}", Encoding.UTF8, "application/json"));
            Assert.Equal(HttpStatusCode.OK, ref1.StatusCode);
            var ref2 = await client.PostAsync("/api/ai-limits/refresh", new StringContent("{}", Encoding.UTF8, "application/json"));
            Assert.Equal((HttpStatusCode)429, ref2.StatusCode);
            Assert.True(ref2.Headers.Contains("Retry-After"));
            using var ref2Doc = JsonDocument.Parse(await ref2.Content.ReadAsStringAsync());
            Assert.Equal(AiLimitsErrorCodes.CooldownActive, ref2Doc.RootElement.GetProperty("errorCode").GetString());

            // Once the cooldown expires, refresh is allowed again.
            _now = _now.Add(ref2.Headers.RetryAfter!.Delta!.Value);
            var ref3 = await client.PostAsync("/api/ai-limits/refresh", new StringContent("{}", Encoding.UTF8, "application/json"));
            Assert.Equal(HttpStatusCode.OK, ref3.StatusCode);

            // Delete source locally -> 200
            var delResp = await client.DeleteAsync($"/api/ai-limits/sources/{sourceId}");
            Assert.Equal(HttpStatusCode.OK, delResp.StatusCode);
        }
    }
}
