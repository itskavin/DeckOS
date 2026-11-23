using System.Text.RegularExpressions;
using DeckOS.Auth;
using QRCoder;

namespace DeckOS.Lib
{
    /// <summary>
    /// Monta os dados de pareamento (URI + QR) compartilhados pela janela de bandeja
    /// e pelo modo de diagnóstico --print-pairing.
    /// </summary>
    public static class PairingInfo
    {
        public const int DefaultPort = 4787;

        private static volatile int _port = PortFromUrls(Environment.GetEnvironmentVariable("ASPNETCORE_URLS")) ?? DefaultPort;

        /// <summary>
        /// Porta do servidor: a de ASPNETCORE_URLS ate o host subir, depois a que ele de fato
        /// escutou (<see cref="UseBoundAddresses"/>). Antes era sempre 4787, e o QR e o banner
        /// apontavam para a porta errada quando a configuracao mandava outra.
        /// </summary>
        public static int Port => _port;

        /// <summary>A porta do primeiro endereco http (senao do primeiro) de uma lista de URLs do Kestrel.</summary>
        public static int? PortFromUrls(string? urls)
        {
            if (string.IsNullOrWhiteSpace(urls)) return null;
            return PortFromUrls(urls.Split(new[] { ';', ',' }, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
        }

        public static int? PortFromUrls(IEnumerable<string> urls)
        {
            int? first = null;
            foreach (var url in urls)
            {
                // "+" e "*" (qualquer interface) nao sao hosts validos para o Uri.
                var normalized = Regex.Replace(url, @"://[+*]", "://localhost");
                if (!Uri.TryCreate(normalized, UriKind.Absolute, out var uri) || uri.Port <= 0) continue;
                if (uri.Scheme == Uri.UriSchemeHttp) return uri.Port;
                first ??= uri.Port;
            }
            return first;
        }

        /// <summary>Guarda a porta em que o servidor realmente escuta (vale a de porta 0 resolvida).</summary>
        public static void UseBoundAddresses(IEnumerable<string> addresses)
        {
            if (PortFromUrls(addresses) is { } port) _port = port;
        }

        /// <summary>Ajuste direto da porta (usado pelos testes para restaurar o estado).</summary>
        internal static void SetPort(int port) => _port = port > 0 ? port : DefaultPort;

        /// <summary>URI escaneada pelo app: deckos://pair?ip=..&port=..&key=..</summary>
        public static string BuildUri()
        {
            var ip = NetworkInfo.GetLanIp();
            var key = ApiKeyProvider.GetKey();
            return $"deckos://pair?ip={ip}&port={Port}&key={key}";
        }

        /// <summary>
        /// Endereco do deck no navegador (iPhone, tablet, outro PC), ja com a chave: a camera
        /// abre direto e a pagina guarda a chave e a tira da barra de endereco.
        /// </summary>
        public static string BuildBrowserUrl()
        {
            var ip = NetworkInfo.GetLanIp();
            var key = ApiKeyProvider.GetKey();
            return $"http://{ip}:{Port}/?pair={System.Uri.EscapeDataString(key)}";
        }

        public static byte[] BuildQrPng(string uri, int pixelsPerModule = 10)
        {
            var generator = new QRCodeGenerator();
            var data = generator.CreateQrCode(uri, QRCodeGenerator.ECCLevel.Q);
            return new PngByteQRCode(data).GetGraphic(pixelsPerModule);
        }
    }
}
