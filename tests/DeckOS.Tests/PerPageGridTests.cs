using System;
using System.IO;
using DeckOS.Models;
using DeckOS.Services;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace DeckOS.Tests
{
    public class PerPageGridTests : IDisposable
    {
        private readonly string _dir = Path.Combine(
            Path.GetTempPath(),
            "deckos-page-grid-test-" + Guid.NewGuid().ToString("N"));

        public void Dispose()
        {
            if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
        }

        private StreamDeckConfigService CreateService() =>
            new(NullLogger<StreamDeckConfigService>.Instance, _dir);

        [Fact]
        public void CustomGrid_PersistsAcrossRestart_IsolatedPerProfile_AndCanResetToInherit()
        {
            var svc = CreateService();
            var pageA = new DeckProfile
            {
                Id = "page_a",
                Name = "Media",
                Rows = 2,
                Columns = 4,
                CustomRows = 3,
                CustomColumns = 2,
            };
            var pageB = new DeckProfile
            {
                Id = "page_b",
                Name = "Default",
                Rows = 2,
                Columns = 4,
            };

            svc.SaveProfile(pageA);
            svc.SaveProfile(pageB);

            // Simulate full server restart from disk.
            var reloaded = CreateService();
            var a = reloaded.GetProfile("page_a");
            var b = reloaded.GetProfile("page_b");

            Assert.NotNull(a);
            Assert.NotNull(b);
            Assert.Equal(3, a!.CustomRows);
            Assert.Equal(2, a.CustomColumns);
            Assert.Null(b!.CustomRows);
            Assert.Null(b.CustomColumns);

            // Resetting page A to inherit global clears both override fields cleanly.
            a.CustomRows = null;
            a.CustomColumns = null;
            reloaded.SaveProfile(a);

            var afterReset = CreateService().GetProfile("page_a");
            Assert.NotNull(afterReset);
            Assert.Null(afterReset!.CustomRows);
            Assert.Null(afterReset.CustomColumns);
        }

        [Fact]
        public void CustomGrid_ClampsValidRange_AndClearsIncompleteOrInvalidValues()
        {
            var svc = CreateService();

            var clamped = new DeckProfile
            {
                Id = "clamped",
                Name = "Clamped",
                CustomRows = 99,
                CustomColumns = 25,
            };
            svc.SaveProfile(clamped);
            var loadedClamped = CreateService().GetProfile("clamped");
            Assert.Equal(20, loadedClamped!.CustomRows);
            Assert.Equal(20, loadedClamped.CustomColumns);

            var halfSet = new DeckProfile
            {
                Id = "half_set",
                Name = "Half",
                CustomRows = 3,
                CustomColumns = null,
            };
            svc.SaveProfile(halfSet);
            var loadedHalf = CreateService().GetProfile("half_set");
            Assert.Null(loadedHalf!.CustomRows);
            Assert.Null(loadedHalf.CustomColumns);

            var zeroed = new DeckProfile
            {
                Id = "zeroed",
                Name = "Zeroed",
                CustomRows = 0,
                CustomColumns = 4,
            };
            svc.SaveProfile(zeroed);
            var loadedZero = CreateService().GetProfile("zeroed");
            Assert.Null(loadedZero!.CustomRows);
            Assert.Null(loadedZero.CustomColumns);
        }

        [Fact]
        public void RemoteSave_ReflowAndCustomGridOverride_AllowedForExistingPrivilegedButtons()
        {
            var saved = new DeckProfile
            {
                Id = "kbd",
                Name = "Keyboard",
                Buttons =
                {
                    new DeckButton
                    {
                        Id = "btn_esc",
                        Row = 0,
                        Column = 4,
                        Label = "ESC",
                        Action = new DeckAction { Type = "key", Parameters = new() { ["key"] = "ESC" } },
                    },
                },
            };

            var incoming = new DeckProfile
            {
                Id = "kbd",
                Name = "Keyboard",
                CustomRows = 3,
                CustomColumns = 3,
                Buttons =
                {
                    new DeckButton
                    {
                        Id = "btn_esc",
                        Row = 1,
                        Column = 1,
                        Label = "ESC",
                        Action = new DeckAction { Type = "key", Parameters = new() { ["key"] = "ESC" } },
                    },
                },
            };

            Assert.Null(ActionPolicy.FindRemoteViolation(incoming, saved));
        }
    }
}
