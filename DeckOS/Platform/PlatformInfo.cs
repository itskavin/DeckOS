using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using Microsoft.Extensions.Configuration;

namespace DeckOS.Platform
{
    /// <summary>Estado configurado do discovery (UDP e mDNS), compartilhado entre o startup e /api/platform.</summary>
    public sealed record DiscoveryAvailability(bool Udp, bool Mdns)
    {
        public static DiscoveryAvailability FromConfiguration(IConfiguration configuration)
        {
            var udp = string.Equals(configuration["EnableDiscovery"], "true", StringComparison.OrdinalIgnoreCase);
            var mdnsSetting = configuration["DECKOS_MDNS"] ?? Environment.GetEnvironmentVariable("DECKOS_MDNS");
            return new DiscoveryAvailability(udp, udp && Lib.MdnsAdvertiser.IsEnabled(mdnsSetting));
        }
    }
    public enum PlatformOs
    {
        Windows,
        MacOS,
        Linux,
        Other,
    }

    /// <summary>Recurso que falta por causa de uma ferramenta: o que instalar para ter.</summary>
    public sealed record MissingCapability(string Capability, string Tool, string Package);

    /// <summary>Resposta do GET /api/platform.</summary>
    public sealed record PlatformReport(
        string Os,
        string OsVersion,
        string Arch,
        string? Version,
        string MachineName,
        string? Session,
        IReadOnlyList<string> Capabilities,
        IReadOnlyList<MissingCapability> Missing);

    /// <summary>
    /// O que este PC sabe fazer. A interface esconde o que nao esta na lista (Voicemeeter no
    /// macOS, trocar o audio padrao no Linux...) em vez de deixar o botao falhar no toque.
    ///
    /// Os ids sao contrato com o configurador: mudar um nome quebra a interface em silencio.
    /// </summary>
    public static class Capabilities
    {
        // Teclado e apps
        public const string Keyboard = "keyboard";                 // tecla, atalho, multi-acao com teclas
        public const string KeyboardHold = "keyboard.hold";        // segurar tecla (modo "hold", toggle, oneshot)
        public const string AppsLaunch = "apps.launch";            // abrir programa/arquivo/URL
        public const string AppsList = "apps.list";                // GET /api/apps (biblioteca)
        public const string WindowActivate = "window.activate";    // trazer janela pelo titulo
        public const string AutoProfile = "foreground.autoProfile"; // troca de perfil pelo app em foco
        public const string MacroRecord = "macro.record";          // gravar macro do teclado

        // Audio e midia
        public const string AudioVolume = "audio.volume";          // volume/mudo da saida padrao
        public const string AudioMicrophone = "audio.microphone";  // volume/mudo da entrada padrao
        public const string AudioAppMute = "audio.appMute";        // mudo por app
        public const string AudioAppVolume = "audio.appVolume";    // volume por app (controle deslizante)
        public const string AudioMixer = "audio.mixer";            // /api/v1/Mixer: dispositivos e sessoes
        public const string AudioDefaultDevice = "audio.defaultDevice"; // trocar o dispositivo padrao
        public const string MediaControl = "media.control";        // play/pause/proxima
        public const string MediaNowPlaying = "media.nowPlaying";  // titulo, capa, posicao
        public const string Soundboard = "soundboard";             // tocar sons
        public const string SoundboardDevices = "soundboard.devices"; // escolher saida "cabo"/monitor
        public const string Voicemeeter = "voicemeeter";

        // Sistema
        public const string PowerLock = "power.lock";
        public const string PowerSleep = "power.sleep";
        public const string PowerDisplayOff = "power.displayOff";
        public const string SystemMonitor = "system.monitor";      // CPU, RAM, rede, discos
        public const string SystemGpu = "system.gpu";
        public const string DisplayBrightness = "display.brightness";
        public const string ScriptPowerShell = "script.powershell";
        public const string ScriptPython = "script.python";
        public const string ScriptCmd = "script.cmd";
        public const string ScriptShell = "script.shell";
        public const string Steam = "steam";
        public const string UsbAdb = "usb.adb";

