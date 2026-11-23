using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.Hosting;

namespace DeckOS.Lib
{
    /// <summary>
    /// Quando o servidor termina de subir, copia o endereco em que ele escuta para
    /// <see cref="PairingInfo"/>: o QR, o banner e o mDNS usam a porta real, nao a padrao.
    /// </summary>
    internal sealed class BoundPortWatcher : IHostedService
    {
        private readonly IServer _server;
        private readonly IHostApplicationLifetime _lifetime;

        public BoundPortWatcher(IServer server, IHostApplicationLifetime lifetime)
        {
            _server = server;
            _lifetime = lifetime;
        }

        public Task StartAsync(CancellationToken cancellationToken)
        {
            // Se o Kestrel ja subiu antes deste servico, atualiza logo (antes do mDNS anunciar).
            Sync();
            // Caso contrario (ou se o endereco final so existir no ApplicationStarted), sincroniza la.
            _lifetime.ApplicationStarted.Register(Sync);
            return Task.CompletedTask;
        }

        private void Sync()
        {
            var addresses = _server.Features.Get<IServerAddressesFeature>()?.Addresses;
            if (addresses != null) PairingInfo.UseBoundAddresses(addresses);
        }

        public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    }
}
