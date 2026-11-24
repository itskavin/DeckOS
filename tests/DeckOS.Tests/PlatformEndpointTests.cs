using System;
using System.Collections.Generic;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using DeckOS.Auth;
using DeckOS.Platform;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace DeckOS.Tests
{
    /// <summary>Formato do /api/platform e do /api/apps (contrato com o configurador).</summary>
    public class PlatformEndpointTests : IClassFixture<WebApplicationFactory<DeckOS.Program>>
    {
        private static readonly byte[] Png = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };

        private sealed class FakeApps : IInstalledApps
        {
            public static readonly InstalledApp Notepad = new("0123456789abcdef", "Bloco de Notas", @"C:\Windows\notepad.exe");

            public IReadOnlyList<InstalledApp> List() => new[] { Notepad };
            public InstalledApp? Find(string id) => id == Notepad.Id ? Notepad : null;
            public Task<(byte[] Data, string ContentType)?> GetIconAsync(string id) =>
                Task.FromResult<(byte[], string)?>(id == Notepad.Id ? (Png, "image/png") : null);
        }

        private readonly WebApplicationFactory<DeckOS.Program> _factory;

        public PlatformEndpointTests(WebApplicationFactory<DeckOS.Program> factory) =>
            _factory = factory.WithWebHostBuilder(b => b.ConfigureTestServices(s => s.AddSingleton<IInstalledApps, FakeApps>()));

        private HttpClient Client(bool key = true)
        {
            var client = _factory.CreateClient(new WebApplicationFactoryClientOptions { BaseAddress = new System.Uri("https://localhost") });
            if (key) client.DefaultRequestHeaders.Add("X-API-KEY", TestEnvironment.DeviceCredential);
            return client;
        }

        [Fact]
        public async Task Apps_ListaComIdNomeCaminhoEIcone()
        {
            var json = await Client().GetStringAsync("/api/apps");
            using var doc = JsonDocument.Parse(json);
            var app = Assert.Single(doc.RootElement.EnumerateArray());
            Assert.Equal(new[] { "id", "name", "path", "iconUrl" }, app.EnumerateObject().Select(p => p.Name));
            Assert.Equal("0123456789abcdef", app.GetProperty("id").GetString());
            Assert.Equal("Bloco de Notas", app.GetProperty("name").GetString());
            Assert.Equal("/api/apps/0123456789abcdef/icon", app.GetProperty("iconUrl").GetString());
        }

        [Fact]
        public async Task Icone_PngOu404()
        {
            var client = Client();
            var ok = await client.GetAsync("/api/apps/0123456789abcdef/icon");
            Assert.Equal(HttpStatusCode.OK, ok.StatusCode);
            Assert.Equal("image/png", ok.Content.Headers.ContentType?.MediaType);
            Assert.Equal(Png, await ok.Content.ReadAsByteArrayAsync());
            Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/api/apps/ffff/icon")).StatusCode);
        }

        [Fact]
        public async Task Plataforma_SistemaECapacidades()
        {
            var json = await Client().GetStringAsync("/api/platform");
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            Assert.Contains(root.GetProperty("os").GetString(), new[] { "windows", "macos", "linux", "other" });
            foreach (var key in new[] { "osVersion", "arch", "machineName", "capabilities", "missing" })
                Assert.True(root.TryGetProperty(key, out _), key);
            var caps = root.GetProperty("capabilities").EnumerateArray().Select(c => c.GetString()).ToList();
            // TestEnvironment define DECKOS_MDNS=0, entao /api/platform nao deve anunciar discovery.mdns.
            Assert.Contains(Capabilities.DiscoveryUdp, caps);
            Assert.DoesNotContain(Capabilities.DiscoveryMdns, caps);
            if (Capabilities.WindowsBuild && OperatingSystem.IsWindows()) Assert.Contains(Capabilities.AudioMixer, caps);
            foreach (var m in root.GetProperty("missing").EnumerateArray())
            {
                Assert.False(string.IsNullOrEmpty(m.GetProperty("capability").GetString()));
                Assert.False(string.IsNullOrEmpty(m.GetProperty("package").GetString()));
            }
        }

        [Fact]
        public async Task Plataforma_DiscoveryDesativadoNaConfig_OmiteUdpEMdns()
        {
            using var factory = _factory.WithWebHostBuilder(b => b.ConfigureAppConfiguration((_, cfg) =>
                cfg.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["EnableDiscovery"] = "false",
                })));
            var client = factory.CreateClient(new WebApplicationFactoryClientOptions { BaseAddress = new System.Uri("https://localhost") });
            client.DefaultRequestHeaders.Add("X-API-KEY", TestEnvironment.DeviceCredential);

            var json = await client.GetStringAsync("/api/platform");
            using var doc = JsonDocument.Parse(json);
            var caps = doc.RootElement.GetProperty("capabilities").EnumerateArray().Select(c => c.GetString()).ToList();

            Assert.DoesNotContain(Capabilities.DiscoveryUdp, caps);
            Assert.DoesNotContain(Capabilities.DiscoveryMdns, caps);
        }

        [Fact]
        public async Task Plataforma_DiscoveryEMdnsAtivadosNaConfig_AnunciaAmbos()
        {
            using var factory = _factory.WithWebHostBuilder(b =>
            {
                b.ConfigureAppConfiguration((_, cfg) =>
                    cfg.AddInMemoryCollection(new Dictionary<string, string?>
                    {
                        ["EnableDiscovery"] = "true",
                        ["DECKOS_MDNS"] = "1",
                    }));
                b.ConfigureTestServices(s =>
                {
                    // Evita disputar a porta 5353 durante o teste mantendo DiscoveryAvailability ativo.
                    var mdns = s.FirstOrDefault(d => d.ImplementationType == typeof(DeckOS.Lib.MdnsAdvertiser));
                    if (mdns != null) s.Remove(mdns);
                });
            });
            var client = factory.CreateClient(new WebApplicationFactoryClientOptions { BaseAddress = new System.Uri("https://localhost") });
            client.DefaultRequestHeaders.Add("X-API-KEY", TestEnvironment.DeviceCredential);

            var json = await client.GetStringAsync("/api/platform");
            using var doc = JsonDocument.Parse(json);
            var caps = doc.RootElement.GetProperty("capabilities").EnumerateArray().Select(c => c.GetString()).ToList();

            Assert.Contains(Capabilities.DiscoveryUdp, caps);
            Assert.Contains(Capabilities.DiscoveryMdns, caps);
        }

        [Fact]
        public async Task SemChave_401()
        {
            Assert.Equal(HttpStatusCode.Unauthorized, (await Client(key: false).GetAsync("/api/apps")).StatusCode);
            Assert.Equal(HttpStatusCode.Unauthorized, (await Client(key: false).GetAsync("/api/platform")).StatusCode);
        }

        [Fact]
        public void AppDaStore_LevaOsArgumentos()
        {
            // Calculadora da Store: explorer.exe + shell:AppsFolder. Sem os argumentos na
            // resposta, o botao arrastado da biblioteca abria o Explorer.
            var calc = new InstalledApp("fedcba9876543210", "Calculadora", "explorer.exe")
            {
                Arguments = @"shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App",
            };
            var json = System.Text.Json.JsonSerializer.Serialize(DeckOS.Controllers.PlatformController.ToDto(calc),
                new System.Text.Json.JsonSerializerOptions(System.Text.Json.JsonSerializerDefaults.Web));
            using var doc = JsonDocument.Parse(json);
            Assert.Equal(calc.Arguments, doc.RootElement.GetProperty("arguments").GetString());
        }

        [Fact]
        public void LaunchApp_TemCampoAppId()
        {
            using var scope = _factory.Services.CreateScope();
            var executor = scope.ServiceProvider.GetRequiredService<DeckOS.Services.ActionExecutorService>();
            var schema = executor.Find("launch_app")!.Describe();
            Assert.Contains(schema.Fields, f => f.Key == "appId");
        }
    }

    /// <summary>A lista de apps da base: id estavel, sem nome repetido, em ordem.</summary>
    public class InstalledAppsBaseTests
    {
        private sealed class Fixed : InstalledAppsBase
        {
            protected override IEnumerable<InstalledApp> Scan() => new[]
            {
                new InstalledApp(MakeId("/b"), "Zeta", "/b"),
                new InstalledApp(MakeId("/a"), "alfa", "/a"),
                new InstalledApp(MakeId("/c"), "Alfa", "/c"),
                new InstalledApp(MakeId("/d"), " ", "/d"),
            };

            protected override Task<(byte[] Data, string ContentType)?> LoadIconAsync(InstalledApp app) =>
                Task.FromResult<(byte[], string)?>(null);
        }

        [Fact]
        public async Task ListaOrdenadaSemRepetidos_EIdHexSeguro()
        {
            var apps = new Fixed();
            Assert.Equal(new[] { "alfa", "Zeta" }, apps.List().Select(a => a.Name));
            Assert.Equal(InstalledAppsBase.MakeId("/A"), InstalledAppsBase.MakeId("/a"));
            Assert.Matches("^[0-9a-f]{16}$", InstalledAppsBase.MakeId("/a"));
            Assert.NotNull(apps.Find(InstalledAppsBase.MakeId("/b")));
            // Id que nao e hex nunca vira caminho de arquivo.
            Assert.Null(await apps.GetIconAsync("../../etc/passwd"));
        }
    }
}
