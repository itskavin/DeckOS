using System;
using System.Diagnostics;
using System.IO;
using QRCoder;

namespace DeckOS.Lib
{
    /// <summary>
    /// O que a janela de pareamento do Windows mostra, no terminal (macOS/Linux): o endereco
    /// do configurador, o QR do app em texto e o link para abrir o deck no navegador.
    /// </summary>
    public static class ConsoleBanner
    {
        public static string WebUrl => $"http://localhost:{PairingInfo.Port}/";

        /// <summary>QR em meio-blocos (▀▄█): cabe num terminal de 80 colunas.</summary>
        public static string AsciiQr(string text)
        {
            using var generator = new QRCodeGenerator();
            using var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.L);
            return new AsciiQRCode(data).GetGraphicSmall();
        }

        public static void Print(TextWriter output)
        {
            var version = typeof(ConsoleBanner).Assembly.GetName().Version?.ToString(3);
            var uri = PairingInfo.BuildUri();
            output.WriteLine();
            output.WriteLine($"DeckOS {version} — {Environment.MachineName}");
            output.WriteLine($"Configurador:  {WebUrl}");
            output.WriteLine();
            output.WriteLine("Pareie o celular: no app DeckOS, toque em + e escaneie este QR.");
            output.WriteLine(AsciiQr(uri));
            output.WriteLine($"Ou abra no navegador do celular (iPhone, iPad): {PairingInfo.BuildBrowserUrl()}");
            output.WriteLine($"Dados em: {AppPaths.LocalDir}");
            output.WriteLine("Ctrl+C encerra.");
            output.WriteLine();
            output.Flush();
        }

        /// <summary>Abre uma URL no navegador padrao (open no macOS, xdg-open no Linux).</summary>
        public static void OpenBrowser(string url)
        {
            try
            {
                if (OperatingSystem.IsMacOS()) Platform.Tools.Spawn("open", new[] { url });
                else if (OperatingSystem.IsLinux()) Platform.Tools.Spawn("xdg-open", new[] { url });
                else Process.Start(new ProcessStartInfo(url) { UseShellExecute = true })?.Dispose();
            }
            catch (Exception ex)
            {
                Console.WriteLine($"Não foi possível abrir o navegador ({ex.Message}). Abra {url}");
            }
        }
    }
}
