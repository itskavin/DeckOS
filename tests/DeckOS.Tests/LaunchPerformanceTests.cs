using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Platform;
using DeckOS.Services;
using Xunit;
#if WINDOWS
using System.Drawing;
using DeckOS.Platform.Windows;
#endif

namespace DeckOS.Tests
{
    /// <summary>
    /// Prazos de latencia rodam em serie, depois dos outros. A atualizacao em segundo plano vai
    /// para a fila do ThreadPool: no inicio da suite, num CI de poucos nucleos, essa fila chega
    /// a dezenas de itens e o Task.Run levava mais que o prazo sem nada estar errado.
    /// </summary>
    [CollectionDefinition(Name, DisableParallelization = true)]
    public class LaunchLatencyCollection
    {
        public const string Name = "Latencia de abertura";
    }

    [Collection(LaunchLatencyCollection.Name)]
    public class LaunchPerformanceTests
    {
        private sealed class FakeInstalledApps : InstalledAppsBase
        {
            private readonly Func<int, IEnumerable<InstalledApp>> _scan;
            private readonly Func<InstalledApp, Task<(byte[] Data, string ContentType)?>>? _icon;
            public int ScanCalls;
            public int IconCalls;

            public FakeInstalledApps(
                Func<int, IEnumerable<InstalledApp>> scan,
                Func<InstalledApp, Task<(byte[] Data, string ContentType)?>>? icon = null)
            {
                _scan = scan;
                _icon = icon;
            }

            protected override IEnumerable<InstalledApp> Scan()
            {
                var n = Interlocked.Increment(ref ScanCalls);
                return _scan(n);
            }

            protected override Task<(byte[] Data, string ContentType)?> LoadIconAsync(InstalledApp app)
            {
                Interlocked.Increment(ref IconCalls);
                return _icon != null ? _icon(app) : Task.FromResult<(byte[], string)?>(null);
            }
        }

        [Fact]
        public void InstalledApps_SingleFlight_CoalescesConcurrentColdScans()
        {
            using var gate = new ManualResetEventSlim(false);
            var apps = new FakeInstalledApps(_ =>
            {
                gate.Wait(TimeSpan.FromSeconds(5));
                return new[] { new InstalledApp("abcdef0123456789", "Sample", @"C:\sample.exe") };
            });

            var t1 = Task.Run(() => apps.List());
            var t2 = Task.Run(() => apps.Find("abcdef0123456789"));
            Thread.Sleep(40);
            gate.Set();

            Assert.Single(t1.Result);
            Assert.NotNull(t2.Result);
            Assert.Equal(1, apps.ScanCalls);
        }

        [Fact]
        public async Task InstalledApps_StaleWhileRevalidate_DoesNotBlockFindOrList()
        {
            var now = new DateTime(2026, 11, 22, 12, 0, 0, DateTimeKind.Utc);
            using var refreshStarted = new ManualResetEventSlim(false);
            using var allowRefreshFinish = new ManualResetEventSlim(false);

            var apps = new FakeInstalledApps(call =>
            {
                if (call == 1)
                {
                    return new[] { new InstalledApp("1111111111111111", "Alpha", @"C:\alpha.exe") };
                }
                refreshStarted.Set();
                allowRefreshFinish.Wait(TimeSpan.FromSeconds(5));
                return new[]
                {
                    new InstalledApp("1111111111111111", "Alpha", @"C:\alpha.exe"),
                    new InstalledApp("2222222222222222", "Beta", @"C:\beta.exe"),
                };
            })
            {
                UtcNow = () => now,
                ListTtl = TimeSpan.FromMinutes(5),
            };

            // Warm cache
            Assert.NotNull(apps.Find("1111111111111111"));
            Assert.Equal(1, apps.ScanCalls);

            // Advance past TTL: Find must return stale hit IMMEDIATELY without waiting for slow scan #2.
            now = now.AddMinutes(10);
            var sw = Stopwatch.StartNew();
            var hit = apps.Find("1111111111111111");
            sw.Stop();

            Assert.NotNull(hit);
            Assert.True(sw.ElapsedMilliseconds < 250, $"Stale Find blocked for {sw.ElapsedMilliseconds} ms");
            Assert.True(refreshStarted.Wait(TimeSpan.FromSeconds(3)), "Background refresh did not start");

            // Complete background refresh and verify new app becomes visible.
            allowRefreshFinish.Set();
            var deadline = DateTime.UtcNow.AddSeconds(3);
            while (apps.Find("2222222222222222") == null && DateTime.UtcNow < deadline)
                await Task.Delay(15);

            Assert.NotNull(apps.Find("2222222222222222"));
            Assert.Equal(2, apps.ScanCalls);
        }

