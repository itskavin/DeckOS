using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using DeckOS.Lib;
using DeckOS.Lib.Input;
using DeckOS.Platform;
using DeckOS.Platform.Linux;
using DeckOS.Platform.MacOS;
using Xunit;

namespace DeckOS.Tests
{
    /// <summary>Leitura de .desktop e busca de icone no tema (Linux).</summary>
    public class DesktopEntryTests
    {
        private const string Firefox = """
            [Desktop Entry]
            # comentario
            Version=1.0
            Type=Application
            Name=Firefox Web Browser
            Name[pt_BR]=Navegador Firefox
            Name[pt]=Firefox (pt)
            Exec=firefox %u
            Icon=firefox
            Categories=Network;WebBrowser;

            [Desktop Action new-window]
            Name=New Window
            Exec=firefox --new-window %u
            """;

        [Fact]
        public void Le_ChavesDoGrupoPrincipal_SemOsDasAcoes()
        {
            var e = DesktopEntry.Parse(Firefox);
            Assert.Equal("Application", e.Type);
            Assert.Equal("firefox %u", e.Exec);
            Assert.Equal("firefox", e.Icon);
            Assert.Equal("Firefox Web Browser", e.Name());
            Assert.True(e.IsVisibleApplication());
        }

        [Theory]
        [InlineData("pt_BR.UTF-8", "Navegador Firefox")]
        [InlineData("pt_PT", "Firefox (pt)")]
        [InlineData("de_DE", "Firefox Web Browser")]
        [InlineData(null, "Firefox Web Browser")]
        public void Name_PrefereOIdiomaMaisEspecifico(string? locale, string expected) =>
            Assert.Equal(expected, DesktopEntry.Parse(Firefox).Name(locale));

        [Fact]
        public void ExecArgs_TiraCodigosDeCampo()
        {
            Assert.Equal(new[] { "firefox" }, DesktopEntry.Parse(Firefox).ExecArgs());
        }

