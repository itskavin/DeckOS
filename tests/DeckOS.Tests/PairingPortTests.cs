using System;
using System.IO;
using System.Linq;
using DeckOS.Lib;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Xunit;

namespace DeckOS.Tests
{
    /// <summary>Porta real de escuta no banner de console, QR e URIs de pareamento.</summary>
    [Collection("PairingPort")]
    public class PairingPortTests
    {
        [Theory]
        [InlineData("http://0.0.0.0:5123", 5123)]
        [InlineData("http://+:5200", 5200)]
        [InlineData("http://*:5300", 5300)]
        [InlineData("http://[::]:5400", 5400)]
        [InlineData("https://localhost:5001;http://localhost:5000", 5001)]
        [InlineData("https://localhost:5001", 5001)]
        [InlineData("http://127.0.0.1:0", null)]
        [InlineData("", null)]
        [InlineData("nao-e-url", null)]
        public void PortFromUrls_ExtraiPortaEsperada(string urls, int? expected)
        {
            Assert.Equal(expected, PairingInfo.PortFromUrls(urls));
        }

        [Fact]
        public async System.Threading.Tasks.Task HostComPortaAlternativa_AtualizaBannerEQrComPortaReal()
        {
            var previousPort = PairingInfo.Port;
            PairingInfo.SetPort(PairingInfo.DefaultPort);

            using var host = Program.CreateHostBuilder(new[]
            {
                "--urls", "http://127.0.0.1:0;https://127.0.0.1:0",
                "--EnableDiscovery", "false",
            }).Build();

            try
            {
                await host.StartAsync();

                var server = host.Services.GetRequiredService<IServer>();
                var addresses = server.Features.Get<IServerAddressesFeature>()?.Addresses;
                Assert.NotNull(addresses);
                var boundPort = PairingInfo.PortFromUrls(addresses!);
                Assert.NotNull(boundPort);
                Assert.NotEqual(PairingInfo.DefaultPort, boundPort!.Value);

                Assert.Equal(boundPort.Value, PairingInfo.Port);
                Assert.Equal($"http://localhost:{PairingInfo.LocalPort}/", ConsoleBanner.WebUrl);
                Assert.Contains(System.Uri.EscapeDataString($"https://{NetworkInfo.GetLanIp()}:{boundPort.Value}"), PairingInfo.BuildUri());
                Assert.Contains($":{boundPort.Value}/#pair=", PairingInfo.BuildBrowserUrl());

                using var sw = new StringWriter();
                ConsoleBanner.Print(sw);
                var banner = sw.ToString();
                Assert.Contains($"http://localhost:{PairingInfo.LocalPort}/", banner);
                Assert.Contains($":{boundPort.Value}/#pair=", banner);
            }
            finally
            {
                try { await host.StopAsync(); } catch { }
                PairingInfo.SetPort(previousPort);
            }
        }
    }
}
