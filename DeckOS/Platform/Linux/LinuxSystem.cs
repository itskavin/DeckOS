using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using DeckOS.Lib.Input;
using DeckOS.Models;
using DeckOS.Services;

namespace DeckOS.Platform.Linux
{
    /// <summary>Leitura do /proc. Separado para os testes.</summary>
    public static class ProcParse
    {
        /// <summary>Linha "cpu" do /proc/stat: (ocioso, total) em jiffies.</summary>
        public static (long Idle, long Total)? CpuTimes(string stat)
        {
            var line = stat.Split('\n').FirstOrDefault(l => l.StartsWith("cpu ", StringComparison.Ordinal));
            if (line == null) return null;
            var values = line.Split(' ', StringSplitOptions.RemoveEmptyEntries).Skip(1)
                .Select(v => long.TryParse(v, NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : 0).ToArray();
            if (values.Length < 4) return null;
            // user nice system idle iowait irq softirq steal (guest ja esta dentro de user).
            var idle = values[3] + (values.Length > 4 ? values[4] : 0);
            var total = values.Take(Math.Min(values.Length, 8)).Sum();
            return (idle, total);
        }

        /// <summary>% de CPU entre duas leituras do /proc/stat.</summary>
        public static float CpuPercent((long Idle, long Total) before, (long Idle, long Total) after)
        {
            var total = after.Total - before.Total;
            if (total <= 0) return 0;
            var busy = total - (after.Idle - before.Idle);
            return (float)Math.Clamp(busy * 100.0 / total, 0, 100);
        }

        /// <summary>MemTotal e MemAvailable do /proc/meminfo, em MB.</summary>
        public static (float TotalMb, float AvailableMb) Memory(string meminfo)
        {
            long Kb(string key)
            {
                var line = meminfo.Split('\n').FirstOrDefault(l => l.StartsWith(key + ":", StringComparison.Ordinal));
                var digits = line?.Split(':', 2)[1].Trim().Split(' ')[0];
                return long.TryParse(digits, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v : 0;
            }
            var total = Kb("MemTotal");
            var available = Kb("MemAvailable");
            // Kernel antigo, sem MemAvailable: livre + cache.
            if (available == 0) available = Kb("MemFree") + Kb("Buffers") + Kb("Cached");
            return (total / 1024f, available / 1024f);
        }

        /// <summary>Bytes enviados e recebidos no /proc/net/dev, fora o loopback.</summary>
        public static (long Sent, long Received) NetDev(string netdev)
        {
            long sent = 0, recv = 0;
            foreach (var line in netdev.Split('\n'))
            {
                var colon = line.IndexOf(':');
                if (colon < 0) continue;
                var name = line[..colon].Trim();
                if (name == "lo" || name.Length == 0) continue;
                var f = line[(colon + 1)..].Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (f.Length < 9) continue;
                if (long.TryParse(f[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out var r)) recv += r;
                if (long.TryParse(f[8], NumberStyles.Integer, CultureInfo.InvariantCulture, out var s)) sent += s;
            }
            return (sent, recv);
        }

        /// <summary>"0x03a00003  0 12345  host Titulo" (wmctrl -lp) para (pid, titulo).</summary>
        public static List<(int Pid, string Title)> WmctrlWindows(string output)
        {
            var list = new List<(int, string)>();
            foreach (var line in output.Split('\n'))
            {
                var f = line.Split(' ', 5, StringSplitOptions.RemoveEmptyEntries);
                if (f.Length < 5 || !int.TryParse(f[2], out var pid) || pid <= 0) continue;
                // Desktop "-1" e janela fixa (barra, dock): nao e app.
                if (f[1] == "-1") continue;
                list.Add((pid, f[4].Trim()));
            }
            return list;
        }
    }

    /// <summary>CPU, RAM e rede pelo /proc; GPU pelo sysfs (AMD/Intel expõem gpu_busy_percent).</summary>
    public sealed class LinuxSystemMetrics : ISystemMetrics
    {
        private (long Idle, long Total)? _lastCpu;

        public float CpuPercent()
        {
            try
            {
                var now = ProcParse.CpuTimes(File.ReadAllText("/proc/stat"));
                if (now == null) return 0;
                var before = _lastCpu;
                _lastCpu = now;
                return before == null ? 0 : ProcParse.CpuPercent(before.Value, now.Value);
            }
            catch { return 0; }
        }

        public (float TotalMb, float AvailableMb, float LoadPercent) Memory()
        {
            try
            {
                var (total, available) = ProcParse.Memory(File.ReadAllText("/proc/meminfo"));
                var load = total > 0 ? (float)Math.Round((total - available) * 100 / total) : 0;
                return (total, available, load);
            }
            catch { return (0, 0, 0); }
        }

        public float GpuPercent()
        {
            try
            {
                foreach (var file in Directory.EnumerateFiles("/sys/class/drm", "gpu_busy_percent", new EnumerationOptions { RecurseSubdirectories = true, MaxRecursionDepth = 3 }))
                {
                    if (float.TryParse(File.ReadAllText(file).Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var v))
                        return Math.Clamp(v, 0, 100);
                }
            }
            catch { }
            return 0;
        }

        public (long Sent, long Received) NetworkBytes()
        {
            try { return ProcParse.NetDev(File.ReadAllText("/proc/net/dev")); }
            catch { return (0, 0); }
        }

        public List<DiskStat> Disks() => SystemMonitorService.SampleDisks();
    }

    /// <summary>
    /// Janela em foco pelo xdotool e lista de janelas pelo wmctrl (X11). O Wayland nao deixa
    /// um app ver as janelas dos outros: la nao ha troca automatica de perfil.
    /// </summary>
    public sealed class LinuxForeground : IForegroundWindow
    {
        private static bool Wayland => Capabilities.LinuxSession(Environment.GetEnvironmentVariable) == "wayland";

        public (int Pid, string? Process)? Foreground()
        {
            if (Wayland || !Tools.Has("xdotool")) return null;
            var output = Tools.TryOutput("xdotool", "getactivewindow", "getwindowpid");
            if (!int.TryParse(output?.Trim(), out var pid) || pid <= 0) return null;
            return (pid, ProcessName(pid));
        }

        public IReadOnlyList<(string Process, string Title)> VisibleApps()
        {
            if (Wayland || !Tools.Has("wmctrl")) return Array.Empty<(string, string)>();
            var output = Tools.TryOutput("wmctrl", "-lp");
            if (output == null) return Array.Empty<(string, string)>();
            var own = Environment.ProcessId;
            return ProcParse.WmctrlWindows(output)
                .Where(w => w.Pid != own)
                .Select(w => (name: ProcessName(w.Pid), w.Title))
                .Where(w => w.name != null)
                .Select(w => (w.name!, w.Title))
                .ToList();
        }

        private static string? ProcessName(int pid)
        {
            try
            {
                using var p = Process.GetProcessById(pid);
                return p.ProcessName;
            }
            catch
            {
                return null;
            }
        }
    }

    /// <summary>Travar (loginctl), suspender (systemctl) e desligar a tela (xset, KDE ou GNOME).</summary>
    public sealed class LinuxPower : IPowerActions
    {
        public void Lock()
        {
            // Sob o systemd --user nao ha "sessao do chamador": lock-session falha e o
            // lock-sessions (todas as do usuario) resolve. O xdg-screensaver cobre o resto.
            if (Tools.Has("loginctl"))
            {
                if (TryRun("loginctl", "lock-session") || TryRun("loginctl", "lock-sessions")) return;
            }
            if (Tools.Has("xdg-screensaver") && TryRun("xdg-screensaver", "lock")) return;
            if (Tools.Has("dbus-send") && TryRun("dbus-send", "--session", "--type=method_call",
                    "--dest=org.freedesktop.ScreenSaver", "/org/freedesktop/ScreenSaver", "org.freedesktop.ScreenSaver.Lock")) return;
            throw new ToolMissingException("loginctl", "systemd");
        }

        public void Sleep() => Tools.Spawn(Tools.Require("systemctl", "systemd"), new[] { "suspend" });

        public void DisplayOff()
        {
            var session = Capabilities.LinuxSession(Environment.GetEnvironmentVariable);
            if (session != "wayland" && Tools.Has("xset") && TryRun("xset", "dpms", "force", "off")) return;
            if (Tools.Has("kscreen-doctor") && TryRun("kscreen-doctor", "--dpms", "off")) return;
            // GNOME: liga a protecao de tela, que apaga o monitor.
            if (Tools.Has("busctl") && TryRun("busctl", "--user", "call", "org.gnome.Shell", "/org/gnome/ScreenSaver",
                    "org.gnome.ScreenSaver", "SetActive", "b", "true")) return;
            throw new ToolMissingException("xset", "x11-xserver-utils");
        }

        private static bool TryRun(string tool, params string[] args)
        {
            try { return Tools.Run(tool, args).Ok; }
            catch { return false; }
        }
    }

    /// <summary>Abrir app/arquivo (.desktop, executavel, xdg-open) e ativar janela (wmctrl).</summary>
    public sealed class LinuxAppActivator : IAppActivator
    {
        public void ActivateWindow(string? name)
        {
            if (string.IsNullOrEmpty(name)) return;
            Tools.Require("wmctrl", "wmctrl");
            Tools.Run("wmctrl", "-F", "-a", name);
        }

        public void SendKeys(string keys)
        {
            if (string.IsNullOrEmpty(keys)) return;
            KeyboardInput.Send(KeySequence.Parse(keys));
        }

        public void LaunchApp(string path, string? arguments = null)
        {
            path = path.Trim();
            if (path.EndsWith(".desktop", StringComparison.OrdinalIgnoreCase))
            {
                LaunchDesktopFile(path, arguments);
                return;
            }
            if (File.Exists(path) && IsExecutable(path))
            {
                var psi = new ProcessStartInfo(path) { UseShellExecute = false };
                foreach (var a in CommandLine.Split(arguments)) psi.ArgumentList.Add(a);
                Process.Start(psi)?.Dispose();
                return;
            }
            // Nome no PATH (firefox, code) sem caminho.
            if (!path.Contains('/') && !path.Contains(':') && Tools.Which(path) is { } exe)
            {
                Tools.Spawn(exe, CommandLine.Split(arguments));
                return;
            }
            // Arquivo, pasta ou URL: o app padrao.
            Tools.Spawn(Tools.Require("xdg-open", "xdg-utils"), new[] { path });
        }

        private static void LaunchDesktopFile(string path, string? arguments)
        {
            // gtk-launch so acha pelo id (nome do arquivo) e nas pastas do XDG; senao, o Exec.
            var id = Path.GetFileNameWithoutExtension(path);
            if (string.IsNullOrEmpty(arguments) && Tools.Has("gtk-launch") && (!File.Exists(path) || DesktopEntry.InXdgDirs(path)))
            {
                Tools.Spawn("gtk-launch", new[] { id });
                return;
            }
            var entry = File.Exists(path) ? DesktopEntry.Parse(File.ReadAllText(path)) : null;
            var argv = entry?.ExecArgs();
            if (argv == null || argv.Count == 0)
                throw new InvalidOperationException($"'{path}' não tem um comando para abrir.");
            argv.AddRange(CommandLine.Split(arguments));
            var exe = Tools.Which(argv[0]) ?? argv[0];
            Tools.Spawn(exe, argv.Skip(1));
        }

        private static bool IsExecutable(string path)
        {
            if (OperatingSystem.IsWindows()) return false;
            try { return (File.GetUnixFileMode(path) & (UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute)) != 0; }
            catch { return false; }
        }
    }
}
