using System;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Auth;
using DeckOS.Lib;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Xunit;

namespace DeckOS.Tests;

public sealed class SecurePairingTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "deckos-pairing-" + Guid.NewGuid().ToString("N"));
    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }
    public SecurePairingTests() => Directory.CreateDirectory(_dir);
    public void Dispose() => Directory.Delete(_dir, true);
    [Fact]
    public void TokensExpireAreOneUseAndNeverPersist()
    {
        var clock = new Clock();
        var path = Path.Combine(_dir, "devices");
        var pairing = new SecurePairing(path, clock);
        var expired = pairing.IssueToken();
        clock.Now = clock.Now.AddMinutes(3);
        Assert.Null(pairing.Exchange(expired, "test"));
        var fresh = pairing.IssueToken();
        var device = pairing.Exchange(fresh, "test")!.Value;
        Assert.Null(pairing.Exchange(fresh, "test"));
        Assert.Equal(device.Id, pairing.Validate(device.Credential));
        var raw = SecretFile.ReadAllText(path);
        Assert.DoesNotContain(fresh, raw);
        Assert.DoesNotContain(device.Credential, raw);
        Assert.Equal(device.Id, new SecurePairing(path, clock).Validate(device.Credential));
        var cancellation = pairing.Revocation(device.Id);
        Assert.True(pairing.Revoke(device.Id));
        Assert.True(cancellation.IsCancellationRequested);
        Assert.Null(pairing.Validate(device.Credential));
        Assert.Null(new SecurePairing(path, clock).Validate(device.Credential));
    }
    [Fact]
    public void ConcurrentReplayCreatesOnlyOneDevice()
    {
        var pairing = new SecurePairing(Path.Combine(_dir, "devices"));
        var token = pairing.IssueToken();
        var results = Enumerable.Range(0, 12).AsParallel().Select(_ => pairing.Exchange(token, "test")).ToArray();
        Assert.Single(results.Where(r => r != null));
    }
    [Theory]
    [InlineData("http", "localhost", "127.0.0.1", null, null, true)]
    [InlineData("http", "localhost", "192.168.1.4", null, null, false)]
    [InlineData("http", "evil.example", "127.0.0.1", null, null, false)]
    [InlineData("http", "localhost", "127.0.0.1", "http://evil.example", null, false)]
    [InlineData("http", "localhost", "127.0.0.1", null, "127.0.0.1", false)]
    [InlineData("https", "pc", "192.168.1.4", null, null, true)]
    [InlineData("https", "pc", "192.168.1.4", "http://pc", null, false)]
    public void BoundaryRejectsCleartextRemoteRebindingOriginsAndProxyHeaders(string scheme, string host, string ip, string? origin, string? forwarded, bool allowed)
    {
        var ctx = new DefaultHttpContext();
        ctx.Request.Scheme = scheme; ctx.Request.Host = new HostString(host);
        ctx.Connection.RemoteIpAddress = IPAddress.Parse(ip);
        if (origin != null) ctx.Request.Headers.Origin = origin;
        if (forwarded != null) ctx.Request.Headers["X-Forwarded-For"] = forwarded;
        Assert.Equal(allowed, TransportBoundary.Allowed(ctx));
        if (scheme == "https") Assert.False(TransportBoundary.IsLocalAdmin(ctx));
    }
}

