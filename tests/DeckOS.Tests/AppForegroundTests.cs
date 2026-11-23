using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using DeckOS.Services;
using Xunit;
using W = DeckOS.Services.WindowsAppForeground;

namespace DeckOS.Tests;

public class AppForegroundTests
{
    [Fact]
    public void ExecutableIdentity_RequiresFullImagePath_NotNameOrTitle()
    {
        var target = new W.Target(@"C:\Apps\Spotify\Spotify.exe", null);
        Assert.True(W.Matches(target, @"c:\apps\spotify\SPOTIFY.EXE", null));
        Assert.False(W.Matches(target, @"C:\Other\Spotify.exe", null));
        Assert.False(W.Matches(target, "Spotify", null));
        Assert.False(W.Matches(target, null, null));
    }

    [Fact]
    public void StoreIdentity_RequiresExactAumid_NotSharedHostOrPackageSibling()
    {
        var target = new W.Target(null, "Package_123!Spotify");
        Assert.True(W.Matches(target, null, "package_123!spotify"));
        Assert.False(W.Matches(target, @"C:\Windows\System32\ApplicationFrameHost.exe", null));
        Assert.False(W.Matches(target, null, "Package_123!OtherApp"));
        Assert.False(W.Matches(target, null, "OtherPackage!Spotify"));
    }

    [Fact]
    public void ShortcutTarget_PreservesExecutableIdentityAndStoreIdentity()
    {
        var shortcut = new AppActivator.ResolvedShortcut(@"C:\Apps\Spotify\Spotify.exe", "--flag", null,
            ProcessWindowStyle.Minimized, false);
        Assert.Equal(new W.Target(shortcut.TargetPath, null), W.ResolveTarget("Spotify.lnk", "--extra", shortcut));
        Assert.Equal(new W.Target(null, "Pkg!App"),
            W.ResolveTarget("Store.lnk", null, shortcut with { AppUserModelId = "Pkg!App" }));
        Assert.Equal(new W.Target(null, "Pkg!App"),
            W.ResolveTarget("Store.lnk", null, shortcut with { TargetPath = "explorer.exe", Arguments = @"shell:AppsFolder\Pkg!App" }));
        // Desktop apps' explicit AUMIDs (Firefox hash, Electron reverse-DNS, a path) keep exe identity.
        Assert.Equal(new W.Target(shortcut.TargetPath, null),
            W.ResolveTarget("Zen.lnk", null, shortcut with { AppUserModelId = "F0DC299D809B9700" }));
    }

    [Fact]
    public void NonApplicationShellTargets_DoNotWaitOrSelectExplorer()
    {
        Assert.Null(W.ResolveTarget("https://example.com", null, null));
        Assert.Null(W.ResolveTarget(@"C:\Users\file.txt", null, null));
        Assert.Null(W.ResolveTarget("Unknown.lnk", null, null));
        Assert.Equal(new W.Target(null, "Pkg!App"), W.ResolveTarget("explorer.exe", @"shell:AppsFolder\Pkg!App --flag", null));
    }

    [Fact]
    public void InstallRoot_IsTheAppFolder_ButNeverTheSharedWindowsFolder()
    {
        Assert.Equal(@"C:\Users\u\AppData\Local\Gemini", W.InstallRoot(@"C:\Users\u\AppData\Local\Gemini\Gemini.exe"));
        Assert.True(W.IsUnder(@"C:\Users\u\AppData\Local\Gemini\app-1.21.1\Gemini.exe", @"C:\Users\u\AppData\Local\Gemini"));
        Assert.False(W.IsUnder(@"C:\Users\u\AppData\Local\GeminiOther\x.exe", @"C:\Users\u\AppData\Local\Gemini"));
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (windows.Length > 0)
        {
            Assert.Null(W.InstallRoot(Path.Combine(windows, "System32", "cmd.exe")));
            Assert.Null(W.InstallRoot(Path.Combine(windows, "explorer.exe")));
        }
    }

