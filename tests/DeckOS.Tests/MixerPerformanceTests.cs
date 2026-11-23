#if WINDOWS
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Threading.Tasks;
using DeckOS.Audio;
using DeckOS.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Moq;
using NAudio.CoreAudioApi;
using Xunit;

namespace DeckOS.Tests
{
    public class MixerPerformanceTests
    {
        [Fact]
        public void ProcessMetadataCache_CachesIcon_AndInvalidatesOnFileTimestampChange()
        {
            var mtime = 1000L;
            var extractCalls = 0;
            var cache = new ProcessMetadataCache(
                maxIconEntries: 16,
                processReader: _ => new ProcessMetadataCache.LiveProcessInfo("zen", "DeckOS", @"C:\Apps\zen.exe"),
                lastWriteTicksReader: _ => mtime,
                iconExtractor: _ => $"data:image/png;base64,v{++extractCalls}");

            var first = cache.Resolve(100);
            var second = cache.Resolve(100);

            Assert.True(first.Found);
            Assert.Equal("data:image/png;base64,v1", first.Icon);
            Assert.Equal("data:image/png;base64,v1", second.Icon);
            Assert.Equal(1, extractCalls);

            // Simulate binary update on disk: mtime changes -> icon must be re-extracted.
            mtime = 2000L;
            var third = cache.Resolve(100);

            Assert.Equal("data:image/png;base64,v2", third.Icon);
            Assert.Equal(2, extractCalls);
        }

        [Fact]
        public void ProcessMetadataCache_NegativeIconResult_ExpiresAfterTtl()
        {
            var now = new DateTime(2026, 11, 23, 0, 0, 0, DateTimeKind.Utc);
            var extractCalls = 0;
            string? nextIcon = null;

            var cache = new ProcessMetadataCache(
                maxIconEntries: 16,
                negativeTtl: TimeSpan.FromSeconds(30),
                processReader: _ => new ProcessMetadataCache.LiveProcessInfo("audiodg", "", @"C:\Windows\System32\audiodg.exe"),
                lastWriteTicksReader: _ => 500L,
                iconExtractor: _ =>
                {
                    extractCalls++;
                    return nextIcon;
                },
                utcNowTicks: () => now.Ticks);

            var first = cache.Resolve(50);
            var second = cache.Resolve(50);
            Assert.Null(first.Icon);
            Assert.Null(second.Icon);
            Assert.Equal(1, extractCalls);

            // After TTL expires, cache retries extraction instead of permanently hiding icons.
            now = now.AddSeconds(31);
            nextIcon = "data:image/png;base64,recovered";
            var third = cache.Resolve(50);

            Assert.Equal("data:image/png;base64,recovered", third.Icon);
            Assert.Equal(2, extractCalls);
        }

        [Fact]
        public void ProcessMetadataCache_EnforcesMaxEntries_AndEvictsLeastRecentlyUsed()
        {
            var tick = 100L;
            var extractCalls = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);

            var cache = new ProcessMetadataCache(
                maxIconEntries: 2,
                processReader: pid => new ProcessMetadataCache.LiveProcessInfo($"app{pid}", "", $@"C:\Apps\app{pid}.exe"),
                lastWriteTicksReader: _ => 1L,
                iconExtractor: path =>
                {
                    extractCalls[path] = extractCalls.GetValueOrDefault(path) + 1;
                    return $"icon:{path}:{extractCalls[path]}";
                },
                utcNowTicks: () => ++tick);

            cache.Resolve(1); // t=101
            cache.Resolve(2); // t=102
            cache.Resolve(1); // t=103 (app1 is now MRU; app2 is LRU)
            cache.Resolve(3); // t=104 -> evicts app2

            Assert.True(cache.CachedIconCount <= 2);

            // app1 should still be cached (no second extraction).
            cache.Resolve(1);
            Assert.Equal(1, extractCalls[@"C:\Apps\app1.exe"]);

            // app2 was evicted, so resolving it again triggers a fresh extraction.
            cache.Resolve(2);
            Assert.Equal(2, extractCalls[@"C:\Apps\app2.exe"]);
            Assert.True(cache.CachedIconCount <= 2);
        }

