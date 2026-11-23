using System;
using System.Diagnostics;
using DeckOS.Services;
using Xunit;

namespace DeckOS.Tests;

public class AppForegroundTests
{
    [Fact]
    public void ExecutableIdentity_RequiresFullImagePath_NotNameOrTitle()
    {
        var target = new WindowsAppForeground.Target(@"C:\Apps\Spotify\Spotify.exe", null);
        Assert.True(WindowsAppForeground.Matches(target, @"c:\apps\spotify\SPOTIFY.EXE", null));
        Assert.False(WindowsAppForeground.Matches(target, @"C:\Other\Spotify.exe", null));
        Assert.False(WindowsAppForeground.Matches(target, "Spotify", null));
        Assert.False(WindowsAppForeground.Matches(target, null, null));
    }

    [Fact]
    public void StoreIdentity_RequiresExactAumid_NotSharedHostOrPackageSibling()
    {
        var target = new WindowsAppForeground.Target(null, "Package_123!Spotify");
        Assert.True(WindowsAppForeground.Matches(target, null, "package_123!spotify"));
        Assert.False(WindowsAppForeground.Matches(target, @"C:\Windows\System32\ApplicationFrameHost.exe", null));
        Assert.False(WindowsAppForeground.Matches(target, null, "Package_123!OtherApp"));
        Assert.False(WindowsAppForeground.Matches(target, null, "OtherPackage!Spotify"));
    }

    [Fact]
    public void ShortcutTarget_PreservesExecutableIdentityAndStoreIdentity()
    {
        var shortcut = new AppActivator.ResolvedShortcut(@"C:\Apps\Spotify\Spotify.exe", "--flag", null,
            ProcessWindowStyle.Minimized, false);
        Assert.Equal(new WindowsAppForeground.Target(shortcut.TargetPath, null),
            WindowsAppForeground.ResolveTarget("Spotify.lnk", "--extra", shortcut));
        Assert.Equal(new WindowsAppForeground.Target(null, "Pkg!App"),
            WindowsAppForeground.ResolveTarget("Store.lnk", null, shortcut with { AppUserModelId = "Pkg!App" }));
        Assert.Equal(new WindowsAppForeground.Target(null, "Pkg!App"),
            WindowsAppForeground.ResolveTarget("Store.lnk", null,
                shortcut with { TargetPath = "explorer.exe", Arguments = @"shell:AppsFolder\Pkg!App" }));
    }

    [Fact]
    public void NonApplicationShellTargets_DoNotWaitOrSelectExplorer()
    {
        Assert.Null(WindowsAppForeground.ResolveTarget("https://example.com", null, null));
        Assert.Null(WindowsAppForeground.ResolveTarget(@"C:\Users\file.txt", null, null));
        Assert.Null(WindowsAppForeground.ResolveTarget("Unknown.lnk", null, null));
        Assert.Equal(new WindowsAppForeground.Target(null, "Pkg!App"),
            WindowsAppForeground.ResolveTarget("explorer.exe", @"shell:AppsFolder\Pkg!App --flag", null));
    }

    private sealed class Windows : WindowsAppForeground.IWindows
    {
        public Func<int, IntPtr> FindWindow = _ => new IntPtr(101);
        public Func<int, bool> Activation = _ => true;
        public int Finds, Activations, WaitMs;
        public IntPtr LastActivated;
        public IntPtr Find(WindowsAppForeground.Target target) => FindWindow(++Finds);
        public bool Activate(IntPtr window) { LastActivated = window; return Activation(++Activations); }
        public void Delay(int ms) => WaitMs += ms;
    }

    [Fact]
    public void ExistingSingleInstanceWindow_ActivatesImmediatelyWithoutLauncherPidOrDelay()
    {
        var windows = new Windows();
        Assert.True(WindowsAppForeground.Restore(new(@"C:\Spotify.exe", null), windows, windows.Delay));
        Assert.Equal(new IntPtr(101), windows.LastActivated);
        Assert.Equal(1, windows.Activations);
        Assert.Equal(0, windows.WaitMs);
    }

    [Fact]
    public void ColdWindowAndAsynchronousRestore_RetryUntilActuallyForeground()
    {
        var windows = new Windows
        {
            FindWindow = attempt => attempt < 4 ? IntPtr.Zero : new IntPtr(202),
            Activation = attempt => attempt == 2,
        };
        Assert.True(WindowsAppForeground.Restore(new(null, "Pkg!App"), windows, windows.Delay));
        Assert.Equal(5, windows.Finds);
        Assert.Equal(2, windows.Activations);
        Assert.Equal(200, windows.WaitMs);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void MissingWindowOrDeniedForeground_StopsAtBoundedDeadline(bool exists)
    {
        var windows = new Windows { FindWindow = _ => exists ? new IntPtr(303) : IntPtr.Zero, Activation = _ => false };
        Assert.False(WindowsAppForeground.Restore(new(@"C:\App.exe", null), windows, windows.Delay));
        Assert.Equal(41, windows.Finds);
        Assert.Equal(exists ? 41 : 0, windows.Activations);
        Assert.Equal(2000, windows.WaitMs);
    }
}