    // Real window metadata captured on the user's PC (Tauri, Firefox, Electron, shell).
    [Theory]
    [InlineData(0x40110L, true, false, true, true)]       // Tauri main window
    [InlineData(0x100L, true, false, true, true)]         // Firefox / Chromium main window
    [InlineData(0x80800A0L, true, false, true, false)]    // Tao Thread Event Target: tool + no-activate
    [InlineData(0x88L, true, false, true, false)]         // Shell_TrayWnd: tool window
    [InlineData(0x200080L, true, false, false, false)]    // XAML island: tool, zero size
    [InlineData(0x100L, false, false, true, false)]       // MozillaHiddenWindowClass: has caption, hidden
    [InlineData(0x100L, true, true, true, false)]         // MozillaDropShadowWindowClass: owned popup
    [InlineData(0x40100L, true, true, true, true)]        // owned but explicitly an app window
    public void UserFacingWindows_FollowAltTabRules(long exStyle, bool visible, bool owned, bool hasArea, bool expected)
    {
        var w = new W.Window(new IntPtr(1), 1, visible, false, false, owned, exStyle, hasArea);
        Assert.Equal(expected, W.IsUserFacing(w));
        Assert.False(W.IsUserFacing(w with { Cloaked = true }));
    }

    private const string App = @"C:\Apps\Tool\Tool.exe";
    private static readonly IntPtr Active = new(900);

    /// <summary>
    /// Desktop model of what was measured: while the user is active, SetForegroundWindow (direct or
    /// with joined input) is refused for DeckOS, a SW_RESTORE of a minimized window is honored, and
    /// the foreground process may activate its own new windows.
    /// </summary>
    private sealed class Desktop : W.IWindows
    {
        public sealed class Win
        {
            public IntPtr Handle; public uint Pid; public bool Visible = true, Min, Owned; public long Ex = 0x100; public bool Area = true;
            public uint Hosted; public string? AppId;
        }
        public readonly List<Win> Z = new();
        public readonly Dictionary<uint, (string? Image, string? Aumid, long Created, uint Parent)> Procs = new();
        public readonly HashSet<uint> Exited = new();
        public readonly List<string> Calls = new();
        public readonly List<(long At, Action Do)> Events = new();
        public IntPtr Fg = Active;
        public bool ForegroundLock = true;
        public Action<Win>? OnMinimized;
        public long Ms, Utc = 1000;

        public Desktop()
        {
            Add(Active, 1, @"C:\Other\Editor.exe");
            Procs[1] = (@"C:\Other\Editor.exe", null, 10, 0);
        }

        public Win Add(IntPtr handle, uint pid, string? image = null, bool top = false)
        {
            var w = new Win { Handle = handle, Pid = pid };
            if (top) Z.Insert(0, w); else Z.Add(w);
            if (image != null && !Procs.ContainsKey(pid)) Procs[pid] = (image, null, 10, 0);
            return w;
        }

        public Win Get(int handle) => Z.Single(w => w.Handle == new IntPtr(handle));
        public void Activate(Win w) { Z.Remove(w); Z.Insert(0, w); Fg = w.Handle; }
        public void At(long ms, Action action) => Events.Add((ms, action));

        public IReadOnlyList<W.Window> Snapshot(bool readAppIds) =>
            Z.Select(w => new W.Window(w.Handle, w.Pid, w.Visible, w.Min, false, w.Owned, w.Ex, w.Area, w.Hosted, w.AppId)).ToList();
        public IReadOnlyList<W.ProcessEntry> Processes() =>
            Procs.Where(p => !Exited.Contains(p.Key)).Select(p => new W.ProcessEntry(p.Key, p.Value.Parent)).ToList();
        public W.ProcessIdentity Identity(uint pid) =>
            Procs.TryGetValue(pid, out var p) ? new(p.Image, p.Aumid, p.Created) : new(null, null, long.MinValue);
        public IntPtr Foreground() => Fg;
        public bool SetForeground(IntPtr window, bool attachInput, out string detail)
        {
            Calls.Add($"{(attachInput ? "attach" : "set")}:{window}");
            detail = ForegroundLock ? "denied" : "set";
            if (!ForegroundLock) Activate(Z.Single(w => w.Handle == window));
            return Fg == window;
        }
        public readonly HashSet<IntPtr> Protected = new(); // e.g. elevated: ShowWindowAsync fails
        public bool Show(IntPtr window, int command)
        {
            Calls.Add($"show{command}:{window}");
            if (Protected.Contains(window)) return false;
            var w = Z.Single(x => x.Handle == window);
            if (command == W.SW_SHOWMINNOACTIVE) { w.Min = true; OnMinimized?.Invoke(w); }
            else if (command == W.SW_RESTORE && w.Min) { w.Min = false; w.Visible = true; Activate(w); }
            else if (command == W.SW_RESTORE && !w.Visible) w.Visible = true;
            return true;
        }
        public long ElapsedMs => Ms;
        public long UtcNow => Utc + Ms;
        public void Delay(int ms)
        {
            Ms += ms;
            foreach (var e in Events.Where(e => e.At <= Ms).ToList()) { Events.Remove(e); e.Do(); }
        }
    }