        [Fact]
        public void ProcessMetadataCache_ReadsLiveWindowTitle_AndDropsExitedProcesses_AndDeduplicatesPerPass()
        {
            var readCount = 0;
            var title = "Song A";
            var alive = true;

            var cache = new ProcessMetadataCache(
                processReader: _ =>
                {
                    readCount++;
                    return alive
                        ? new ProcessMetadataCache.LiveProcessInfo("Spotify", title, @"C:\Apps\Spotify.exe")
                        : null;
                },
                lastWriteTicksReader: _ => 1L,
                iconExtractor: _ => "data:image/png;base64,spotify");

            // Within one enumeration pass across 3 devices, PID is queried once.
            var pass1 = new Dictionary<int, ProcessSessionMetadata>();
            var r1 = cache.Resolve(42, pass1);
            var r2 = cache.Resolve(42, pass1);
            var r3 = cache.Resolve(42, pass1);

            Assert.Equal(1, readCount);
            Assert.Equal("Spotify: Song A", r1.Description);
            Assert.Equal(r1, r2);
            Assert.Equal(r1, r3);

            // Next pass reflects updated live title without stale description.
            title = "Song B";
            var r4 = cache.Resolve(42, new Dictionary<int, ProcessSessionMetadata>());
            Assert.Equal(2, readCount);
            Assert.Equal("Spotify: Song B", r4.Description);

            // Once process exits, cache never pretends the dead PID is alive.
            alive = false;
            var r5 = cache.Resolve(42, new Dictionary<int, ProcessSessionMetadata>());
            Assert.False(r5.Found);
            Assert.Null(r5.Description);
        }

