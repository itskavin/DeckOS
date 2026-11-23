using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using DeckOS.Lib.Input;
using DeckOS.Models;
using DeckOS.Services;

namespace DeckOS.Platform
{
    /// <summary>
    /// Os servicos do sistema que tambem sao usados fora do DI (o teclado do HeldKeys.Shared,
    /// o foco do ForegroundWatcher.RunningApps). O ServiceRegistration registra estas mesmas
    /// instancias, entao DI e estatico nunca divergem.
    /// </summary>
    public static class PlatformServices
    {
        private static readonly Lazy<IKeyboardInput> _keyboard = new(CreateKeyboard);
        private static readonly Lazy<IForegroundWindow> _foreground = new(CreateForeground);

        public static IKeyboardInput Keyboard => _keyboard.Value;
        public static IForegroundWindow Foreground => _foreground.Value;

        private static IKeyboardInput CreateKeyboard()
        {
#if WINDOWS
            if (OperatingSystem.IsWindows()) return new Windows.WindowsKeyboard();
#endif
            if (OperatingSystem.IsMacOS()) return new MacOS.MacKeyboard();
            if (OperatingSystem.IsLinux()) return new Linux.LinuxKeyboard();
            return new UnsupportedKeyboard();
        }

        private static IForegroundWindow CreateForeground()
        {
#if WINDOWS
            if (OperatingSystem.IsWindows()) return new Windows.WindowsForeground();
#endif
            if (OperatingSystem.IsMacOS()) return new MacOS.MacForeground();
            if (OperatingSystem.IsLinux()) return new Linux.LinuxForeground();
            return new UnsupportedForeground();
        }
    }

    // ---- Sistema sem implementacao (o binario portavel rodando no Windows, BSD...) ----
    // Le o que da (nada) e recusa agir com uma mensagem clara, em vez de quebrar o servidor.

    internal static class Unsupported
    {
        public static PlatformFeatureException Error(string what) =>
            new($"{what} não está disponível neste sistema ({Capabilities.OsId(Capabilities.CurrentOs)}).");
    }

    public sealed class UnsupportedKeyboard : IKeyboardInput
    {
        public void KeyDown(ushort vk) => throw Unsupported.Error("Teclado");
        public void KeyUp(ushort vk) => throw Unsupported.Error("Teclado");
        public void Send(IReadOnlyList<KeyStroke> strokes) => throw Unsupported.Error("Teclado");
        public bool TryResolveChar(char c, out ushort vk) => KeyMaps.TryUsChar(c, out vk, out _);
    }

    public sealed class UnsupportedForeground : IForegroundWindow
    {
        public (int Pid, string? Process)? Foreground() => null;
        public IReadOnlyList<(string Process, string Title)> VisibleApps() => Array.Empty<(string, string)>();
    }

    public sealed class UnsupportedVolume : ISystemVolume
    {
        public DeviceAudioState? Apply(string? deviceId, bool input, int? volume = null, int? delta = null,
            bool? mute = null, bool toggleMute = false) => throw Unsupported.Error("Volume");

        public (int Volume, bool Mute)? AppVolume(string app, int? volume) => throw Unsupported.Error("Volume por app");
    }

    public sealed class UnsupportedPower : IPowerActions
    {
        public void Lock() => throw Unsupported.Error("Travar o computador");
        public void Sleep() => throw Unsupported.Error("Suspender");
        public void DisplayOff() => throw Unsupported.Error("Desligar a tela");
    }

    public sealed class UnsupportedMetrics : ISystemMetrics
    {
        public float CpuPercent() => 0;
        public (float TotalMb, float AvailableMb, float LoadPercent) Memory() => (0, 0, 0);
        public float GpuPercent() => 0;
        public (long Sent, long Received) NetworkBytes() => (0, 0);
        public List<DiskStat> Disks() => SystemMonitorService.SampleDisks();
    }

    public sealed class UnsupportedMedia : IMediaControlService
    {
        public Task<List<MediaSessionInfo>> GetAllSessionsAsync(bool includeThumbnails = true) => Task.FromResult(new List<MediaSessionInfo>());
        public Task<MediaSessionInfo?> GetSessionByIdAsync(string sessionId) => Task.FromResult<MediaSessionInfo?>(null);
        public Task<MediaSessionInfo?> GetNowPlayingAsync(bool includeThumbnail) => Task.FromResult<MediaSessionInfo?>(null);
        public Task<bool> SeekAsync(double seconds) => Task.FromResult(false);
        public Task<bool> IsAnythingPlayingAsync() => Task.FromResult(false);
        public Task<MediaCommandResult> SendCommandAsync(string? sessionId, string command) =>
            Task.FromResult(new MediaCommandResult { Success = false });
    }

    public sealed class UnsupportedAppActivator : IAppActivator
    {
        public void ActivateWindow(string? name) => throw Unsupported.Error("Ativar janela");
        public void SendKeys(string keys) => KeyboardInput.Send(KeySequence.Parse(keys));

        public void LaunchApp(string path, string? arguments = null)
        {
            var psi = new System.Diagnostics.ProcessStartInfo { FileName = path, Arguments = arguments ?? "", UseShellExecute = true };
            System.Diagnostics.Process.Start(psi)?.Dispose();
        }
    }
}