    private static W.Result Run(Desktop desktop, W.Target target, uint launchedPid = 0, Func<bool>? superseded = null)
    {
        var session = new W.Session(target, desktop) { Superseded = superseded ?? (() => false) };
        session.Launched(launchedPid);
        return session.Run();
    }

    [Fact]
    public void VisibleWindowBehindActiveApp_IsMinimizedWithoutActivationAndRestoredOnce()
    {
        // EasyCLIProxyAPI case: running window behind a maximized app, foreground refused.
        var d = new Desktop();
        d.Add(new IntPtr(10), 5, App).Ex = 0x40110;
        d.Add(new IntPtr(11), 5).Ex = 0x80800A0; // Tao event target, visible but not activatable
        d.Procs[6] = (App, null, d.UtcNow + 1, 0); // second instance hands off and exits
        d.At(200, () => d.Exited.Add(6));

        var result = Run(d, new(App, null), 6);

        Assert.Equal("foreground", result.Outcome);
        Assert.Equal(new IntPtr(10), d.Fg);
        Assert.Equal(1, d.Calls.Count(c => c == "show7:10"));
        Assert.Equal(1, d.Calls.Count(c => c == "show9:10"));
        Assert.DoesNotContain(d.Calls, c => c.EndsWith(":11") || c.EndsWith(":900"));
        Assert.True(d.Calls.IndexOf("set:10") < d.Calls.IndexOf("attach:10"));
        Assert.True(d.Calls.IndexOf("show5:10") < d.Calls.IndexOf("show7:10"));
        Assert.Contains("refused", result.Steps);
        Assert.Contains("cycle@", result.Steps);
    }

    [Fact]
    public void WindowProtectedFromDeckOS_ReportsDenialHonestly()
    {
        var d = new Desktop();
        d.Add(new IntPtr(10), 5, App);
        d.Protected.Add(new IntPtr(10));
        var result = Run(d, new(App, null));
        Assert.Equal("refused", result.Outcome);
        Assert.Contains("cycle-denied", result.Steps);
        Assert.DoesNotContain("show9:10", d.Calls);
        Assert.Equal(Active, d.Fg);
    }

    [Fact]
    public void WhenWindowsAllowsActivation_NoMinimizeCycleHappens()
    {
        var d = new Desktop { ForegroundLock = false };
        d.Add(new IntPtr(10), 5, App);
        var result = Run(d, new(App, null));
        Assert.Equal("foreground", result.Outcome);
        Assert.DoesNotContain(d.Calls, c => c.StartsWith("show"));
    }

    [Fact]
    public void MinimizedWindow_IsRestoredOnce_WithoutForcedCycle()
    {
        var d = new Desktop();
        d.Add(new IntPtr(10), 5, App).Min = true;
        var result = Run(d, new(App, null));
        Assert.Equal("foreground", result.Outcome);
        Assert.Equal(new[] { "show9:10" }, d.Calls);
        Assert.False(d.Get(10).Min);
    }

    [Fact]
    public void HiddenOwnedToolAndEmptyHelperWindows_AreNeverShownOrActivated()
    {
        // Firefox/Tauri helper windows of a running app whose relaunch shows nothing.
        var d = new Desktop();
        d.Add(new IntPtr(20), 5, App).Visible = false;                 // hidden captioned helper
        d.Add(new IntPtr(21), 5).Owned = true;                          // drop shadow popup
        d.Add(new IntPtr(22), 5).Ex = 0x80800A0;                        // event target
        d.Add(new IntPtr(23), 5).Area = false;                          // zero-size visible
        d.Procs[6] = (App, null, d.UtcNow + 1, 0);
        d.At(150, () => d.Exited.Add(6));

        var result = Run(d, new(App, null), 6);

        Assert.Equal("no-visible-window", result.Outcome);
        Assert.Empty(d.Calls);
        Assert.Equal(Active, d.Fg);
        Assert.InRange(result.ElapsedMs, W.Session.ExitedLaunchMs, W.Session.ExitedLaunchMs + 200);
    }

    [Fact]
    public void ColdLauncherStub_UiChildInSameInstallTree_IsFoundAfterFourSeconds()
    {
        const string stub = @"C:\Apps\Gem\Gem.exe", ui = @"C:\Apps\Gem\app-1.2\Gem.exe";
        var d = new Desktop();
        d.Add(new IntPtr(30), 50, @"C:\Elsewhere\Gem.exe");            // same file name, other app
        d.Procs[100] = (stub, null, d.UtcNow + 1, 0);
        d.At(100, () => d.Procs[101] = (ui, null, d.UtcNow, 100));
        d.At(250, () => d.Exited.Add(100));
        d.At(6000, () => d.Add(new IntPtr(31), 101));                   // slow first frame, appears behind

        var result = Run(d, new(stub, null), 100);

        Assert.Equal("foreground", result.Outcome);
        Assert.Equal(new IntPtr(31), d.Fg);
        Assert.DoesNotContain(d.Calls, c => c.EndsWith(":30"));
        Assert.Contains("child-image", result.Steps);
    }

