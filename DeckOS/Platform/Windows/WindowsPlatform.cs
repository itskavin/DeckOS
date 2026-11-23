using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using DeckOS.Models;
using DeckOS.Services;
using NAudio.CoreAudioApi;

namespace DeckOS.Platform.Windows
{
    /// <summary>Travar, suspender e desligar a tela pelo Win32 (antes dentro do WindowsProvider).</summary>
    public sealed class WindowsPower : IPowerActions
    {
        public void Lock() => LockWorkStation();

        // Suspende (nao hiberna). Assincrono: o Windows dorme depois de responder.
        public void Sleep() => _ = Task.Run(() => SetSuspendState(false, false, false));

        // SC_MONITORPOWER 2 = desligar. SendMessageTimeout: um app travado no broadcast nao
        // pode prender o deck.
        public void DisplayOff() =>
            SendMessageTimeout(HwndBroadcast, WmSysCommand, ScMonitorPower, (IntPtr)2, 0x0002, 1000, out _);

        private static readonly IntPtr HwndBroadcast = new(0xffff);
        private const uint WmSysCommand = 0x0112;
        private static readonly IntPtr ScMonitorPower = new(0xF170);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern bool LockWorkStation();

        [DllImport("powrprof.dll", SetLastError = true)]
        private static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);

        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam,
            uint flags, uint timeout, out IntPtr result);
    }

    /// <summary>Volume pelo Core Audio (NAudio), via <see cref="MixerService"/>.</summary>
    public sealed class WindowsSystemVolume : ISystemVolume
    {
        private readonly MixerService _mixer;

        public WindowsSystemVolume(MixerService mixer) => _mixer = mixer;

        public DeviceAudioState? Apply(string? deviceId, bool input, int? volume = null, int? delta = null,
            bool? mute = null, bool toggleMute = false)
        {
            // "default" em vez de um id fixo: o id do endpoint muda quando o usuario troca
            // de fone/monitor, e ai o botao apontaria pra um dispositivo que nao existe mais.
            var id = string.IsNullOrEmpty(deviceId) || string.Equals(deviceId, "default", StringComparison.OrdinalIgnoreCase)
                ? _mixer.GetDefaultDeviceId(input ? DataFlow.Capture : DataFlow.Render)
                : deviceId;
            if (string.IsNullOrEmpty(id)) return null;
            return _mixer.SetDeviceAudio(id, volume, delta, mute, toggleMute);
        }

        /// <summary>Volume das sessoes de audio de um app no dispositivo de saida padrao.</summary>
        public (int Volume, bool Mute)? AppVolume(string app, int? volume)
        {
            using var en = new MMDeviceEnumerator();
            using var device = en.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            var sessions = device.AudioSessionManager.Sessions;
            int? current = null;
            var mute = false;
            for (var i = 0; i < sessions.Count; i++)
            {
                using var session = sessions[i];
                if (session.IsSystemSoundsSession) continue;
                string name;
                try
                {
                    using var proc = Process.GetProcessById((int)session.GetProcessID);
                    name = proc.ProcessName;
                }
                catch
                {
                    continue;
                }
                if (!name.Equals(app, StringComparison.OrdinalIgnoreCase)) continue;
                // Um app pode ter varias sessoes (navegador com abas): mexe em todas.
                if (volume.HasValue) session.SimpleAudioVolume.Volume = Math.Min(volume.Value, 100) / 100f;
                current ??= (int)Math.Round(session.SimpleAudioVolume.Volume * 100);
                mute |= session.SimpleAudioVolume.Mute;
            }
            return current == null ? null : (current.Value, mute);
        }
    }

    /// <summary>
    /// CPU e GPU pelos PerformanceCounter, RAM pelo GlobalMemoryStatusEx (antes dentro do
    /// SystemMonitorService).
    /// </summary>
    public sealed class WindowsSystemMetrics : ISystemMetrics, IDisposable
    {
        private PerformanceCounter? _cpuCounter;
        private bool _cpuTried;

        // Counters de GPU (uso) por instância de engine 3D; cacheados entre ticks.
        private readonly Dictionary<string, PerformanceCounter> _gpuCounters = new();
        // A enumeração de instâncias ("GetInstanceNames") é cara e aloca uma string por
        // engine de GPU a cada chamada. Só rescaneia a cada N ticks; entre eles, só lê os
        // counters já cacheados (evita pressão de GC constante no loop de 1s).
        private int _gpuTick = 0;
        private const int GpuRescanEveryTicks = 30;

        public float CpuPercent()
        {
            if (!_cpuTried)
            {
                _cpuTried = true;
                try
                {
                    _cpuCounter = new PerformanceCounter("Processor", "% Processor Time", "_Total");
                }
                catch
                {
                    // Fallback for PT-BR
                    try { _cpuCounter = new PerformanceCounter("Processador", "% tempo de processador", "_Total"); }
                    catch (Exception ex) { Lib.Log.Error(ex, "Failed to init CPU Counter"); }
                }
                try { _cpuCounter?.NextValue(); } catch { }
            }
            try { return _cpuCounter?.NextValue() ?? 0; }
            catch { return 0; }
        }

        public (float TotalMb, float AvailableMb, float LoadPercent) Memory()
        {
            // RAM via GlobalMemoryStatusEx: total, disponível e % de uso de uma vez.
            var mem = new MEMORYSTATUSEX();
            if (!GlobalMemoryStatusEx(mem)) return (0, 0, 0);
            return (mem.ullTotalPhys / (1024f * 1024f), mem.ullAvailPhys / (1024f * 1024f), mem.dwMemoryLoad);
        }

        public (long Sent, long Received) NetworkBytes()
        {
            long sent = 0, recv = 0;
            try
            {
                foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (ni.OperationalStatus != OperationalStatus.Up) continue;
                    if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                    var s = ni.GetIPv4Statistics();
                    sent += s.BytesSent;
                    recv += s.BytesReceived;
                }
            }
            catch { }
            return (sent, recv);
        }

        public float GpuPercent()
        {
            try
            {
                // Rescan das instâncias só de tempos em tempos (caro). No 1º tick e a cada N.
                if (_gpuTick++ % GpuRescanEveryTicks == 0)
                {
                    var cat = new PerformanceCounterCategory("GPU Engine");
                    var names = cat.GetInstanceNames()
                        .Where(n => n.EndsWith("engtype_3D"))
                        .ToHashSet();

                    foreach (var n in names)
                    {
                        if (!_gpuCounters.ContainsKey(n))
                        {
                            var c = new PerformanceCounter("GPU Engine", "Utilization Percentage", n, true);
                            try { c.NextValue(); } catch { } // prime: 1ª leitura é 0
                            _gpuCounters[n] = c;
                        }
                    }
                    foreach (var key in _gpuCounters.Keys.Where(k => !names.Contains(k)).ToList())
                    {
                        try { _gpuCounters[key].Dispose(); } catch { }
                        _gpuCounters.Remove(key);
                    }
                }

                float sum = 0;
                foreach (var c in _gpuCounters.Values)
                {
                    try { sum += c.NextValue(); } catch { }
                }
                return Math.Min(sum, 100f);
            }
            catch
            {
                return 0; // GPU Engine indisponível neste sistema
            }
        }

        public List<DiskStat> Disks() => SystemMonitorService.SampleDisks();

        public void Dispose()
        {
            // Libera os PerformanceCounter ao encerrar o serviço.
            try { _cpuCounter?.Dispose(); } catch { }
            foreach (var c in _gpuCounters.Values) { try { c.Dispose(); } catch { } }
            _gpuCounters.Clear();
        }

        [StructLayout(LayoutKind.Sequential)]
        private class MEMORYSTATUSEX
        {
            public uint dwLength;
            public uint dwMemoryLoad;
            public ulong ullTotalPhys;
            public ulong ullAvailPhys;
            public ulong ullTotalPageFile;
            public ulong ullAvailPageFile;
            public ulong ullTotalVirtual;
            public ulong ullAvailVirtual;
            public ulong ullAvailExtendedVirtual;

            public MEMORYSTATUSEX()
            {
                dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX lpBuffer);
    }

    /// <summary>Janela em foco e janelas visiveis pelo user32 (antes dentro do ForegroundWatcher).</summary>
    public sealed class WindowsForeground : IForegroundWindow
    {
        public (int Pid, string? Process)? Foreground()
        {
            var hwnd = GetForegroundWindow();
            if (hwnd == IntPtr.Zero) return null;
            GetWindowThreadProcessId(hwnd, out var pid);
            return pid == 0 ? null : ((int)pid, ProcessName(pid));
        }

        public IReadOnlyList<(string Process, string Title)> VisibleApps()
        {
            var titles = new Dictionary<uint, string>();
            EnumWindows((hwnd, _) =>
            {
                if (!IsWindowVisible(hwnd)) return true;
                var length = GetWindowTextLength(hwnd);
                if (length == 0) return true;
                var sb = new StringBuilder(length + 1);
                GetWindowText(hwnd, sb, sb.Capacity);
                GetWindowThreadProcessId(hwnd, out var pid);
                titles.TryAdd(pid, sb.ToString());
                return true;
            }, IntPtr.Zero);

            var ownPid = (uint)Environment.ProcessId;
            return titles
                .Where(t => t.Key != ownPid)
                .Select(t => (name: ProcessName(t.Key), title: t.Value))
                .Where(t => t.name != null && t.name != "explorer" && t.name != "TextInputHost" && t.name != "ApplicationFrameHost")
                .Select(t => (t.name!, t.title))
                .ToList();
        }

        private static string? ProcessName(uint pid)
        {
            try
            {
                using var p = Process.GetProcessById((int)pid);
                return p.ProcessName;
            }
            catch
            {
                return null;
            }
        }

        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);

        [DllImport("user32.dll")]
        private static extern int GetWindowTextLength(IntPtr hWnd);
    }
}
