using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using DeckOS.Lib.Input;
using DeckOS.Models;
using DeckOS.Services;

namespace DeckOS.Platform.MacOS
{
    /// <summary>Leitura da saida das ferramentas do macOS. Separado para os testes.</summary>
    public static class MacParse
    {
        /// <summary>vm_stat: paginas livres + inativas + especulativas + purgaveis, em bytes.</summary>
        public static long AvailableBytes(string vmStat)
        {
            var pageSize = 4096L;
            var header = Regex.Match(vmStat, @"page size of (\d+) bytes");
            if (header.Success) pageSize = long.Parse(header.Groups[1].Value, CultureInfo.InvariantCulture);
            long Pages(string label)
            {
                var m = Regex.Match(vmStat, "^" + Regex.Escape(label) + @":\s+(\d+)", RegexOptions.Multiline);
                return m.Success ? long.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : 0;
            }
            return (Pages("Pages free") + Pages("Pages inactive") + Pages("Pages speculative") + Pages("Pages purgeable")) * pageSize;
        }

        /// <summary>"CPU usage: 3.33% user, 5.0% sys, 91.66% idle" (top -l 1) para o % ocupado.</summary>
        public static float? TopCpu(string top)
        {
            var m = Regex.Match(top, @"CPU usage:.*?([\d.]+)% idle");
            return m.Success ? (float)Math.Clamp(100 - double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture), 0, 100) : null;
        }
    }

    /// <summary>Travar (Ctrl+Cmd+Q), suspender e apagar a tela pelo pmset.</summary>
    public sealed class MacPower : IPowerActions
    {
        private const string CgSession = "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession";

        public void Lock()
        {
            // O CGSession sumiu no Big Sur; o atalho do menu Apple (Ctrl+Cmd+Q) e o que sobra.
            if (File.Exists(CgSession))
            {
                Tools.Spawn(CgSession, new[] { "-suspend" });
                return;
            }
            Osa.AppleScript("tell application \"System Events\" to keystroke \"q\" using {control down, command down}");
        }

        public void Sleep() => Tools.Spawn("pmset", new[] { "sleepnow" });

        public void DisplayOff() => Tools.Check("pmset", new[] { "displaysleepnow" });
    }

    /// <summary>
    /// Volume pelo AppleScript ("set volume"). O macOS nao tem mudo de entrada: mutar o
    /// microfone zera o volume dele e desmutar devolve o anterior.
    /// </summary>
    public sealed class MacSystemVolume : ISystemVolume
    {
        private int _micBeforeMute = 75;

        public DeviceAudioState? Apply(string? deviceId, bool input, int? volume = null, int? delta = null,
            bool? mute = null, bool toggleMute = false)
        {
            var (vol, muted) = Read(input);
            if (volume.HasValue || delta.HasValue)
            {
                var target = Math.Clamp(volume ?? vol + delta!.Value, 0, 100);
                Osa.AppleScript($"set volume {(input ? "input" : "output")} volume {target}");
                if (!input && target > 0 && !mute.HasValue && !toggleMute && muted)
                    Osa.AppleScript("set volume output muted false");
                vol = target;
            }
            var wantMute = toggleMute ? !muted : mute;
            if (wantMute.HasValue)
            {
                if (!input)
                {
                    Osa.AppleScript($"set volume output muted {(wantMute.Value ? "true" : "false")}");
                }
                else if (wantMute.Value && vol > 0)
                {
                    _micBeforeMute = vol;
                    Osa.AppleScript("set volume input volume 0");
                }
                else if (!wantMute.Value && vol == 0)
                {
                    Osa.AppleScript($"set volume input volume {_micBeforeMute}");
                }
            }
            var after = Read(input);
            return new DeviceAudioState
            {
                Id = "default",
                Title = input ? "Microfone" : "Saída de áudio",
                Volume = after.Volume,
                Mute = after.Mute,
            };
        }

        private static (int Volume, bool Mute) Read(bool input)
        {
            if (input)
            {
                var v = int.TryParse(Osa.AppleScript("input volume of (get volume settings)"), out var iv) ? iv : 0;
                return (v, v == 0);
            }
            // "missing value" quando a saida nao tem volume (HDMI, alguns DACs USB).
            var raw = Osa.AppleScript("(output volume of (get volume settings) as text) & \",\" & (output muted of (get volume settings) as text)");
            var parts = raw.Split(',');
            var volume = int.TryParse(parts[0], out var ov) ? ov : 0;
            var muted = parts.Length > 1 && parts[1].Trim() == "true";
            return (volume, muted);
        }

        public (int Volume, bool Mute)? AppVolume(string app, int? volume) =>
            throw new PlatformFeatureException("O macOS não tem volume por app.");
    }

    /// <summary>
    /// CPU pelo host_statistics (Mach), RAM pelo sysctl hw.memsize + vm_stat, rede pelo .NET.
    /// GPU nao ha como ler sem privilegio: fica 0.
    /// </summary>
    public sealed class MacSystemMetrics : ISystemMetrics
    {
        private (long Idle, long Total)? _lastCpu;
        private long _totalBytes;

        public float CpuPercent()
        {
            try
            {
                var info = new int[4];
                var count = 4;
                if (host_statistics(mach_host_self(), 3 /* HOST_CPU_LOAD_INFO */, info, ref count) != 0)
                    return MacParse.TopCpu(Tools.TryOutput("top", "-l", "1", "-n", "0") ?? "") ?? 0;
                // user, system, idle, nice (ticks desde o boot)
                long user = (uint)info[0], sys = (uint)info[1], idle = (uint)info[2], nice = (uint)info[3];
                var now = (idle, user + sys + idle + nice);
                var before = _lastCpu;
                _lastCpu = now;
                if (before == null) return 0;
                var total = now.Item2 - before.Value.Total;
                if (total <= 0) return 0;
                return (float)Math.Clamp((total - (now.idle - before.Value.Idle)) * 100.0 / total, 0, 100);
            }
            catch
            {
                return 0;
            }
        }

        public (float TotalMb, float AvailableMb, float LoadPercent) Memory()
        {
            try
            {
                if (_totalBytes == 0)
                    long.TryParse(Tools.TryOutput("sysctl", "-n", "hw.memsize")?.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out _totalBytes);
                var vm = Tools.TryOutput("vm_stat");
                if (_totalBytes <= 0 || vm == null) return (0, 0, 0);
                var available = Math.Min(MacParse.AvailableBytes(vm), _totalBytes);
                var totalMb = _totalBytes / (1024f * 1024f);
                var availMb = available / (1024f * 1024f);
                return (totalMb, availMb, (float)Math.Round((totalMb - availMb) * 100 / totalMb));
            }
            catch
            {
                return (0, 0, 0);
            }
        }

        public float GpuPercent() => 0;

        public (long Sent, long Received) NetworkBytes()
        {
            long sent = 0, recv = 0;
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    try
                    {
                        var s = ni.GetIPStatistics();
                        sent += s.BytesSent;
                        recv += s.BytesReceived;
                    }
                    catch (PlatformNotSupportedException) { }
                }
            }
            catch { }
            return (sent, recv);
        }

        public List<DiskStat> Disks() => SystemMonitorService.SampleDisks();

        [DllImport("libSystem.dylib")]
        private static extern uint mach_host_self();

        [DllImport("libSystem.dylib")]
        private static extern int host_statistics(uint host, int flavor, int[] info, ref int count);
    }

    /// <summary>
    /// App em foco pelo lsappinfo (vem com o macOS e nao pede permissao); a lista de apps
    /// com janela, pelo System Events.
    /// </summary>
    public sealed class MacForeground : IForegroundWindow
    {
        public (int Pid, string? Process)? Foreground()
        {
            var asn = Tools.TryOutput("lsappinfo", "front")?.Trim();
            if (string.IsNullOrEmpty(asn)) return null;
            var info = Tools.TryOutput("lsappinfo", "info", "-only", "pid", asn) ?? "";
            var m = Regex.Match(info, @"""pid""\s*=\s*(\d+)");
            if (!m.Success || !int.TryParse(m.Groups[1].Value, out var pid)) return null;
            return (pid, ProcessName(pid));
        }

        public IReadOnlyList<(string Process, string Title)> VisibleApps()
        {
            var json = Osa.Js(
                "var se=Application('System Events');" +
                "var p=se.applicationProcesses.whose({backgroundOnly:false});" +
                "JSON.stringify({pids:p.unixId(),names:p.name()})", 8000);
            using var doc = System.Text.Json.JsonDocument.Parse(json);
            var pids = doc.RootElement.GetProperty("pids").EnumerateArray().Select(e => e.GetInt32()).ToList();
            var names = doc.RootElement.GetProperty("names").EnumerateArray().Select(e => e.GetString() ?? "").ToList();
            var own = Environment.ProcessId;
            var list = new List<(string, string)>();
            for (var i = 0; i < Math.Min(pids.Count, names.Count); i++)
            {
                if (pids[i] == own || names[i] == "Finder") continue;
                if (ProcessName(pids[i]) is { } process) list.Add((process, names[i]));
            }
            return list;
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

    /// <summary>Abrir app (.app pelo open -a), arquivo ou URL (open) e trazer janela pelo titulo.</summary>
    public sealed class MacAppActivator : IAppActivator
    {
        public void ActivateWindow(string? name)
        {
            if (string.IsNullOrEmpty(name)) return;
            Osa.Js(
                "var se=Application('System Events');var t=" + Osa.JsString(name) + ";" +
                "var ps=se.applicationProcesses.whose({backgroundOnly:false})();" +
                "for(var i=0;i<ps.length;i++){try{var w=ps[i].windows.whose({name:t})();" +
                "if(w.length){ps[i].frontmost=true;w[0].actions['AXRaise'].perform();break;}}catch(e){}}", 8000);
        }

        public void SendKeys(string keys)
        {
            if (string.IsNullOrEmpty(keys)) return;
            KeyboardInput.Send(KeySequence.Parse(keys));
        }

        public void LaunchApp(string path, string? arguments = null)
        {
            path = path.Trim();
            var args = CommandLine.Split(arguments);
            if (path.EndsWith(".app", StringComparison.OrdinalIgnoreCase) || path.EndsWith(".app/", StringComparison.OrdinalIgnoreCase))
            {
                var open = new List<string> { "-a", path };
                if (args.Count > 0) { open.Add("--args"); open.AddRange(args); }
                Tools.Spawn("open", open);
                return;
            }
            if (File.Exists(path) && IsExecutable(path) && !path.EndsWith(".command", StringComparison.OrdinalIgnoreCase))
            {
                var psi = new ProcessStartInfo(path) { UseShellExecute = false };
                foreach (var a in args) psi.ArgumentList.Add(a);
                Process.Start(psi)?.Dispose();
                return;
            }
            // Nome de app sem caminho ("Safari"): o open -a acha.
            if (!path.Contains('/') && !path.Contains(':') && !File.Exists(path))
            {
                var open = new List<string> { "-a", path };
                if (args.Count > 0) { open.Add("--args"); open.AddRange(args); }
                Tools.Spawn("open", open);
                return;
            }
            Tools.Spawn("open", new[] { path });
        }

        private static bool IsExecutable(string path)
        {
            if (OperatingSystem.IsWindows()) return false;
            try { return (File.GetUnixFileMode(path) & (UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute)) != 0; }
            catch { return false; }
        }
    }
}