    [Fact]
    public void WarmLauncherStub_HandsOffToRunningUiProcess_FromSameInstallTree()
    {
        const string stub = @"C:\Apps\Gem\Gem.exe", ui = @"C:\Apps\Gem\app-1.2\Gem.exe";
        var d = new Desktop();
        d.Add(new IntPtr(40), 60, ui);                                 // running UI, behind
        d.Procs[100] = (stub, null, d.UtcNow + 1, 0);
        d.At(50, () => d.Procs[101] = (ui, null, d.UtcNow, 100));      // forwards to pid 60 and exits
        d.At(300, () => { d.Exited.Add(100); d.Exited.Add(101); });

        var result = Run(d, new(stub, null), 100);

        Assert.Equal("foreground", result.Outcome);
        Assert.Equal(new IntPtr(40), d.Fg);
    }

    [Fact]
    public void SystemFolderTarget_DoesNotAdoptOtherInstancesOfItsChildren()
    {
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (windows.Length == 0) return;
        var cmd = Path.Combine(windows, "System32", "cmd.exe");
        var host = Path.Combine(windows, "System32", "conhost.exe");
        var d = new Desktop();
        d.Add(new IntPtr(50), 70, host);                               // someone else's console
        d.Procs[100] = (cmd, null, d.UtcNow + 1, 0);
        d.At(100, () => d.Procs[101] = (host, null, d.UtcNow, 100));
        d.At(700, () => d.Add(new IntPtr(51), 101));

        var result = Run(d, new(cmd, null), 100);

        Assert.Equal(new IntPtr(51), d.Fg);
        Assert.DoesNotContain(d.Calls, c => c.EndsWith(":50"));
        Assert.DoesNotContain("child-image", result.Steps);
    }

    [Fact]
    public void RecycledParentPid_OlderProcessIsNotAdopted()
    {
        var d = new Desktop();
        d.Procs[100] = (App, null, d.UtcNow + 1, 0);
        d.Procs[80] = (@"C:\Unrelated\Old.exe", null, 5, 100);         // started long before the launch
        d.Add(new IntPtr(60), 80);
        d.At(100, () => d.Exited.Add(100));

        var result = Run(d, new(App, null), 100);

        Assert.Equal("no-visible-window", result.Outcome);
        Assert.Empty(d.Calls);
    }

    [Fact]
    public void SingleInstanceHandOff_TransientHelperFocus_ThenAppOwnNewWindowWins()
    {
        // Zen trace: minimized window restored, hidden remote window briefly focused, new window opened.
        var d = new Desktop();
        d.Add(new IntPtr(70), 60, App).Min = true;
        var remote = d.Add(new IntPtr(71), 60);
        remote.Visible = false;
        d.Procs[100] = (App, null, d.UtcNow + 1, 0);
        d.At(150, () => d.Fg = remote.Handle);
        d.At(400, () => d.Exited.Add(100));
        d.At(1400, () => d.Activate(d.Add(new IntPtr(72), 60, top: true)));

        var result = Run(d, new(App, null), 100);

        Assert.Equal("foreground", result.Outcome);
        Assert.Equal(new IntPtr(72), result.Window);
        Assert.Equal(new[] { "show9:70" }, d.Calls);
    }

    [Fact]
    public void SingleInstanceHandOff_NewWindowLeftBehind_IsRaised()
    {
        var d = new Desktop();
        d.Add(new IntPtr(70), 60, App);
        d.Procs[100] = (App, null, d.UtcNow + 1, 0);
        d.At(300, () => d.Exited.Add(100));
        d.At(1200, () => d.Add(new IntPtr(72), 60));                   // created without activation

        var result = Run(d, new(App, null), 100);

        Assert.Equal(new IntPtr(72), d.Fg);
        Assert.Equal("foreground", result.Outcome);
        Assert.Contains("show9:72", d.Calls);
    }

    [Fact]
    public void AppThatHidesWhenMinimized_GetsItsWindowBack()
    {
        var d = new Desktop { OnMinimized = w => w.Visible = false };
        d.Add(new IntPtr(10), 5, App);
        var result = Run(d, new(App, null));
        Assert.True(d.Get(10).Visible);
        Assert.Equal("foreground", result.Outcome);
    }