        [Fact]
        public void MixerMaster_ReadsFriendlyNameAndVolumeOnce_AndDisposesAllDevicesAndSessions()
        {
            var friendlyReads = 0;
            var volumeReads = 0;
            var deviceDisposed = 0;
            var sessionDisposed = 0;

            var s1 = new Mock<IAudioSession>();
            s1.SetupGet(s => s.IsSystemSoundsSession).Returns(false);
            s1.Setup(s => s.GetProcessID()).Returns((uint)Environment.ProcessId);
            s1.SetupGet(s => s.Volume).Returns(0.5f);
            s1.SetupGet(s => s.Mute).Returns(false);
            s1.Setup(s => s.Dispose()).Callback(() => sessionDisposed++);

            var s2 = new Mock<IAudioSession>();
            s2.SetupGet(s => s.IsSystemSoundsSession).Returns(true);
            s2.Setup(s => s.Dispose()).Callback(() => sessionDisposed++);

            var device = new Mock<IAudioDevice>();
            device.SetupGet(d => d.Id).Returns("dev-1");
            device.SetupGet(d => d.FriendlyName).Returns(() =>
            {
                friendlyReads++;
                return "Speakers (Realtek(R) Audio)";
            });
            device.SetupGet(d => d.DeviceFriendlyName).Returns("Realtek(R) Audio");
            device.SetupGet(d => d.DataFlow).Returns(DataFlow.Render);
            device.SetupGet(d => d.MasterVolumeLevelScalar).Returns(() =>
            {
                volumeReads++;
                return 0.8f;
            });
            device.SetupGet(d => d.Mute).Returns(false);
            device.SetupGet(d => d.Sessions).Returns(new[] { s1.Object, s2.Object });
            device.Setup(d => d.Dispose()).Callback(() => deviceDisposed++);

            var enumerator = new Mock<IAudioDeviceEnumerator>();
            enumerator.Setup(e => e.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
                .Returns(new[] { device.Object });

            var masters = MixerMaster.GetAllMixers(enumerator.Object, DataFlow.Render, DeviceState.Active);

            var master = Assert.Single(masters);
            Assert.Equal("Speakers", master.Title);
            Assert.Equal("Realtek(R) Audio", master.Description);
            Assert.Equal(80, master.Volume);
            Assert.Equal(1, friendlyReads);
            Assert.Equal(1, volumeReads);
            Assert.Equal(1, deviceDisposed);
            Assert.Equal(2, sessionDisposed);

            var ch = Assert.Single(master.Channels!);
            Assert.Equal(Environment.ProcessId, ch.Id);
            Assert.Equal(40, ch.Volume);
        }

        [Fact]
        public void MixerService_FindOne_UsesDirectGetDeviceAndDisposes_BeforeFallback()
        {
            var disposed = false;
            var direct = new Mock<IAudioDevice>();
            direct.SetupGet(d => d.Id).Returns("dev-direct");
            direct.SetupGet(d => d.FriendlyName).Returns("Headphones (USB DAC)");
            direct.SetupGet(d => d.DeviceFriendlyName).Returns("USB DAC");
            direct.SetupGet(d => d.DataFlow).Returns(DataFlow.Render);
            direct.SetupGet(d => d.MasterVolumeLevelScalar).Returns(0.6f);
            direct.SetupGet(d => d.Mute).Returns(true);
            direct.SetupGet(d => d.Sessions).Returns(Array.Empty<IAudioSession>());
            direct.Setup(d => d.Dispose()).Callback(() => disposed = true);

            var enumerator = new Mock<IAudioDeviceEnumerator>();
            enumerator.Setup(e => e.GetDevice("dev-direct")).Returns(direct.Object);

            var service = new MixerService(NullLogger<MixerService>.Instance, enumerator.Object);
            var entity = service.FindOne("dev-direct");

            Assert.NotNull(entity);
            Assert.Equal("dev-direct", entity!.Id);
            Assert.Equal("Headphones", entity.Device.Title);
            Assert.Equal(60, entity.Device.Volume);
            Assert.True(entity.Device.Mute);
            Assert.True(disposed);
            enumerator.Verify(
                e => e.EnumerateAudioEndPoints(It.IsAny<DataFlow>(), It.IsAny<DeviceState>()),
                Times.Never);
        }

        [Fact]
        public void CoreAudioMetadata_ExtractTitle_MatchesExpectedFormatting()
        {
            Assert.Equal("Speakers", CoreAudioMetadata.ExtractTitle("Speakers (Realtek(R) Audio)"));
            Assert.Equal("1 - BenQ EW270Q", CoreAudioMetadata.ExtractTitle("1 - BenQ EW270Q (AMD High Definition Audio Device)"));
            Assert.Equal("Plain Device", CoreAudioMetadata.ExtractTitle("  Plain Device  "));
            Assert.Equal(string.Empty, CoreAudioMetadata.ExtractTitle(null));
            Assert.Equal(string.Empty, CoreAudioMetadata.ExtractTitle(string.Empty));
        }

        [Fact]
        public async Task LiveReadOnly_NAudioMixerService_ConcurrentMtaEnumeration_SucceedsFastWithValidMetadata()
        {
            // Read-only verification against real Windows Core Audio endpoints (no volume/mute mutations).
            var enumerator = new NAudioDeviceEnumerator();
            var service = new MixerService(NullLogger<MixerService>.Instance, enumerator);

            // Warm once (COM/GDI+ first-time init)
            var warmupOut = service.FindAllOutputs();
            var warmupIn = service.FindAllInputs();

            // Concurrent MTA callers simulating rapid simultaneous out + in + refresh polls
            var tasks = Enumerable.Range(0, 8).Select(i => Task.Run(() =>
            {
                long maxMs = 0;
                List<DeckOS.Mixer.MixerEntity> lastList = new();
                for (var iter = 0; iter < 5; iter++)
                {
                    var sw = Stopwatch.StartNew();
                    lastList = i % 2 == 0 ? service.FindAllOutputs() : service.FindAllInputs();
                    sw.Stop();
                    if (sw.ElapsedMilliseconds > maxMs) maxMs = sw.ElapsedMilliseconds;
                }
                return (IsOutput: i % 2 == 0, ElapsedMs: maxMs, Items: lastList);
            })).ToArray();

            var results = await Task.WhenAll(tasks);

            foreach (var r in results)
            {
                Assert.True(r.ElapsedMs < 2000, $"Expected fast live mixer query, got {r.ElapsedMs}ms");
                foreach (var entity in r.Items)
                {
                    Assert.False(string.IsNullOrWhiteSpace(entity.Id));
                    Assert.False(string.IsNullOrWhiteSpace(entity.Device.Title));
                    Assert.InRange(entity.Device.Volume, 0, 100);
                    if (!r.IsOutput)
                    {
                        Assert.Null(entity.Device.Channels);
                    }
                }
            }

            // Confirm single-device FindOne matches active output when present
            if (warmupOut.Count > 0)
            {
                var target = warmupOut[0];
                var single = service.FindOne(target.Id);
                Assert.NotNull(single);
                Assert.Equal(target.Id, single!.Id);
                Assert.Equal(target.Device.Title, single.Device.Title);
            }
            if (warmupIn.Count > 0)
            {
                var target = warmupIn[0];
                var single = service.FindOne(target.Id);
                Assert.NotNull(single);
                Assert.Equal(target.Id, single!.Id);
                Assert.Equal(target.Device.Title, single.Device.Title);
            }
        }
    }
}
#endif