        // App do PC
        public const string Tray = "tray";                         // icone na bandeja, janela de QR
        public const string AutoUpdate = "app.autoUpdate";         // Velopack
        public const string FirewallSetup = "app.firewallSetup";
        public const string DiscoveryUdp = "discovery.udp";
        public const string DiscoveryMdns = "discovery.mdns";

        public static PlatformOs CurrentOs =>
            OperatingSystem.IsWindows() ? PlatformOs.Windows
            : OperatingSystem.IsMacOS() ? PlatformOs.MacOS
            : OperatingSystem.IsLinux() ? PlatformOs.Linux
            : PlatformOs.Other;

        /// <summary>Este binario e o do Windows (com NAudio, WinRT, bandeja)?</summary>
        public static bool WindowsBuild =>
#if WINDOWS
            true;
#else
            false;
#endif

        public static string OsId(PlatformOs os) => os switch
        {
            PlatformOs.Windows => "windows",
            PlatformOs.MacOS => "macos",
            PlatformOs.Linux => "linux",
            _ => "other",
        };

        /// <summary>"wayland", "x11" ou null (fora do Linux, ou sem sessao grafica).</summary>
        public static string? LinuxSession(Func<string, string?> env)
        {
            var type = env("XDG_SESSION_TYPE")?.Trim().ToLowerInvariant();
            if (type is "wayland" or "x11") return type;
            if (!string.IsNullOrEmpty(env("WAYLAND_DISPLAY"))) return "wayland";
            if (!string.IsNullOrEmpty(env("DISPLAY"))) return "x11";
            return null;
        }

