using System;
using System.IO;
using System.Runtime.CompilerServices;
using DeckOS.Lib;

namespace DeckOS.Tests
{
    /// <summary>
    /// Roda antes de qualquer teste: aponta as pastas de dados do servidor para um
    /// diretorio temporario. Sem isso, os testes de integracao sobem o servidor real e leem
    /// (e migram) a chave, os segredos e os perfis de quem esta desenvolvendo.
    /// </summary>
    internal static class TestEnvironment
    {
        private static readonly Lazy<string> Device = new(() => {
            var pairing = DeckOS.Auth.SecurePairing.Shared;
            return pairing.Exchange(pairing.IssueToken(), "isolated-test-device")!.Value.Credential;
        });
        public static string DeviceCredential => Device.Value;
        [ModuleInitializer]
        internal static void IsolateDataDir()
        {
            var dir = Path.Combine(Path.GetTempPath(), "deckos-tests-" + Guid.NewGuid().ToString("N"));
            Environment.SetEnvironmentVariable(AppPaths.DataDirEnvVar, dir);
            // Sem anuncio Bonjour: varios servidores de teste disputariam a porta 5353.
            Environment.SetEnvironmentVariable("DECKOS_MDNS", "0");
        }
    }
}