    [Fact]
    public void UserSwitchesElsewhereBeforeColdWindow_NothingIsStolen()
    {
        var d = new Desktop();
        d.Add(new IntPtr(80), 2, @"C:\Other\Browser.exe");
        d.Procs[100] = (App, null, d.UtcNow + 1, 0);
        d.At(1000, () => d.Activate(d.Get(80)));
        d.At(3000, () => d.Add(new IntPtr(81), 100));

        var result = Run(d, new(App, null), 100);

        Assert.Equal("user-switched", result.Outcome);
        Assert.Empty(d.Calls);
        Assert.Equal(new IntPtr(80), d.Fg);
    }

    [Fact]
    public void FocusLostAfterVerification_IsNotFoughtBack()
    {
        var d = new Desktop();
        d.Add(new IntPtr(10), 5, App).Min = true;
        d.At(500, () => d.Activate(d.Get(900)));
        var result = Run(d, new(App, null));
        Assert.Equal("lost", result.Outcome);
        Assert.Single(d.Calls);
    }

    [Fact]
    public void NewerLaunch_SupersedesPendingActivation()
    {
        var d = new Desktop();
        var stop = false;
        d.At(100, () => stop = true);
        d.At(3000, () => d.Add(new IntPtr(10), 5, App));
        Assert.Equal("superseded", Run(d, new(App, null), superseded: () => stop).Outcome);
        Assert.Empty(d.Calls);
    }

    [Fact]
    public void StoreFrame_MatchesHostedAppProcessAumid_NotTheSharedFrameHost()
    {
        var d = new Desktop();
        d.Procs[90] = (@"C:\Program Files\WindowsApps\Pkg\App.exe", "Pkg!App", 5, 0);
        d.Procs[91] = (@"C:\Program Files\WindowsApps\Other\Other.exe", "Other!App", 5, 0);
        d.Add(new IntPtr(95), 8, @"C:\Windows\System32\ApplicationFrameHost.exe").Hosted = 91;
        d.Add(new IntPtr(96), 8).Hosted = 90;

        var result = Run(d, new(null, "Pkg!App"));

        Assert.Equal(new IntPtr(96), d.Fg);
        Assert.Equal("foreground", result.Outcome);
        Assert.DoesNotContain(d.Calls, c => c.EndsWith(":95"));
    }

    // Real Win32 windows: the native snapshot must report the metadata the rules depend on.
    [Fact]
    [Trait("Category", "RequiresDesktop")]
    public void NativeSnapshot_ClassifiesRealWindows()
    {
        if (!OperatingSystem.IsWindows()) return;
        const uint visible = 0x10000000, popup = 0x80000000, overlapped = 0x00CF0000;
        var created = new List<IntPtr>();
        IntPtr Make(uint ex, uint style, int size, IntPtr owner = default)
        {
            var h = CreateWindowEx(ex, "STATIC", null, style, 100, 100, size, size, owner, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            Assert.NotEqual(IntPtr.Zero, h);
            created.Add(h);
            return h;
        }
        try
        {
            var main = Make(0x100, overlapped | visible, 200);
            var tool = Make(0x80, overlapped | visible, 200);
            var eventTarget = Make(0x80800A0, popup | visible, 26);
            var hidden = Make(0x100, overlapped, 200);
            var owned = Make(0, popup | visible, 50, main);
            var empty = Make(0, popup | visible, 0);

            var native = new W.NativeWindows();
            var mine = native.Snapshot(false).Where(w => created.Contains(w.Handle)).ToDictionary(w => w.Handle);
            Assert.Equal(6, mine.Count);
            Assert.True(W.IsUserFacing(mine[main]));
            foreach (var other in new[] { tool, eventTarget, hidden, owned, empty })
                Assert.False(W.IsUserFacing(mine[other]));
            Assert.All(mine.Values, w => Assert.Equal((uint)Environment.ProcessId, w.ProcessId));

            var self = native.Identity((uint)Environment.ProcessId);
            Assert.Equal(Environment.ProcessPath, self.Image, StringComparer.OrdinalIgnoreCase);
            Assert.True(self.CreatedUtc < DateTime.UtcNow.ToFileTimeUtc());
            Assert.Contains(native.Processes(), p => p.Id == Environment.ProcessId && p.ParentId != 0);
        }
        finally
        {
            foreach (var h in created) DestroyWindow(h);
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(uint ex, string cls, string? name, uint style, int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] private static extern bool DestroyWindow(IntPtr window);
}
