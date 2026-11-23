using System;
using System.IO;
using System.Linq;
using DeckOS.Models;
using DeckOS.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace DeckOS.Tests
{
    /// <summary>
    /// A ordem dos perfis e a ordem das paginas no celular. Do disco os arquivos vinham em
    /// ordem de nome: depois de reiniciar o PC, uma pagina criada pelo app (id numerico)
    /// passava na frente da "Default" (GUID).
    /// </summary>
    public class ProfileOrderTests : IDisposable
    {
        private readonly string _dir = Path.Combine(Path.GetTempPath(), "deckos-order-" + Guid.NewGuid().ToString("N"));

        public void Dispose()
        {
            try { Directory.Delete(_dir, true); } catch { }
        }

        private StreamDeckConfigService Open() => new(NullLogger<StreamDeckConfigService>.Instance, _dir);

        private static string[] Ids(StreamDeckConfigService s) => s.GetProfiles().Select(p => p.Id).ToArray();

        [Fact]
        public void DepoisDeReiniciar_MantemAOrdemDeCriacao()
        {
            var s = Open();
            s.SaveProfile(new DeckProfile { Id = "zz-default", Name = "Default", IsDefault = true });
            s.SaveProfile(new DeckProfile { Id = "1795338151824", Name = "Pagina nova" });
            s.SaveProfile(new DeckProfile { Id = "mm-outra", Name = "Outra" });
            // Editar nao muda o lugar.
            s.SaveProfile(new DeckProfile { Id = "zz-default", Name = "Default editada", IsDefault = true });
            Assert.Equal(new[] { "zz-default", "1795338151824", "mm-outra" }, Ids(s));

            Assert.Equal(new[] { "zz-default", "1795338151824", "mm-outra" }, Ids(Open()));
        }

        [Fact]
        public void ApagarERecriar_VaiProFim_ESemArquivoDeOrdemUsaOsArquivos()
        {
            var s = Open();
            s.SaveProfile(new DeckProfile { Id = "b", Name = "B" });
            s.SaveProfile(new DeckProfile { Id = "a", Name = "A" });
            s.SaveProfile(new DeckProfile { Id = "c", Name = "C" });
            s.DeleteProfile("b");
            s.SaveProfile(new DeckProfile { Id = "b", Name = "B de novo" });
            Assert.Equal(new[] { "a", "c", "b" }, Ids(Open()));

            // Instalacao antiga (sem o arquivo): fica a ordem dos arquivos, e passa a ser gravada.
            File.Delete(Path.Combine(_dir, "profile-order.json"));
            var migrated = Ids(Open());
            Assert.Equal(new[] { "a", "b", "c" }, migrated);
            Assert.True(File.Exists(Path.Combine(_dir, "profile-order.json")));
        }
    }
}
