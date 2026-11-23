using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Actions.Providers;
using DeckOS.Hubs;
using DeckOS.Models;
using DeckOS.Services;
using Microsoft.AspNetCore.SignalR;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using Xunit;

namespace DeckOS.Tests
{
    public class TimerServiceTests
    {
        private DateTime _now = new(2026, 10, 15, 12, 0, 0, DateTimeKind.Utc);
        private readonly List<string> _finished = new();

        private TimerService Service()
        {
            var clients = new Mock<IHubClients>();
            clients.Setup(c => c.All).Returns(Mock.Of<IClientProxy>());
            var hub = new Mock<IHubContext<DeckHub>>();
            hub.Setup(h => h.Clients).Returns(clients.Object);

            return new TimerService(NullLogger<TimerService>.Instance, hub.Object)
            {
                Now = () => _now,
                OnFinished = t => _finished.Add(t.Id),
            };
        }

        private static Dictionary<string, string> P(params (string k, string v)[] ps) =>
            ps.ToDictionary(p => p.k, p => p.v);

        private static long Field(TimerService s, string id, string name)
        {
            var entry = s.GetStatePayload()[id];
            return Convert.ToInt64(entry.GetType().GetProperty(name)!.GetValue(entry));
        }

        private static bool Flag(TimerService s, string id, string name) =>
            (bool)s.GetStatePayload()[id].GetType().GetProperty(name)!.GetValue(s.GetStatePayload()[id])!;

        [Fact]
        public void Countdown_TerminaNaHora_eAvisa()
        {
            var s = Service();
            var p = P(("mode", "countdown"), ("durationSec", "60"));

            s.Apply("t", "toggle", p);
            _now += TimeSpan.FromSeconds(59);
            Assert.False(s.Tick());

            _now += TimeSpan.FromSeconds(2);
            Assert.True(s.Tick());
            Assert.True(Flag(s, "t", "finished"));
            Assert.False(Flag(s, "t", "running"));
            Assert.Equal(new[] { "t" }, _finished);
        }

        [Fact]
        public void Pausar_CongelaOTempo()
        {
            var s = Service();
            var p = P(("mode", "stopwatch"));

            s.Apply("c", "toggle", p);
            _now += TimeSpan.FromSeconds(10);
            s.Apply("c", "toggle", p); // pausa
            _now += TimeSpan.FromMinutes(5);

            Assert.Equal(10_000, Field(s, "c", "elapsedMs"));
        }

        [Fact]
        public void ToqueDepoisDeTerminar_Zera()
        {
            var s = Service();
            var p = P(("mode", "countdown"), ("durationSec", "1"));
            s.Apply("t", "toggle", p);
            _now += TimeSpan.FromSeconds(2);
            s.Tick();

            s.Apply("t", "toggle", p);

            Assert.False(Flag(s, "t", "finished"));
            Assert.Equal(0, Field(s, "t", "elapsedMs"));
        }

        [Fact]
        public void Pomodoro_PassaParaAPausa_SemAcumularAtraso()
        {
            var s = Service();
            var p = P(("mode", "pomodoro"), ("workSec", "1500"), ("breakSec", "300"));
            s.Apply("p", "toggle", p);

            // O laco percebe o fim 1s atrasado: a pausa conta a partir do fim real.
            _now += TimeSpan.FromSeconds(1501);
            Assert.True(s.Tick());

            Assert.True(Flag(s, "p", "running"));
            Assert.Equal(1, Field(s, "p", "cycles"));
            Assert.Equal(300_000, Field(s, "p", "durationMs"));
            Assert.Equal(1_000, Field(s, "p", "elapsedMs"));
        }

        [Fact]
        public void Contador_SomaSubtraiEZera()
        {
            var s = Service();
            var p = P(("mode", "counter"));

            s.Apply("n", "toggle", p);
            s.Apply("n", "increment", P(("mode", "counter"), ("step", "5")));
            s.Apply("n", "decrement", p);
            Assert.Equal(5, Field(s, "n", "count"));

            s.Apply("n", "reset", p);
            Assert.Equal(0, Field(s, "n", "count"));
        }

        [Fact]
        public void TrocarOModoDoBotao_ComecaDoZero()
        {
            var s = Service();
            s.Apply("x", "toggle", P(("mode", "stopwatch")));
            _now += TimeSpan.FromSeconds(30);

            s.Apply("x", "toggle", P(("mode", "countdown"), ("durationSec", "60")));

            Assert.Equal(0, Field(s, "x", "elapsedMs"));
            Assert.True(Flag(s, "x", "running"));
        }

        private static DeckButton CounterButton(string id, int row = 0, int col = 0) => new()
        {
            Id = id,
            Row = row,
            Column = col,
            Label = id,
            Action = new DeckAction { Type = "timer", Parameters = new() { ["mode"] = "counter" } },
        };

        private static Dictionary<string, long> ReadCountersFile(string path) =>
            File.Exists(path)
                ? JsonSerializer.Deserialize<Dictionary<string, long>>(File.ReadAllText(path)) ?? new()
                : new();

        private TimerService IsolatedService(StreamDeckConfigService config, string countersPath)
        {
            var clients = new Mock<IHubClients>();
            clients.Setup(c => c.All).Returns(Mock.Of<IClientProxy>());
            var hub = new Mock<IHubContext<DeckHub>>();
            hub.Setup(h => h.Clients).Returns(clients.Object);
            return new TimerService(NullLogger<TimerService>.Instance, hub.Object, config, countersPath)
            {
                Now = () => _now,
            };
        }