[Collection("PairingPort")]
public sealed class SecureKestrelTests
{
    [Theory]
    [InlineData("http://0.0.0.0:4787")]
    [InlineData("http://+:4787")]
    public async Task ExplicitLanHttpConfigurationFailsClosed(string urls)
    {
        await Assert.ThrowsAsync<InvalidOperationException>(async () => {
            using var host = Program.CreateHostBuilder(new[] { "--urls", urls, "--EnableDiscovery", "false" }).Build();
            await host.StartAsync();
        });
    }
    [Fact]
    public async Task RealTlsExchangeReplayAuthRevocationAndLocalAdminBoundary()
    {
        var previous = PairingInfo.Port;
        var previousLocal = PairingInfo.LocalPort;
        using var host = Program.CreateHostBuilder(new[] { "--urls", "http://127.0.0.1:0;https://127.0.0.1:0", "--EnableDiscovery", "false" }).Build();
        try
        {
            await host.StartAsync();
            var addresses = host.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses;
            var secure = addresses.Single(a => a.StartsWith("https:"));
            var local = addresses.Single(a => a.StartsWith("http:"));
            using var handler = new HttpClientHandler { UseProxy = false,
                ServerCertificateCustomValidationCallback = (_, cert, _, _) => cert != null &&
                    Convert.ToHexString(SHA256.HashData(cert.RawData)).Equals(CompanionCertificate.Pin, StringComparison.OrdinalIgnoreCase) };
            using var client = new HttpClient(handler) { BaseAddress = new Uri(secure) };
            using var admin = new HttpClient(new HttpClientHandler { UseProxy = false }) { BaseAddress = new Uri(local) };
            var localKey = await admin.GetFromJsonAsync<JsonElement>("/api/pairing/local-key");
            admin.DefaultRequestHeaders.Add("X-API-KEY", localKey.GetProperty("key").GetString());
            var code = await admin.GetFromJsonAsync<JsonElement>("/api/pairing/qr");
            var query = Microsoft.AspNetCore.WebUtilities.QueryHelpers.ParseQuery(new Uri(code.GetProperty("code").GetString()!).Query);
            var token = query["token"].ToString();
            var paired = await client.PostAsJsonAsync("/api/pairing/exchange", new { token, name = "isolated-test" });
            Assert.Equal(HttpStatusCode.OK, paired.StatusCode);
            var payload = await paired.Content.ReadFromJsonAsync<JsonElement>();
            var id = payload.GetProperty("deviceId").GetString()!;
            var credential = payload.GetProperty("credential").GetString()!;
            Assert.Equal(HttpStatusCode.Gone, (await client.PostAsJsonAsync("/api/pairing/exchange", new { token })).StatusCode);
            client.DefaultRequestHeaders.Add("X-API-KEY", credential);
            Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/api/platform")).StatusCode);
            Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/pairing/devices")).StatusCode);
            Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/api/pairing/local-key")).StatusCode);
            using var legacy = new HttpClient(handler, false) { BaseAddress = new Uri(secure) };
            legacy.DefaultRequestHeaders.Add("X-API-KEY", ApiKeyProvider.GetKey());
            Assert.Equal(HttpStatusCode.Unauthorized, (await legacy.GetAsync("/api/platform")).StatusCode);
            using var ws = new ClientWebSocket();
            ws.Options.SetRequestHeader("X-API-KEY", credential);
            ws.Options.RemoteCertificateValidationCallback = (_, cert, _, _) => cert != null &&
                Convert.ToHexString(SHA256.HashData(cert.GetRawCertData())).Equals(CompanionCertificate.Pin, StringComparison.OrdinalIgnoreCase);
            await ws.ConnectAsync(new Uri(secure.Replace("https:", "wss:") + "/deckHub"), CancellationToken.None);
            await ws.SendAsync(Encoding.UTF8.GetBytes("{\"protocol\":\"json\",\"version\":1}\u001e"), WebSocketMessageType.Text, true, CancellationToken.None);
            var buffer = new byte[8192];
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await ws.ReceiveAsync(buffer, timeout.Token);
            Assert.Equal(HttpStatusCode.OK, (await admin.DeleteAsync("/api/pairing/devices/" + id)).StatusCode);
            Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/platform")).StatusCode);
            // Revocation terminates existing hub connections as well as future requests.
            try { while ((await ws.ReceiveAsync(buffer, timeout.Token)).MessageType != WebSocketMessageType.Close) { } }
            catch (WebSocketException) { }
            Assert.NotEqual(WebSocketState.Open, ws.State);
            using var rebinding = new HttpRequestMessage(HttpMethod.Get, "/api/pairing/local-key");
            rebinding.Headers.Host = "evil.example";
            Assert.Equal(HttpStatusCode.Forbidden, (await admin.SendAsync(rebinding)).StatusCode);
            using var crossOrigin = new HttpRequestMessage(HttpMethod.Get, "/api/pairing/local-key");
            crossOrigin.Headers.Add("Origin", "http://evil.example");
            Assert.Equal(HttpStatusCode.Forbidden, (await admin.SendAsync(crossOrigin)).StatusCode);
            using var proxy = new HttpRequestMessage(HttpMethod.Get, "/api/pairing/local-key");
            proxy.Headers.Add("X-Forwarded-For", "127.0.0.1");
            Assert.Equal(HttpStatusCode.Forbidden, (await admin.SendAsync(proxy)).StatusCode);
        }
        finally
        {
            await host.StopAsync();
            PairingInfo.SetPort(previous);
            PairingInfo.UseBoundAddresses(new[] { $"http://127.0.0.1:{previousLocal}" });
        }
    }
}
