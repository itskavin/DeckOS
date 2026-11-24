using System;
using System.IO;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using Makaretu.Dns;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace DeckOS.Lib
{
    /// <summary>
    /// Anuncia o servidor por mDNS/Bonjour como _deckos._tcp na porta da API, alem do
    /// discovery por UDP (<see cref="DiscoveryServer"/>). O iPhone nao faz broadcast UDP sem
    /// permissao especial, mas acha servicos Bonjour de graca (NWBrowser/NSNetServiceBrowser).
    ///
    /// TXT: name (nome do PC), version e id (fixo por instalacao, para o app reconhecer o PC
    /// mesmo quando o IP muda). DECKOS_MDNS=0 desliga (os testes desligam).
    /// </summary>
    public sealed class MdnsAdvertiser : BackgroundService
    {
        public const string ServiceType = "_deckos._tcp";

        private readonly ILogger<MdnsAdvertiser> _logger;
        private readonly IServer _server;
        private readonly IHostApplicationLifetime _lifetime;

        public MdnsAdvertiser(ILogger<MdnsAdvertiser> logger, IServer server, IHostApplicationLifetime lifetime)
        {
            _logger = logger;
            _server = server;
            _lifetime = lifetime;
        }

        public static bool IsEnabled(string? value) =>
            value?.Trim() != "0" && !string.Equals(value?.Trim(), "false", StringComparison.OrdinalIgnoreCase);

        public static bool Enabled =>
            IsEnabled(Environment.GetEnvironmentVariable("DECKOS_MDNS"));

        /// <summary>Id desta instalacao (aleatorio, gravado na primeira vez em LocalDir/instance-id).</summary>
        public static string InstanceId
        {
            get
            {
                var path = Path.Combine(AppPaths.LocalDir, "instance-id");
                try
                {
                    if (File.Exists(path) && File.ReadAllText(path).Trim() is { Length: >= 8 } existing) return existing;
                    var id = Guid.NewGuid().ToString("N");
                    File.WriteAllText(path, id);
                    return id;
                }
                catch
                {
                    return Environment.MachineName.ToLowerInvariant();
                }
            }
        }

        public static ServiceProfile BuildProfile()
        {
            var version = typeof(MdnsAdvertiser).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";
            // Passa o IP real da LAN: sem isso o Makaretu anuncia todas as placas (incluindo
            // vEthernet/WSL/Hyper-V), e o celular acabava tentando um IP inalcancavel.
            var addresses = IPAddress.TryParse(NetworkInfo.GetLanIp(), out var lanIp) && !IPAddress.IsLoopback(lanIp)
                ? new[] { lanIp }
                : null;
            var profile = new ServiceProfile(Environment.MachineName, ServiceType, (ushort)PairingInfo.Port, addresses);
            profile.AddProperty("name", Environment.MachineName);
            profile.AddProperty("protocol", "https");
            profile.AddProperty("pairingVersion", "2");
            profile.AddProperty("version", version);
            profile.AddProperty("id", InstanceId);
            return profile;
        }

        /// <summary>Espera o Kestrel escutar antes de montar o anuncio, inclusive com porta dinamica.</summary>
        internal async Task WaitForServerAsync(CancellationToken stoppingToken)
        {
            var ready = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            using var registration = _lifetime.ApplicationStarted.Register(() => ready.TrySetResult(true));
            await ready.Task.WaitAsync(stoppingToken);
            stoppingToken.ThrowIfCancellationRequested();
            var addresses = _server.Features.Get<IServerAddressesFeature>()?.Addresses;
            if (addresses != null) PairingInfo.UseBoundAddresses(addresses);
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            // O registro do servico ja respeita a mesma configuracao de /api/platform.
            ServiceDiscovery? sd = null;
            ServiceProfile? profile = null;
            try
            {
                await WaitForServerAsync(stoppingToken);
                profile = BuildProfile();
                sd = new ServiceDiscovery();
                sd.Advertise(profile);
                sd.Announce(profile);
                _logger.LogInformation("[mDNS] Anunciando {Type} na porta {Port}", ServiceType, PairingInfo.Port);
                await Task.Delay(Timeout.Infinite, stoppingToken);
            }
            catch (OperationCanceledException) { }
            catch (Exception ex)
            {
                // Porta 5353 tomada ou rede sem multicast: o discovery por UDP continua.
                _logger.LogWarning(ex, "[mDNS] Anuncio desativado");
            }
            finally
            {
                try
                {
                    if (sd != null && profile != null) sd.Unadvertise(profile);
                }
                catch { }
                try { sd?.Dispose(); } catch { }
            }
        }
    }
}