        [Fact]
        public async Task InstalledApps_IconCache_DeduplicatesAndCachesInMemory()
        {
            // O cache em disco usa a pasta de dados isolada do TestEnvironment (por processo);
            // trocar DECKOS_DATA_DIR aqui vazava para os testes que rodam em paralelo.
            var id = "0123456789abcdef";
            var payload = new byte[] { 0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4 };
            var apps = new FakeInstalledApps(
                _ => new[] { new InstalledApp(id, "IconApp", @"C:\app.exe") },
                async _ =>
                {
                    await Task.Delay(30);
                    return (payload, "image/png");
                });

            var results = await Task.WhenAll(apps.GetIconAsync(id), apps.GetIconAsync(id), apps.GetIconAsync(id));
            Assert.All(results, r =>
            {
                Assert.NotNull(r);
                Assert.Equal(payload, r!.Value.Data);
            });
            Assert.Equal(1, apps.IconCalls);

            // Subsequent call hits in-memory LRU cache.
            var cached = await apps.GetIconAsync(id);
            Assert.NotNull(cached);
            Assert.Equal(1, apps.IconCalls);
        }

        [Theory]
        [InlineData("explorer.exe", @"shell:AppsFolder\Microsoft.WindowsCalculator_8wekyb3d8bbwe!App", true, "Microsoft.WindowsCalculator_8wekyb3d8bbwe!App", null)]
        [InlineData(@"C:\Windows\explorer.exe", @"shell:AppsFolder\Pkg_123!App --extra --flag", true, "Pkg_123!App", "--extra --flag")]
        [InlineData(@"shell:AppsFolder\Pkg_123!App", "--silent", true, "Pkg_123!App", "--silent")]
        [InlineData("explorer.exe", @"C:\Users", false, "", null)]
        [InlineData(@"C:\Program Files\App\app.exe", "--flag", false, "", null)]
        [InlineData("explorer.exe", @"shell:AppsFolder\NotAStoreAppWithoutBang", false, "", null)]
        public void TryParseAppsFolderTarget_ParsesStoreAppsAndArgs(
            string path, string? args, bool expected, string expectedAumid, string? expectedExtra)
        {
            var ok = AppActivator.TryParseAppsFolderTarget(path, args, out var aumid, out var extra);
            Assert.Equal(expected, ok);
            if (expected)
            {
                Assert.Equal(expectedAumid, aumid);
                Assert.Equal(expectedExtra, extra);
            }
        }

        [Theory]
        [InlineData(null, null, "")]
        [InlineData("--a", null, "--a")]
        [InlineData(null, "--b", "--b")]
        [InlineData("--same", "--same", "--same")]
        [InlineData("--a", "--b", "--a --b")]
        public void CombineArguments_PreservesAndDeduplicates(string? first, string? second, string expected)
        {
            Assert.Equal(expected, AppActivator.CombineArguments(first, second));
        }

#if WINDOWS
        [Fact]
        public void WindowsInstalledApps_DrawnInCorner_DetectsSmallVsFullIcons()
        {
            using var corner = new Bitmap(256, 256);
            using (var g = Graphics.FromImage(corner))
            {
                g.Clear(Color.Transparent);
                g.FillRectangle(Brushes.White, 0, 0, 32, 32);
            }
            Assert.True(WindowsInstalledApps.DrawnInCorner(corner));

            using var full = new Bitmap(256, 256);
            using (var g = Graphics.FromImage(full))
            {
                g.Clear(Color.Transparent);
                g.FillRectangle(Brushes.White, 0, 0, 200, 200);
            }
            Assert.False(WindowsInstalledApps.DrawnInCorner(full));
        }

        [Fact]
        public void WindowsInstalledApps_ComEnumeration_ReturnsStoreAppsInProcess()
        {
            if (!OperatingSystem.IsWindows()) return;
            var sw = Stopwatch.StartNew();
            var items = WindowsInstalledApps.TryEnumerateAppsFolderCom();
            sw.Stop();
            Assert.NotNull(items);
            Assert.All(items!, item => Assert.Contains("!", item.AppId));
        }

        [Fact]
        public void AppActivator_ResolveShortcutCached_ReadsAndCachesLnkAndInvalidatesOnWrite()
        {
            if (!OperatingSystem.IsWindows()) return;
            var lnk = Directory.EnumerateFiles(
                    Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms),
                    "*.lnk", SearchOption.AllDirectories)
                .FirstOrDefault();
            if (lnk == null) return;

            var tmpDir = Path.Combine(Path.GetTempPath(), "deckos-lnk-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(tmpDir);
            var copy = Path.Combine(tmpDir, Path.GetFileName(lnk));
            try
            {
                File.Copy(lnk, copy);
                var activator = new AppActivator();
                var first = activator.ResolveShortcutCached(copy);
                var second = activator.ResolveShortcutCached(copy);
                Assert.Same(first, second);

                // Touching LastWriteTimeUtc invalidates the cache entry.
                File.SetLastWriteTimeUtc(copy, File.GetLastWriteTimeUtc(copy).AddSeconds(5));
                var third = activator.ResolveShortcutCached(copy);
                if (first != null) Assert.NotSame(first, third);
            }
            finally
            {
                try { Directory.Delete(tmpDir, true); } catch { }
            }
        }
#endif
    }
}
