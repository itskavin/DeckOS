using System.Collections.Generic;
using System.Threading.Tasks;
using DeckOS.Actions;
using DeckOS.Actions.Providers;
using DeckOS.Models;
using DeckOS.Platform;
using DeckOS.Services;
using Moq;
using Xunit;

namespace DeckOS.Tests
{
    /// <summary>
    /// Botao "abrir programa" vindo da biblioteca "Apps deste computador": o app da Store e
    /// explorer.exe + "shell:AppsFolder\...", e o configurador grava path, arguments e appId.
    /// </summary>
    public class LaunchAppProviderTests
    {
        private static readonly InstalledApp Calc = new("fedcba9876543210", "Calculadora", "explorer.exe")
        {
            Arguments = @"shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App",
        };

        private sealed class OneApp : IInstalledApps
        {
            public IReadOnlyList<InstalledApp> List() => new[] { Calc };
            public InstalledApp? Find(string id) => id == Calc.Id ? Calc : null;
            public Task<(byte[] Data, string ContentType)?> GetIconAsync(string id) =>
                Task.FromResult<(byte[], string)?>(null);
        }

        private static async Task<Mock<IAppActivator>> Run(params (string Key, string Value)[] parameters)
        {
            var activator = new Mock<IAppActivator>();
            var action = new DeckAction { Type = "launch_app" };
            foreach (var (k, v) in parameters) action.Parameters[k] = v;
            await new LaunchAppProvider(activator.Object, new OneApp())
                .ExecuteAsync(new ActionContext(action, "b1", (_, _) => Task.CompletedTask));
            return activator;
        }

        [Fact]
        public async Task AppId_ComOsMesmosArgumentos_NaoRepete()
        {
            var a = await Run(("path", "explorer.exe"), ("arguments", Calc.Arguments!), ("appId", Calc.Id));
            a.Verify(x => x.LaunchApp("explorer.exe", Calc.Arguments), Times.Once);
        }

        [Fact]
        public async Task AppId_ComArgumentoExtra_Acrescenta()
        {
            var a = await Run(("path", "explorer.exe"), ("arguments", "--extra"), ("appId", Calc.Id));
            a.Verify(x => x.LaunchApp("explorer.exe", Calc.Arguments + " --extra"), Times.Once);
        }

        [Fact]
        public async Task AppSumiuDaLista_UsaCaminhoEArgumentosGravados()
        {
            var a = await Run(("path", "explorer.exe"), ("arguments", Calc.Arguments!), ("appId", "naoexiste"));
            a.Verify(x => x.LaunchApp("explorer.exe", Calc.Arguments), Times.Once);
        }
    }
}
