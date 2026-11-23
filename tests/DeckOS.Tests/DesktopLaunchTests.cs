using System;
using DeckOS.Platform;
using DeckOS.Platform.Linux;
using Xunit;

namespace DeckOS.Tests;

public class DesktopLaunchTests
{
    [Fact]
    public void DesktopFallbackHonorsWorkingDirectoryAndTerminalWithoutAShell()
    {
        var entry = DesktopEntry.Parse("[Desktop Entry]\nType=Application\nName=Example\nExec=tool --flag\nTerminal=true\nPath=/home/test/work dir\n");
        var info = LinuxAppActivator.DesktopLaunchInfo(entry, entry.ExecArgs(), t => t is "tool" or "gnome-terminal" ? "/usr/bin/" + t : null);
        Assert.Equal("/usr/bin/gnome-terminal", info.FileName);
        Assert.Equal(new[] { "--", "/usr/bin/tool", "--flag" }, info.ArgumentList);
        Assert.Equal("/home/test/work dir", info.WorkingDirectory);
        Assert.False(info.UseShellExecute);
        Assert.Throws<PlatformFeatureException>(() => LinuxAppActivator.DesktopLaunchInfo(entry, entry.ExecArgs(), _ => null));
    }
}
