using System;
using System.Linq;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Lib;
using Makaretu.Dns;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Xunit;

namespace DeckOS.Tests
{
    [Collection("PairingPort")]
    public class MdnsStartupTests
    {
        [Theory]
        [InlineData("0", false)]
        [InlineData("FALSE", false)]
        [InlineData(" false ", false)]
        [InlineData("1", true)]
        [InlineData(null, true)]
        public void Enabled_RespeitaConfiguracao(string? value, bool expected) =>
            Assert.Equal(expected, MdnsAdvertiser.IsEnabled(value));

        private static MdnsAdvertiser Advertiser(CancellationToken started, ServerAddressesFeature addresses)
        {
            var features = new FeatureCollection();
            features.Set<IServerAddressesFeature>(addresses);
            var server = new Mock<IServer>();
            server.SetupGet(s => s.Features).Returns(features);
            var lifetime = new Mock<IHostApplicationLifetime>();
            lifetime.SetupGet(l => l.ApplicationStarted).Returns(started);
            return new MdnsAdvertiser(NullLogger<MdnsAdvertiser>.Instance, server.Object, lifetime.Object);
        }

        [Fact]
        public async Task Anuncio_EsperaStartupEUsaPortaFinal()
        {
            var previousPort = PairingInfo.Port;
            using var started = new CancellationTokenSource();
            var addresses = new ServerAddressesFeature();
            using var advertiser = Advertiser(started.Token, addresses);
            try
            {
                PairingInfo.SetPort(PairingInfo.DefaultPort);
                var ready = advertiser.WaitForServerAsync(CancellationToken.None);
                Assert.False(ready.IsCompleted);
                Assert.Equal(PairingInfo.DefaultPort, PairingInfo.Port);

                addresses.Addresses.Add("http://127.0.0.1:59421");
                started.Cancel();
                // Prazo folgado para o CI carregado; num PC normal termina na hora.
                await ready.WaitAsync(TimeSpan.FromSeconds(20));
                Assert.Equal(59421, PairingInfo.Port);
            }
            finally { PairingInfo.SetPort(previousPort); }
        }

        [Fact]
        public async Task Anuncio_CancelaSeServidorNaoChegaASubir()
        {
            using var started = new CancellationTokenSource();
            using var stopping = new CancellationTokenSource();
            using var advertiser = Advertiser(started.Token, new ServerAddressesFeature());
            var ready = advertiser.WaitForServerAsync(stopping.Token);
            stopping.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => ready);
        }

        [Fact]
        public void BuildProfile_UsaApenasIpDaLanQuandoDisponivel()
        {
            var lanIp = NetworkInfo.GetLanIp();
            if (!IPAddress.TryParse(lanIp, out var expected) || IPAddress.IsLoopback(expected)) return;

            var profile = MdnsAdvertiser.BuildProfile();
            var aRecords = profile.Resources.OfType<ARecord>().Select(r => r.Address).ToList();
            Assert.Equal(new[] { expected }, aRecords);
        }
    }
}