        [Fact]
        public void Contador_LimpaQuandoBotaoEApagado()
        {
            var dir = Path.Combine(Path.GetTempPath(), "deckos-counters-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                var countersPath = Path.Combine(dir, "counters.json");
                var config = new StreamDeckConfigService(NullLogger<StreamDeckConfigService>.Instance, dir);
                var profile = new DeckProfile { Id = "p1", Name = "P1", Buttons = { CounterButton("c1", 0, 0), CounterButton("c2", 0, 1) } };
                config.SaveProfile(profile);

                using var s = IsolatedService(config, countersPath);
                s.Apply("c1", "increment", P(("mode", "counter"), ("step", "3")));
                s.Apply("c2", "increment", P(("mode", "counter"), ("step", "7")));
                Assert.Equal(3, ReadCountersFile(countersPath)["c1"]);
                Assert.Equal(7, ReadCountersFile(countersPath)["c2"]);

                // Remove o botao c1 e salva o perfil: o contador orfao precisa sumir do disco e da memoria.
                profile.Buttons.RemoveAll(b => b.Id == "c1");
                config.SaveProfile(profile);

                Assert.False(s.GetStatePayload().ContainsKey("c1"));
                Assert.Equal(7, Field(s, "c2", "count"));
                var saved = ReadCountersFile(countersPath);
                Assert.False(saved.ContainsKey("c1"));
                Assert.Equal(7, saved["c2"]);
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }

        [Fact]
        public void Contador_LimpaQuandoPerfilEApagado()
        {
            var dir = Path.Combine(Path.GetTempPath(), "deckos-counters-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                var countersPath = Path.Combine(dir, "counters.json");
                var config = new StreamDeckConfigService(NullLogger<StreamDeckConfigService>.Instance, dir);
                config.SaveProfile(new DeckProfile { Id = "p1", Name = "P1", Buttons = { CounterButton("c1") } });

                using var s = IsolatedService(config, countersPath);
                s.Apply("c1", "increment", P(("mode", "counter"), ("step", "4")));
                Assert.Equal(4, ReadCountersFile(countersPath)["c1"]);

                config.DeleteProfile("p1");

                Assert.False(s.GetStatePayload().ContainsKey("c1"));
                Assert.Empty(ReadCountersFile(countersPath));
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }

        [Fact]
        public void Contador_LimpaOrfaosNoStartupEPreservaAtivos()
        {
            var dir = Path.Combine(Path.GetTempPath(), "deckos-counters-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                var countersPath = Path.Combine(dir, "counters.json");
                var config = new StreamDeckConfigService(NullLogger<StreamDeckConfigService>.Instance, dir);
                config.SaveProfile(new DeckProfile { Id = "p1", Name = "P1", Buttons = { CounterButton("vivo") } });
                File.WriteAllText(countersPath, JsonSerializer.Serialize(new Dictionary<string, long>
                {
                    ["vivo"] = 12,
                    ["orfao"] = 99,
                }));

                using var s = IsolatedService(config, countersPath);

                Assert.Equal(12, Field(s, "vivo", "count"));
                Assert.False(s.GetStatePayload().ContainsKey("orfao"));
                var saved = ReadCountersFile(countersPath);
                Assert.Equal(new[] { "vivo" }, saved.Keys);
                Assert.Equal(12, saved["vivo"]);
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }

        [Fact]
        public void Contador_PreservaValorAoMoverBotaoEntrePerfis()
        {
            var dir = Path.Combine(Path.GetTempPath(), "deckos-counters-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(dir);
            try
            {
                var countersPath = Path.Combine(dir, "counters.json");
                var config = new StreamDeckConfigService(NullLogger<StreamDeckConfigService>.Instance, dir);
                config.SaveProfile(new DeckProfile { Id = "p1", Name = "P1", Buttons = { CounterButton("m1", 0, 0) } });
                config.SaveProfile(new DeckProfile { Id = "p2", Name = "P2" });

                using var s = IsolatedService(config, countersPath);
                s.Apply("m1", "increment", P(("mode", "counter"), ("step", "5")));

                Assert.Equal(StreamDeckConfigService.CopyButtonResult.Ok,
                    config.CopyButton("p1", "m1", "p2", 0, 0, move: true));

                Assert.Equal(5, Field(s, "m1", "count"));
                Assert.Equal(5, ReadCountersFile(countersPath)["m1"]);
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }
    }

    public class HttpProviderTests
    {
        [Fact]
        public async Task Requisicao_LevaCorpoECabecalhos()
        {
            using var req = HttpProvider.BuildRequest(HttpMethod.Post, new Uri("https://exemplo.com/hook"),
                "Authorization: Bearer abc\nX-Origem: deck\nlinha invalida\nContent-Type: application/vnd.teste",
                "{\"a\":1}", "application/json");

            Assert.Equal("Bearer abc", req.Headers.Authorization!.ToString());
            Assert.Equal("deck", req.Headers.GetValues("X-Origem").Single());
            Assert.Equal("application/vnd.teste", req.Content!.Headers.ContentType!.MediaType);
            Assert.Equal("{\"a\":1}", await req.Content.ReadAsStringAsync());
        }

        [Fact]
        public void Get_NaoTemCorpo()
        {
            using var req = HttpProvider.BuildRequest(HttpMethod.Get, new Uri("https://exemplo.com"), "", "ignorado", "text/plain");
            Assert.Null(req.Content);
        }
    }
}