        /// <summary>
        /// A lista para um sistema. Logica pura (os testes passam um <paramref name="hasTool"/>
        /// falso): no Windows tudo vem do proprio binario; no macOS e no Linux, das ferramentas
        /// instaladas.
        /// </summary>
        public static (List<string> Capabilities, List<MissingCapability> Missing) Compute(
            PlatformOs os, bool windowsBuild, Func<string, bool> hasTool, string? linuxSession,
            bool discoveryUdp = true, bool discoveryMdns = true)
        {
            var caps = new List<string>();
            var missing = new List<MissingCapability>();

            void Need(string capability, string tool, string package)
            {
                if (hasTool(tool)) caps.Add(capability);
                else missing.Add(new MissingCapability(capability, tool, package));
            }

            void NeedAny(string capability, (string tool, string package)[] options)
            {
                if (options.Any(o => hasTool(o.tool))) caps.Add(capability);
                else missing.Add(new MissingCapability(capability, options[0].tool, options[0].package));
            }

            // Comuns: discovery reflete o que realmente esta habilitado na configuracao.
            if (discoveryUdp) caps.Add(DiscoveryUdp);
            if (discoveryMdns) caps.Add(DiscoveryMdns);
            caps.Add(Steam);

            switch (os)
            {
                case PlatformOs.Windows when windowsBuild:
                    caps.AddRange(new[]
                    {
                        Keyboard, KeyboardHold, AppsLaunch, AppsList, WindowActivate, AutoProfile, MacroRecord,
                        AudioVolume, AudioMicrophone, AudioAppMute, AudioAppVolume, AudioMixer, AudioDefaultDevice,
                        MediaControl, MediaNowPlaying, Soundboard, SoundboardDevices, Voicemeeter,
                        PowerLock, PowerSleep, PowerDisplayOff, SystemMonitor, SystemGpu, DisplayBrightness,
                        ScriptPowerShell, ScriptPython, ScriptCmd, Tray, AutoUpdate, FirewallSetup,
                    });
                    Need(UsbAdb, "adb", "Android platform-tools");
                    break;

                case PlatformOs.MacOS:
                    // osascript, open, pmset e afplay vem com o macOS.
                    caps.AddRange(new[]
                    {
                        Keyboard, KeyboardHold, AppsLaunch, AppsList, WindowActivate, AutoProfile,
                        AudioVolume, AudioMicrophone, MediaControl, MediaNowPlaying, Soundboard,
                        PowerLock, PowerSleep, PowerDisplayOff, SystemMonitor, ScriptShell,
                    });
                    if (hasTool("python3")) caps.Add(ScriptPython);
                    if (hasTool("pwsh")) caps.Add(ScriptPowerShell);
                    Need(UsbAdb, "adb", "android-platform-tools (brew install android-platform-tools)");
                    break;

                case PlatformOs.Linux:
                    // Teclado: xdotool no X11; no Wayland, ydotool (qualquer compositor, com o
                    // ydotoold rodando) ou wtype (wlroots: Sway, Hyprland).
                    var keyTools = linuxSession == "wayland"
                        ? new[] { ("ydotool", "ydotool"), ("wtype", "wtype") }
                        : new[] { ("xdotool", "xdotool") };
                    NeedAny(Keyboard, keyTools);
                    NeedAny(KeyboardHold, keyTools);
                    if (linuxSession == "wayland")
                    {
                        // Wayland nao deixa um app ler a janela em foco dos outros.
                        missing.Add(new MissingCapability(AutoProfile, "xdotool", "sessão X11 (o Wayland não informa a janela em foco)"));
                        missing.Add(new MissingCapability(WindowActivate, "wmctrl", "sessão X11 (o Wayland não deixa ativar janelas)"));
                    }
                    else
                    {
                        Need(AutoProfile, "xdotool", "xdotool");
                        Need(WindowActivate, "wmctrl", "wmctrl");
                    }
                    NeedAny(AppsLaunch, new[] { ("xdg-open", "xdg-utils"), ("gtk-launch", "libgtk-3-bin") });
                    caps.Add(AppsList);
                    var volume = new[] { ("wpctl", "wireplumber"), ("pactl", "pulseaudio-utils") };
                    NeedAny(AudioVolume, volume);
                    NeedAny(AudioMicrophone, volume);
                    Need(AudioAppMute, "pactl", "pulseaudio-utils");
                    Need(AudioAppVolume, "pactl", "pulseaudio-utils");
                    Need(MediaControl, "playerctl", "playerctl");
                    Need(MediaNowPlaying, "playerctl", "playerctl");
                    NeedAny(Soundboard, new[] { ("mpv", "mpv"), ("ffplay", "ffmpeg"), ("paplay", "pulseaudio-utils"), ("pw-play", "pipewire") });
                    Need(PowerLock, "loginctl", "systemd");
                    Need(PowerSleep, "systemctl", "systemd");
                    NeedAny(PowerDisplayOff, new[] { ("xset", "x11-xserver-utils"), ("busctl", "systemd") });
                    caps.Add(SystemMonitor);
                    caps.Add(ScriptShell);
                    if (hasTool("python3")) caps.Add(ScriptPython);
                    if (hasTool("pwsh")) caps.Add(ScriptPowerShell);
                    Need(UsbAdb, "adb", "adb (android-tools-adb / android-tools)");
                    break;
            }
            return (caps, missing);
        }

        /// <summary>O relatorio deste PC, agora.</summary>
        public static PlatformReport Current(DiscoveryAvailability? discovery = null)
        {
            var os = CurrentOs;
            var session = os == PlatformOs.Linux ? LinuxSession(Environment.GetEnvironmentVariable) : null;
            Tools.Forget();
            var udp = discovery?.Udp ?? true;
            var mdns = discovery?.Mdns ?? Lib.MdnsAdvertiser.Enabled;
            var (caps, missing) = Compute(os, WindowsBuild, t => t == "adb" ? Lib.UsbBridge.FindAdb() != null : Tools.Has(t), session, udp, mdns);
            return new PlatformReport(
                OsId(os),
                RuntimeInformation.OSDescription,
                RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant(),
                typeof(Capabilities).Assembly.GetName().Version?.ToString(3),
                Environment.MachineName,
                session,
                caps,
                missing);
        }
    }
}
