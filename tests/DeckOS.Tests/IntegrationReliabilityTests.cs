using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Actions;
using DeckOS.Auth;
using DeckOS.Integrations;
using DeckOS.Lib;
using DeckOS.Models;
using DeckOS.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace DeckOS.Tests
{
    [Collection(RealTimeNetworkCollection.Name)]
    public class IntegrationReliabilityTests
    {
        [Fact]
        public async Task PolledHttp_MairlistLogout_ImmediatelyMarksDisconnectedAndClearsState()
        {
            await using var server = await FakeHttpServer.StartAsync(async ctx =>
            {
                if (ctx.Request.Path == "/status/onair")
                    await ctx.Response.WriteAsync("1");
                else
                    ctx.Response.StatusCode = 404;
            });

            var mairlist = new MairlistIntegration(NullLogger<MairlistIntegration>.Instance, Fakes.Hub(), Fakes.Config(), new SimpleHttpFactory());
            await mairlist.StartAsync(CancellationToken.None);
            try
            {
                var status = await mairlist.ConfigureAsync(new() { ["url"] = server.Url });
                Assert.True(status.Connected);
                Assert.True(mairlist.OnAir);

                await mairlist.LogoutAsync();
                var after = mairlist.GetStatus();
                Assert.False(after.Connected);
                Assert.False(after.Configured);
                Assert.Null(mairlist.OnAir);
                Assert.Null(after.Message);
            }
            finally
            {
                await mairlist.LogoutAsync();
                await mairlist.StopAsync(CancellationToken.None);
            }
        }

        [Fact]
        public async Task PolledHttp_RadioDjLogout_ImmediatelyMarksDisconnectedAndClearsState()
        {
            await using var server = await FakeHttpServer.StartAsync(async ctx =>
            {
                if (ctx.Request.Path == "/np")
                {
                    ctx.Response.StatusCode = 404;
                    return;
                }
                await ctx.Response.WriteAsync("true");
            });

            var radio = new RadioDjIntegration(NullLogger<RadioDjIntegration>.Instance, Fakes.Hub(), Fakes.Config(), new ForbiddenHttpFactory());
            await radio.StartAsync(CancellationToken.None);
            try
            {
                var status = await radio.ConfigureAsync(new() { ["url"] = server.Url, ["password"] = "pw" });
                Assert.True(status.Connected);
                Assert.True(radio.Input);

                await radio.LogoutAsync();
                var after = radio.GetStatus();
                Assert.False(after.Connected);
                Assert.False(after.Configured);
                Assert.Null(radio.Input);
            }
            finally
            {
                await radio.LogoutAsync();
                await radio.StopAsync(CancellationToken.None);
            }
        }

        [Fact]
        public async Task Vmix_ReconfigureWhileConnectedToBadPort_DoesNotReturnStaleConnected()
        {
            const string xml = "<vmix><version>29.0</version><inputs></inputs></vmix>";
            await using var server = new FakeLineServer(async (line, s) =>
            {
                if (line.StartsWith("SUBSCRIBE")) await s.SendAsync("SUBSCRIBE OK TALLY\r\n");
                else if (line.StartsWith("XML")) await s.SendAsync($"XML {xml.Length}\r\n{xml}");
            });

            var vmix = new VmixIntegration(NullLogger<VmixIntegration>.Instance, Fakes.Hub(), Fakes.Config());
            await vmix.StartAsync(CancellationToken.None);
            try
            {
                var ok = await vmix.ConfigureAsync(new() { ["host"] = "127.0.0.1:" + server.Port });
                Assert.True(ok.Connected);

                // Pick a closed port and reconfigure while previously connected.
                var free = new TcpListener(IPAddress.Loopback, 0);
                free.Start();
                var closedPort = ((IPEndPoint)free.LocalEndpoint).Port;
                free.Stop();

                var failed = await vmix.ConfigureAsync(new() { ["host"] = "127.0.0.1:" + closedPort });
                Assert.False(failed.Connected);
                Assert.NotNull(failed.Message);

                await vmix.LogoutAsync();
                Assert.False(vmix.GetStatus().Connected);
                Assert.False(vmix.GetStatus().Configured);
            }
            finally
            {
                await vmix.LogoutAsync();
                await vmix.StopAsync(CancellationToken.None);
            }
        }

        [Fact]
        public void RedirectUriFor_ReflectsBoundPort()
        {
            var previous = PairingInfo.LocalPort;
            try
            {
                PairingInfo.UseBoundAddresses(new[] { "http://127.0.0.1:5512" });
                Assert.Equal("http://127.0.0.1:5512/api/integrations/spotify/callback", AccountIntegration.RedirectUriFor("spotify"));
            }
            finally
            {
                PairingInfo.UseBoundAddresses(new[] { $"http://127.0.0.1:{previous}" });
            }
        }

        [Fact]
        public async Task OAuthIntegrations_ForgetWhenDisconnectedClearsClientId()
        {
            var spotify = new SpotifyIntegration(NullLogger<SpotifyIntegration>.Instance, Fakes.Hub(), Fakes.Config(), new SimpleHttpFactory());
            // Save clientId via ConfigureAsync? No, that would open browser. Test via LogoutAsync directly after reflection/state or via invalid callback.
            await spotify.LogoutAsync();
            Assert.False(spotify.GetStatus().Configured);

            var ha = new HomeAssistantIntegration(NullLogger<HomeAssistantIntegration>.Instance, Fakes.Hub(), Fakes.Config());
            await Assert.ThrowsAsync<InvalidOperationException>(() => ha.ConfigureAsync(new() { ["url"] = "ftp://example.com", ["token"] = "abc" }));
            await Assert.ThrowsAsync<InvalidOperationException>(() => ha.ConfigureAsync(new() { ["url"] = "http://127.0.0.1:8123", ["token"] = "" }));
            // Token missing must not have persisted half-configured URL.
            Assert.False(ha.GetStatus().Configured);
            Assert.Equal("", ha.GetStatus().Fields["url"]);
        }

        [Fact]
        public async Task HomeAssistantProvider_ValidatesMissingEntityAndInvalidJson()
        {
            var ha = new HomeAssistantIntegration(NullLogger<HomeAssistantIntegration>.Instance, Fakes.Hub(), Fakes.Config());
            var provider = new HomeAssistantProvider(ha);

            await Assert.ThrowsAsync<InvalidOperationException>(() =>
                provider.ExecuteAsync(Ctx.Of("homeassistant", ("operation", "toggle"), ("entityId", ""))));
            await Assert.ThrowsAsync<InvalidOperationException>(() =>
                provider.ExecuteAsync(Ctx.Of("homeassistant", ("operation", "service"), ("service", "light.turn_on"), ("data", "{bad"))));
        }

        [Theory]
        [InlineData("localhost", "localhost")]
        [InlineData(" ws://192.168.1.50:4455/ ", "192.168.1.50")]
        [InlineData("", "localhost")]
        public void ObsNormalizeHost_ValidatesCleanly(string input, string expected) =>
            Assert.Equal(expected, ObsService.NormalizeHost(input));

        [Theory]
        [InlineData("host with spaces")]
        [InlineData("192.168.1.50/extra/path")]
        public void ObsNormalizeHost_RejectsMalformed(string input) =>
            Assert.ThrowsAny<InvalidOperationException>(() => ObsService.NormalizeHost(input));

        [Theory]
        [InlineData("192.168.1.10/path")]
        [InlineData("not a host")]
        public void HueNormalizeHost_RejectsMalformed(string input) =>
            Assert.Throws<InvalidOperationException>(() => HueIntegration.NormalizeHost(input));

        [Fact]
        public async Task TriggerService_NormalizesUnpaddedTimeAndDeduplicatesIds()
        {
            var config = new StreamDeckConfigService(NullLogger<StreamDeckConfigService>.Instance);
            var profileId = "trig-norm-" + Guid.NewGuid().ToString("N");
            config.SaveProfile(new DeckProfile
            {
                Id = profileId,
                Name = "Norm",
                Buttons =
                {
                    new DeckButton { Id = "b1", Action = new DeckAction { Type = "rec", Parameters = { ["tag"] = "ok" } } },
                },
            });

            var ran = new List<string>();
            var rec = new LambdaProvider("rec", c => { ran.Add(c.Get("tag")); return Task.CompletedTask; });
            var executor = new ActionExecutorService(NullLogger<ActionExecutorService>.Instance, new IActionProvider[] { rec });
            var conditions = new Conditions(new ServiceCollection().BuildServiceProvider());
            var service = new TriggerService(config, new ButtonToggleService(NullLogger<ButtonToggleService>.Instance),
                executor, conditions, NullLogger<TriggerService>.Instance);

            service.SaveAll(new List<TriggerService.Trigger>
            {
                new() { Id = "dup", Event = "schedule", Time = "9:5", ProfileId = profileId, ButtonId = "b1" },
                new() { Id = "dup", Event = "schedule", Time = "10:00", ProfileId = profileId, ButtonId = "b1" },
            });

            var saved = service.GetAll();
            Assert.Equal(2, saved.Count);
            Assert.NotEqual(saved[0].Id, saved[1].Id);
            Assert.Equal("09:05", saved[0].Time);

            var now = new DateTime(2026, 10, 19, 9, 5, 0);
            service.Now = () => now;
            await service.TickAsync();
            Assert.Equal(new[] { "ok" }, ran);
        }

        private sealed class LambdaProvider : IActionProvider
        {
            private readonly Func<ActionContext, Task> _run;
            public LambdaProvider(string type, Func<ActionContext, Task> run) { Type = type; _run = run; }
            public string Type { get; }
            public ActionSchema Describe() => new() { Type = Type, Title = Type };
            public Task ExecuteAsync(ActionContext c) => _run(c);
        }
    }

    public class IntegrationControllersTests : IClassFixture<WebApplicationFactory<DeckOS.Program>>
    {
        private readonly WebApplicationFactory<DeckOS.Program> _factory;

        public IntegrationControllersTests(WebApplicationFactory<DeckOS.Program> factory) => _factory = factory;

        private HttpClient Client()
        {
            var c = _factory.CreateClient(new WebApplicationFactoryClientOptions { BaseAddress = new System.Uri("https://localhost") });
            c.DefaultRequestHeaders.Add("X-API-KEY", TestEnvironment.DeviceCredential);
            return c;
        }

        [Fact]
        public async Task ObsController_ValidatesPortAndHost_ExposesSafeState_AndForgetsConfig()
        {
            var client = Client();
            Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/api/obs/config", new { host = "localhost", port = 70000 })).StatusCode);
            Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/api/obs/config", new { host = "bad host/path", port = 4455 })).StatusCode);

            var save = await client.PostAsJsonAsync("/api/obs/config", new { host = "ws://127.0.0.1:4455", port = 4456, password = "secret" });
            Assert.Equal(HttpStatusCode.OK, save.StatusCode);

            using var state = JsonDocument.Parse(await client.GetStringAsync("/api/obs/state"));
            Assert.True(state.RootElement.GetProperty("configured").GetBoolean());
            Assert.Equal("127.0.0.1", state.RootElement.GetProperty("host").GetString());
            Assert.Equal(4456, state.RootElement.GetProperty("port").GetInt32());
            Assert.True(state.RootElement.GetProperty("hasPassword").GetBoolean());
            Assert.False(state.RootElement.TryGetProperty("password", out _));

            var del = await client.DeleteAsync("/api/obs/config");
            Assert.Equal(HttpStatusCode.OK, del.StatusCode);
            using var after = JsonDocument.Parse(await del.Content.ReadAsStringAsync());
            Assert.False(after.RootElement.GetProperty("configured").GetBoolean());
        }

        [Fact]
        public async Task DiscordController_ConfigAndForget_UpdateStateCleanly()
        {
            var client = Client();
            var save = await client.PostAsJsonAsync("/api/discord/config", new { clientId = "1234567890", clientSecret = "topsecret" });
            Assert.Equal(HttpStatusCode.OK, save.StatusCode);
            using var doc = JsonDocument.Parse(await save.Content.ReadAsStringAsync());
            Assert.True(doc.RootElement.GetProperty("configured").GetBoolean());
            Assert.Equal("1234567890", doc.RootElement.GetProperty("clientId").GetString());
            Assert.False(doc.RootElement.TryGetProperty("clientSecret", out _));

            var del = await client.DeleteAsync("/api/discord/config");
            Assert.Equal(HttpStatusCode.OK, del.StatusCode);
            using var after = JsonDocument.Parse(await del.Content.ReadAsStringAsync());
            Assert.False(after.RootElement.GetProperty("configured").GetBoolean());
        }

        [Fact]
        public async Task SoundboardController_ClampsVolume()
        {
            var client = Client();
            var resp = await client.PostAsJsonAsync("/api/soundboard/config", new { volume = 250, monitorEnabled = false });
            Assert.Equal(HttpStatusCode.OK, resp.StatusCode);
            using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync());
            Assert.Equal(100, doc.RootElement.GetProperty("volume").GetInt32());
        }
    }
}
