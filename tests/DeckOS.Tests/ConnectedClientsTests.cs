using System;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using DeckOS.Auth;
using DeckOS.Services;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace DeckOS.Tests
{
    public class ConnectedClientsServiceTests
    {
        [Fact]
        public void EmptySnapshot_HasNoClients()
        {
            var svc = new ConnectedClientsService();
            Assert.Empty(svc.Snapshot().Clients);
        }

        [Fact]
        public void Register_SanitizesLabels_UsesEphemeralId_AndOrdersByRole()
        {
            var svc = new ConnectedClientsService();

            svc.Register("conn-cfg-secret", new ClientRegistration
            {
                Role = "configurator",
                Name = "Chrome",
                Platform = "web",
            }, isLoopback: true, isUsbForwarded: false);

            svc.Register("conn-web-secret", new ClientRegistration
            {
                Role = "web_deck",
                Name = "iPad\r\nSafari",
                Platform = "web",
            }, isLoopback: false, isUsbForwarded: false);

            svc.Register("conn-mob-secret", new ClientRegistration
            {
                Role = "mobile",
                Name = "  Nothing   Phone (2a)\t\0  ",
                Model = "AIN065",
                Platform = "android",
            }, isLoopback: true, isUsbForwarded: true);

            var snap = svc.Snapshot();
            Assert.Equal(3, snap.Clients.Count);

            // Ordering: mobile -> web_deck -> configurator
            Assert.Equal("mobile", snap.Clients[0].Role);
            Assert.Equal("Nothing Phone (2a)", snap.Clients[0].Name);
            Assert.Equal("AIN065", snap.Clients[0].Model);
            Assert.Equal("android", snap.Clients[0].Platform);
            Assert.Equal("usb", snap.Clients[0].Transport);
            Assert.True(snap.Clients[0].Connected);
            Assert.NotEqual("conn-mob-secret", snap.Clients[0].Id);
            Assert.Equal(8, snap.Clients[0].Id.Length);

            Assert.Equal("web_deck", snap.Clients[1].Role);
            Assert.Equal("iPadSafari", snap.Clients[1].Name);
            Assert.Equal("wifi", snap.Clients[1].Transport);

            Assert.Equal("configurator", snap.Clients[2].Role);
            Assert.Equal("local", snap.Clients[2].Transport);
        }

        [Fact]
        public void Register_FallsBackToModel_CapsLength_AndHonorsUnregister()
        {
            var svc = new ConnectedClientsService();
            var longModel = new string('X', 120);

            svc.Register("c1", new ClientRegistration
            {
                Role = "deck",
                Model = longModel,
                Platform = "ios",
                Transport = "wifi",
            }, isLoopback: false, isUsbForwarded: false);

            var client = Assert.Single(svc.Snapshot().Clients);
            Assert.Equal("mobile", client.Role);
            Assert.Equal(64, client.Name!.Length);
            Assert.Equal(64, client.Model!.Length);
            Assert.Equal("wifi", client.Transport);

            Assert.True(svc.Unregister("c1", out var after));
            Assert.Empty(after.Clients);
            Assert.False(svc.Unregister("c1", out _));
        }

        [Fact]
        public void Register_WithoutNameOrModel_KeepsNullHonestly()
        {
            var svc = new ConnectedClientsService();
            svc.Register("c2", new ClientRegistration
            {
                Role = "mobile",
                Platform = "android",
            }, isLoopback: false, isUsbForwarded: false);

            var client = Assert.Single(svc.Snapshot().Clients);
            Assert.Null(client.Name);
            Assert.Null(client.Model);
            Assert.Equal("wifi", client.Transport);
        }
    }

    public class ConnectedClientsEndpointTests : IClassFixture<WebApplicationFactory<DeckOS.Program>>
    {
        private readonly WebApplicationFactory<DeckOS.Program> _factory;

        public ConnectedClientsEndpointTests(WebApplicationFactory<DeckOS.Program> factory) => _factory = factory;

        private HttpClient Client(bool withKey = true)
        {
            var client = _factory.CreateClient(new WebApplicationFactoryClientOptions { BaseAddress = new System.Uri("https://localhost") });
            if (withKey) client.DefaultRequestHeaders.Add("X-API-KEY", TestEnvironment.DeviceCredential);
            return client;
        }

        [Fact]
        public async Task ClientsEndpoint_RequiresAuth_AndReturnsRegisteredClients()
        {
            Assert.Equal(HttpStatusCode.Unauthorized, (await Client(withKey: false).GetAsync("/api/system/clients")).StatusCode);

            var registry = _factory.Services.GetRequiredService<ConnectedClientsService>();
            registry.Register("test-conn-1", new ClientRegistration
            {
                Role = "mobile",
                Name = "Phone (2a)",
                Model = "AIN065",
                Platform = "android",
                Transport = "usb",
            }, isLoopback: true, isUsbForwarded: true);

            try
            {
                var json = await Client().GetStringAsync("/api/system/clients");
                using var doc = JsonDocument.Parse(json);
                var clients = doc.RootElement.GetProperty("clients").EnumerateArray().ToList();
                var phone = Assert.Single(clients, c => c.GetProperty("role").GetString() == "mobile");
                Assert.Equal("Phone (2a)", phone.GetProperty("name").GetString());
                Assert.Equal("AIN065", phone.GetProperty("model").GetString());
                Assert.Equal("android", phone.GetProperty("platform").GetString());
                Assert.Equal("usb", phone.GetProperty("transport").GetString());
                Assert.True(phone.GetProperty("connected").GetBoolean());
            }
            finally
            {
                registry.Unregister("test-conn-1", out _);
            }
        }
    }
}