        [Fact]
        public void ExecArgs_AspasEEscapes()
        {
            var e = DesktopEntry.Parse("[Desktop Entry]\nType=Application\nName=X\n" +
                @"Exec=""/opt/My App/bin/app"" --title ""a \""b\"""" --pct=100%% %F");
            Assert.Equal(new[] { "/opt/My App/bin/app", "--title", "a \"b\"", "--pct=100%" }, e.ExecArgs());
        }

        [Fact]
        public void ValorComEscapesDeString()
        {
            var e = DesktopEntry.Parse("[Desktop Entry]\nName=Um\\sdois\\\\tres\n");
            Assert.Equal(@"Um dois\tres", e.Name());
        }

        [Theory]
        [InlineData("Type=Application\nName=X\nExec=x\nNoDisplay=true", null, false)]
        [InlineData("Type=Application\nName=X\nExec=x\nHidden=true", null, false)]
        [InlineData("Type=Link\nName=X\nURL=https://x", null, false)]
        [InlineData("Type=Application\nName=X", null, false)]
        [InlineData("Type=Application\nName=X\nExec=x\nOnlyShowIn=KDE;", "GNOME", false)]
        [InlineData("Type=Application\nName=X\nExec=x\nOnlyShowIn=KDE;", "ubuntu:GNOME", false)]
        [InlineData("Type=Application\nName=X\nExec=x\nOnlyShowIn=GNOME;", "ubuntu:GNOME", true)]
        [InlineData("Type=Application\nName=X\nExec=x\nNotShowIn=GNOME;", "GNOME", false)]
        [InlineData("Type=Application\nName=X\nExec=x", "GNOME", true)]
        public void IsVisibleApplication(string body, string? desktop, bool expected) =>
            Assert.Equal(expected, DesktopEntry.Parse("[Desktop Entry]\n" + body).IsVisibleApplication(desktop));

        [Fact]
        public void ApplicationDirs_UsuarioPrimeiro_EFlatpakSnap()
        {
            var env = new Dictionary<string, string?> { ["XDG_DATA_DIRS"] = "/usr/share:/opt/share" };
            var dirs = DesktopEntry.ApplicationDirs(k => env.GetValueOrDefault(k), "/home/ana");
            Assert.Equal(Path.Combine("/home/ana", ".local", "share", "applications"), dirs[0]);
            Assert.Contains(Path.Combine("/usr/share", "applications"), dirs);
            Assert.Contains(Path.Combine("/opt/share", "applications"), dirs);
            Assert.Contains("/var/lib/flatpak/exports/share/applications", dirs);
            Assert.Contains("/var/lib/snapd/desktop/applications", dirs);
        }
    }

    public class IconResolverTests : IDisposable
    {
        private readonly string _root = Path.Combine(Path.GetTempPath(), "deckos-icons-" + Guid.NewGuid().ToString("N"));

        public void Dispose() { try { Directory.Delete(_root, true); } catch { } }

        private string Touch(params string[] parts)
        {
            var path = Path.Combine(new[] { _root }.Concat(parts).ToArray());
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(path, "x");
            return path;
        }

        [Fact]
        public void PrefereOPngGrandeDoHicolor()
        {
            Touch("icons", "hicolor", "48x48", "apps", "foo.png");
            var big = Touch("icons", "hicolor", "256x256", "apps", "foo.png");
            Touch("icons", "Adwaita", "512x512", "apps", "foo.png");
            Assert.Equal(big, IconResolver.Find("foo", new[] { Path.Combine(_root, "icons") }, Array.Empty<string>()));
        }

        [Fact]
        public void UsaOSvgQuandoNaoHaPngGrande_EOutroTemaSeOHicolorNaoTem()
        {
            Touch("icons", "hicolor", "32x32", "apps", "foo.png");
            var svg = Touch("icons", "hicolor", "scalable", "apps", "foo.svg");
            var other = Touch("icons", "Papirus", "128x128", "apps", "bar.png");
            var roots = new[] { Path.Combine(_root, "icons") };
            Assert.Equal(svg, IconResolver.Find("foo", roots, Array.Empty<string>()));
            Assert.Equal(other, IconResolver.Find("bar", roots, Array.Empty<string>()));
        }

        [Fact]
        public void PixmapsCaminhoAbsolutoEExtensaoNoNome()
        {
            var pix = Touch("pixmaps", "baz.png");
            var xpm = Touch("pixmaps", "old.xpm");
            var pixmaps = new[] { Path.Combine(_root, "pixmaps") };
            Assert.Equal(pix, IconResolver.Find("baz", Array.Empty<string>(), pixmaps));
            Assert.Equal(pix, IconResolver.Find("baz.png", Array.Empty<string>(), pixmaps));
            Assert.Equal(pix, IconResolver.Find(pix, Array.Empty<string>(), Array.Empty<string>()));
            // XPM o navegador nao mostra.
            Assert.Null(IconResolver.Find(xpm, Array.Empty<string>(), Array.Empty<string>()));
            Assert.Null(IconResolver.Find("nao-existe", new[] { Path.Combine(_root, "icons") }, pixmaps));
        }
    }

    /// <summary>Info.plist e icone de um .app (macOS).</summary>
    public class PlistTests : IDisposable
    {
        private readonly string _root = Path.Combine(Path.GetTempPath(), "deckos-app-" + Guid.NewGuid().ToString("N"));

        public void Dispose() { try { Directory.Delete(_root, true); } catch { } }

        private const string Xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleDisplayName</key>
                <string>Visual Studio Code</string>
                <key>CFBundleIconFile</key>
                <string>Code</string>
                <key>CFBundleDocumentTypes</key>
                <array><dict><key>CFBundleTypeName</key><string>ignorado</string></dict></array>
                <key>LSBackgroundOnly</key>
                <false/>
                <key>CFBundleVersion</key>
                <integer>42</integer>
            </dict>
            </plist>
            """;

        [Fact]
        public void ParseXml_ChavesDeCima_SemBuscarODtd()
        {
            var d = Plist.ParseXml(Xml);
            Assert.Equal("Visual Studio Code", d["CFBundleDisplayName"]);
            Assert.Equal("Code", d["CFBundleIconFile"]);
            Assert.Equal("false", d["LSBackgroundOnly"]);
            Assert.Equal("42", d["CFBundleVersion"]);
            Assert.False(d.ContainsKey("CFBundleTypeName"));
        }

        private string App(string name, params string[] resources)
        {
            var app = Path.Combine(_root, name + ".app");
            var res = Path.Combine(app, "Contents", "Resources");
            Directory.CreateDirectory(res);
            foreach (var r in resources) File.WriteAllText(Path.Combine(res, r), "x");
            return app;
        }

        [Fact]
        public void IconPath_IconFileSemExtensao()
        {
            var app = App("Code", "Code.icns", "Outro.icns");
            Assert.Equal(Path.Combine(app, "Contents", "Resources", "Code.icns"),
                Plist.IconPath(app, new Dictionary<string, string> { ["CFBundleIconFile"] = "Code" }));
        }

        [Fact]
        public void IconPath_SemChave_AppIconOuOPrimeiroIcns()
        {
            var a = App("A", "zeta.icns", "AppIcon.icns");
            var b = App("B", "beta.icns", "alfa.icns");
            var c = App("C");
            var none = new Dictionary<string, string>();
            Assert.EndsWith("AppIcon.icns", Plist.IconPath(a, none));
            Assert.EndsWith("alfa.icns", Plist.IconPath(b, none));
            Assert.Null(Plist.IconPath(c, none));
        }

        [Fact]
        public void IconPath_SoAssetsCar_UsaIconNameSeHouverIcns()
        {
            var app = App("S", "AppIcon2.icns");
            Assert.EndsWith("AppIcon2.icns", Plist.IconPath(app, new Dictionary<string, string> { ["CFBundleIconName"] = "AppIcon2" }));
        }

        [Fact]
        public void DisplayName_PastaOuNomeDoPlist()
        {
            Assert.Equal("Visual Studio Code", Plist.DisplayName("/Applications/Visual Studio Code.app", new Dictionary<string, string> { ["CFBundleDisplayName"] = "Visual Studio Code" }));
            // Pasta com sufixo de versao: o nome limpo do plist.
            Assert.Equal("Foo", Plist.DisplayName("/Applications/Foo 2.app", new Dictionary<string, string> { ["CFBundleDisplayName"] = "Foo" }));
            // Plist com outro nome (nome interno): vale a pasta, que e o que o Finder mostra.
            Assert.Equal("Safari", Plist.DisplayName("/Applications/Safari.app/", new Dictionary<string, string> { ["CFBundleDisplayName"] = "WebKit" }));
        }
    }

    /// <summary>Saida das ferramentas do Linux e do macOS.</summary>
    public class ToolOutputParsingTests
    {
        [Theory]
        [InlineData("Volume: 0.40", 40, false)]
        [InlineData("Volume: 1.00 [MUTED]\n", 100, true)]
        [InlineData("Volume: 0.255", 26, false)]
        public void Wpctl(string output, int volume, bool mute)
        {
            Assert.Equal((volume, mute), PulseParse.Wpctl(output));
        }

        [Fact]
        public void Pactl_VolumeEMudo()
        {
            Assert.Equal(40, PulseParse.Percent("Volume: front-left: 26214 /  40% / -23.88 dB,   front-right: 26214 /  40% / -23.88 dB"));
            Assert.True(PulseParse.Mute("Mute: yes"));
            Assert.True(PulseParse.Mute("Mudo: sim"));
            Assert.False(PulseParse.Mute("Mute: no"));
        }

        [Fact]
        public void Pactl_SinkInputs()
        {
            const string output = "Sink Input #42\n\tDriver: protocol-native.c\n\tSink: 0\n\tMute: no\n" +
                "\tVolume: front-left: 65536 / 100% / 0.00 dB,   front-right: 65536 / 100% / 0.00 dB\n\t        balance 0.00\n" +
                "\tProperties:\n\t\tapplication.name = \"Firefox\"\n\t\tapplication.process.binary = \"firefox\"\n\n" +
                "Sink Input #43\n\tMute: yes\n\tVolume: mono: 32768 /  50% / -18.06 dB\n" +
                "\tProperties:\n\t\tapplication.name = \"Spotify\"\n\t\tapplication.process.binary = \"spotify\"\n";
            var list = PulseParse.SinkInputs(output);
            Assert.Equal(2, list.Count);
            Assert.Equal(new PulseParse.SinkInput(42, "firefox", "Firefox", 100, false), list[0]);
            Assert.Equal(new PulseParse.SinkInput(43, "spotify", "Spotify", 50, true), list[1]);
            Assert.True(PulseParse.IsApp(list[1], "Spotify.exe"));
            Assert.False(PulseParse.IsApp(list[0], "chrome"));
        }

        [Fact]
        public void Proc_CpuMemoriaRede()
        {
            var a = ProcParse.CpuTimes("cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 1 2 3 4\n")!.Value;
            var b = ProcParse.CpuTimes("cpu  150 0 150 900 0 0 0 0 0 0\n")!.Value;
            Assert.Equal(50, ProcParse.CpuPercent(a, b));

            var (total, available) = ProcParse.Memory("MemTotal:       16384000 kB\nMemFree:  1000 kB\nMemAvailable:    8192000 kB\n");
            Assert.Equal(16000, total);
            Assert.Equal(8000, available);

            const string netdev = "Inter-|   Receive                                                |  Transmit\n" +
                " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n" +
                "    lo: 9999 1 0 0 0 0 0 0 9999 1 0 0 0 0 0 0\n" +
                "  eth0: 1000 10 0 0 0 0 0 0 500 5 0 0 0 0 0 0\n" +
                " wlan0: 24 1 0 0 0 0 0 0 6 1 0 0 0 0 0 0\n";
            Assert.Equal((506L, 1024L), ProcParse.NetDev(netdev));
        }

        [Fact]
        public void Wmctrl_Janelas()
        {
            var list = ProcParse.WmctrlWindows("0x03a00003  0 1234   host Documento - Editor de Texto\n0x01000002 -1 999 host Painel\n");
            Assert.Equal(new[] { (1234, "Documento - Editor de Texto") }, list);
        }

        [Fact]
        public void Mac_VmStatETop()
        {
            const string vm = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free:                               1000.\n" +
                "Pages active:                             5000.\nPages inactive:                           2000.\nPages speculative:                         500.\nPages purgeable:                           500.\n";
            Assert.Equal(4000L * 16384, MacParse.AvailableBytes(vm));
            Assert.Equal(8.34f, MacParse.TopCpu("Processes: 1\nCPU usage: 3.33% user, 5.0% sys, 91.66% idle \n")!.Value, 2);
            Assert.Null(MacParse.TopCpu("nada"));
        }

        [Fact]
        public void ProcNetTcp_AchaAConexaoDoCliente()
        {
            // 0x12B3 = 4787, 0xC350 = 50000
            const string table = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
                "   0: 0100007F:12B3 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 111 1\n" +
                "   1: 0100007F:C350 0100007F:12B3 01 00000000:00000000 00:00000000 00000000  1000        0 222 1\n" +
                "   2: 0100007F:12B3 0100007F:C350 01 00000000:00000000 00:00000000 00000000  1000        0 333 1\n";
            Assert.Equal(new[] { 222L }, UsbBridge.ProcNetTcpInodes(table, 50000, 4787));
        }

        [Fact]
        public void Playerctl_Sessoes()
        {
            var output = string.Join("\t", "spotify", "Playing", "Song", "Artist", "Album", "61000000", "180000000", "https://i.scdn.co/x") + "\n" +
                string.Join("\t", "firefox", "Paused", "", "", "", "0", "0", "") + "\n";
            var list = DeckOS.Platform.Linux.LinuxMediaControl.ParseSessions(output, out var art);
            Assert.Equal(2, list.Count);
            Assert.Equal("spotify", list[0].Id);
            Assert.Equal("Playing", list[0].PlaybackStatus);
            Assert.Equal(61, list[0].Position);
            Assert.Equal(180, list[0].Duration);
            Assert.Null(list[1].Title);
            Assert.Equal("https://i.scdn.co/x", art["spotify"]);
            Assert.False(art.ContainsKey("firefox"));
        }

        [Fact]
        public void Mac_Sessoes()
        {
            const string json = """[{"id":"Spotify","state":"playing","title":"S","artist":"A","album":null,"pos":12.5,"dur":200,"art":"https://x"},{"id":"Music","state":"paused","title":null,"pos":0,"dur":0,"art":null}]""";
            var list = MacMediaControl.ParseSessions(json, out var art);
            Assert.Equal("Playing", list[0].PlaybackStatus);
            Assert.Equal("Paused", list[1].PlaybackStatus);
            Assert.Equal(12.5, list[0].Position);
            Assert.Single(art);
        }
    }

    /// <summary>Tabelas de teclas e os scripts gerados para o macOS.</summary>
    public class KeyMapTests
    {
        [Theory]
        [InlineData(0x41, "a", 30, 0)]
        [InlineData(0x26, "Up", 103, 126)]
        [InlineData(0x0D, "Return", 28, 36)]
        [InlineData(0x70, "F1", 59, 122)]
        [InlineData(0x7B, "F12", 88, 111)]
        [InlineData(0x7C, "F13", 183, 105)]
        [InlineData(0x5B, "Super_L", 125, 55)]
        [InlineData(0xBA, "semicolon", 39, 41)]
        [InlineData(0xB3, "XF86AudioPlay", 164, null)]
        public void Tabelas(int vk, string keysym, int evdev, int? mac)
        {
            Assert.Equal(keysym, KeyMaps.X11Keysym((ushort)vk));
            Assert.Equal(evdev, KeyMaps.Evdev((ushort)vk));
            Assert.Equal(mac, KeyMaps.MacKeyCode((ushort)vk));
        }

        [Theory]
        [InlineData('a', 0x41, false)]
        [InlineData('A', 0x41, true)]
        [InlineData(':', 0xBA, true)]
        [InlineData('/', 0xBF, false)]
        [InlineData('(', 0x39, true)]
        public void TecladoAmericano(char c, int vk, bool shift)
        {
            Assert.True(KeyMaps.TryUsChar(c, out var v, out var s));
            Assert.Equal((ushort)vk, v);
            Assert.Equal(shift, s);
        }

        [Fact]
        public void MacScript_TextoAtalhoEMidia()
        {
            var script = MacKeyboard.Script(KeySequence.Parse("oi\"x^c#{TAB}{MEDIA_PLAY_PAUSE}"));
            // Texto como literal JSON (aspas escapadas), Ctrl+C e Cmd+Tab pelo System Events.
            Assert.Contains("se.keystroke(\"oi\\\"x\");", script);
            Assert.Contains("se.keystroke(\"c\",{using:['control down']});", script);
            Assert.Contains("se.keyCode(48,{using:['command down']});", script);
            Assert.Contains("mk(16);", script);
            Assert.StartsWith("ObjC.import('Cocoa');", script);
        }

        [Fact]
        public void CommandLine_Split()
        {
            Assert.Equal(new[] { "-a", "meu jogo", "it's", "x\"y", "" }, CommandLine.Split("-a \"meu jogo\" \"it's\" 'x\"y' ''"));
            Assert.Empty(CommandLine.Split("  "));
            Assert.Equal(new[] { "a b" }, CommandLine.Split(@"a\ b"));
        }
    }

    /// <summary>Mapa de capacidades por sistema (o que a interface esconde).</summary>
    public class CapabilityTests
    {
        private static (List<string> Caps, List<MissingCapability> Missing) Run(PlatformOs os, bool windowsBuild, string? session, params string[] tools) =>
            Capabilities.Compute(os, windowsBuild, tools.Contains, session);

        [Fact]
        public void Windows_TemTudoDoBinarioDoWindows()
        {
            var (caps, missing) = Run(PlatformOs.Windows, true, null);
            foreach (var id in new[] { Capabilities.AudioMixer, Capabilities.AudioDefaultDevice, Capabilities.Voicemeeter,
                         Capabilities.MacroRecord, Capabilities.Tray, Capabilities.AppsList, Capabilities.DisplayBrightness })
                Assert.Contains(id, caps);
            Assert.Equal(new[] { Capabilities.UsbAdb }, missing.Select(m => m.Capability));
        }

        [Fact]
        public void BinarioPortavelNoWindows_SoOComum()
        {
            var (caps, _) = Run(PlatformOs.Windows, false, null);
            Assert.DoesNotContain(Capabilities.Keyboard, caps);
            Assert.Contains(Capabilities.DiscoveryMdns, caps);
        }

        [Fact]
        public void MacOS_SemOQueESoDoWindows()
        {
            var (caps, _) = Run(PlatformOs.MacOS, false, null, "python3");
            Assert.Contains(Capabilities.Keyboard, caps);
            Assert.Contains(Capabilities.MediaControl, caps);
            Assert.Contains(Capabilities.ScriptPython, caps);
            foreach (var id in new[] { Capabilities.AudioMixer, Capabilities.AudioDefaultDevice, Capabilities.AudioAppMute,
                         Capabilities.Voicemeeter, Capabilities.MacroRecord, Capabilities.Tray, Capabilities.ScriptCmd, Capabilities.ScriptPowerShell })
                Assert.DoesNotContain(id, caps);
        }

        [Fact]
        public void LinuxX11_SemFerramentas_DizOPacote()
        {
            var (caps, missing) = Run(PlatformOs.Linux, false, "x11");
            Assert.DoesNotContain(Capabilities.Keyboard, caps);
            Assert.Contains(missing, m => m.Capability == Capabilities.Keyboard && m.Package == "xdotool");
            Assert.Contains(missing, m => m.Capability == Capabilities.MediaControl && m.Package == "playerctl");
            Assert.Contains(missing, m => m.Capability == Capabilities.AudioVolume && m.Tool == "wpctl");
            Assert.Contains(Capabilities.AppsList, caps);
            Assert.Contains(Capabilities.SystemMonitor, caps);
        }

        [Fact]
        public void LinuxWayland_YdotoolEPactl()
        {
            var (caps, missing) = Run(PlatformOs.Linux, false, "wayland", "ydotool", "pactl", "playerctl", "loginctl", "systemctl", "xdg-open");
            Assert.Contains(Capabilities.Keyboard, caps);
            Assert.Contains(Capabilities.AudioVolume, caps);
            Assert.Contains(Capabilities.AudioAppMute, caps);
            Assert.Contains(Capabilities.PowerLock, caps);
            // O Wayland nao informa a janela em foco, com ou sem xdotool.
            Assert.DoesNotContain(Capabilities.AutoProfile, caps);
            Assert.Contains(missing, m => m.Capability == Capabilities.AutoProfile);
        }

        [Theory]
        [InlineData("wayland", null, null, "wayland")]
        [InlineData(null, "wayland-0", ":0", "wayland")]
        [InlineData("tty", null, ":0", "x11")]
        [InlineData(null, null, null, null)]
        public void SessaoDoLinux(string? type, string? wayland, string? display, string? expected)
        {
            var env = new Dictionary<string, string?> { ["XDG_SESSION_TYPE"] = type, ["WAYLAND_DISPLAY"] = wayland, ["DISPLAY"] = display };
            Assert.Equal(expected, Capabilities.LinuxSession(k => env.GetValueOrDefault(k)));
        }

        [Fact]
        public void PastasDeDados_PorSistema()
        {
            var env = new Dictionary<string, string?>();
            Assert.Equal(Path.Combine(@"C:\Users\ana\AppData\Local", "DeckOS"), AppPaths.ForOs("windows", k => env.GetValueOrDefault(k), @"C:\Users\ana", @"C:\Users\ana\AppData\Local"));
            Assert.Equal(Path.Combine("/Users/ana", "Library", "Application Support", "DeckOS"), AppPaths.ForOs("macos", k => env.GetValueOrDefault(k), "/Users/ana", "x"));
            Assert.Equal(Path.Combine("/home/ana", ".config", "deckos"), AppPaths.ForOs("linux", k => env.GetValueOrDefault(k), "/home/ana", "x"));
            env["XDG_CONFIG_HOME"] = "/cfg";
            Assert.Equal(Path.Combine("/cfg", "deckos"), AppPaths.ForOs("linux", k => env.GetValueOrDefault(k), "/home/ana", "x"));
            Assert.Equal(Path.Combine("/cfg", "droiddeck"), AppPaths.ForOs("linux", k => env.GetValueOrDefault(k), "/home/ana", "x", legacy: true));
            Assert.Equal(Path.Combine(@"C:\Users\ana\AppData\Local", "DroidDeck"), AppPaths.ForOs("windows", k => env.GetValueOrDefault(k), @"C:\Users\ana", @"C:\Users\ana\AppData\Local", legacy: true));
        }

        [Fact]
        public void PastaAntiga_CopiadaSoQuandoANovaNaoExiste()
        {
            var root = Path.Combine(Path.GetTempPath(), "deckos-migrate-" + Guid.NewGuid().ToString("N"));
            try
            {
                var oldDir = Path.Combine(root, "DroidDeck");
                var newDir = Path.Combine(root, "DeckOS");
                Directory.CreateDirectory(Path.Combine(oldDir, "Roaming"));
                File.WriteAllText(Path.Combine(oldDir, "apikey"), "chave");
                File.WriteAllText(Path.Combine(oldDir, "Roaming", "profiles.json"), "[]");

                Assert.True(AppPaths.CopyLegacyDir(oldDir, newDir));
                Assert.Equal("chave", File.ReadAllText(Path.Combine(newDir, "apikey")));
                Assert.Equal("[]", File.ReadAllText(Path.Combine(newDir, "Roaming", "profiles.json")));
                Assert.True(File.Exists(Path.Combine(oldDir, "apikey")));

                File.WriteAllText(Path.Combine(oldDir, "apikey"), "outra");
                Assert.False(AppPaths.CopyLegacyDir(oldDir, newDir));
                Assert.Equal("chave", File.ReadAllText(Path.Combine(newDir, "apikey")));
                Assert.False(AppPaths.CopyLegacyDir(Path.Combine(root, "nada"), Path.Combine(root, "x")));
            }
            finally { try { Directory.Delete(root, recursive: true); } catch { } }
        }
    }
}
