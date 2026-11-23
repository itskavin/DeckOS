using DeckOS.Hubs;
using DeckOS.Models;
using DeckOS.Platform;
using Microsoft.AspNetCore.SignalR;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace DeckOS.Services
{
    /// <summary>
    /// Manda CPU, RAM, rede, GPU e discos aos celulares a cada segundo, e o estado de
    /// reproducao a cada 3. As leituras vem do <see cref="ISystemMetrics"/> do sistema.
    /// </summary>
    public class SystemMonitorService : BackgroundService
    {
        private readonly ILogger<SystemMonitorService> _logger;
        private readonly IHubContext<DeckHub> _hubContext;
        private readonly IMediaControlService _media;
        private readonly ISystemMetrics _metrics;

        // Estado para throughput de rede (deltas por segundo).
        private long _lastSent;
        private long _lastRecv;
        private DateTime _lastNetTime = DateTime.UtcNow;

        // Espaço em disco muda devagar: lê a cada 30 s e repete o último nos outros ticks.
        private const int DiskEveryTicks = 30;
        private List<DiskStat>? _disks;

        public SystemMonitorService(ILogger<SystemMonitorService> logger, IHubContext<DeckHub> hubContext,
            IMediaControlService media, ISystemMetrics metrics)
        {
            _logger = logger;
            _hubContext = hubContext;
            _media = media;
            _metrics = metrics;
        }

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            int tick = 0;
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    // Sem clientes ouvindo, não computa nem transmite nada — evita o poll
                    // de mídia (caro) e as alocações de rede/GPU 24/7 com o app ocioso.
                    if (DeckHub.ConnectedCount <= 0)
                    {
                        await Task.Delay(1000, stoppingToken);
                        continue;
                    }

                    var cpu = _metrics.CpuPercent();
                    var (ramTotal, ramAvailable, ramLoad) = _metrics.Memory();
                    var (netUp, netDown) = SampleNetwork();

                    var stats = new SystemStats
                    {
                        CpuUsage = (float)Math.Round(cpu, 1),
                        RamTotal = ramTotal,
                        RamAvailable = ramAvailable,
                        RamUsage = ramLoad,
                        NetUpKBps = netUp,
                        NetDownKBps = netDown,
                        GpuUsage = _metrics.GpuPercent(),
                        Disks = tick % DiskEveryTicks == 0 || _disks == null ? (_disks = _metrics.Disks()) : _disks,
                    };

                    // Broadcast to clients listening on "ReceiveSystemStats"
                    await _hubContext.Clients.All.SendAsync("ReceiveSystemStats", stats, cancellationToken: stoppingToken);

                    // Estado de reprodução de mídia (pra botões play/pause refletirem).
                    // A cada 3s: o acesso WinRT (RequestAsync) é caro; 1s era exagero.
                    if (tick % 3 == 0)
                    {
                        try
                        {
                            var playing = await _media.IsAnythingPlayingAsync();
                            await _hubContext.Clients.All.SendAsync("ReceiveMediaStatus",
                                new { playing }, cancellationToken: stoppingToken);
                        }
                        catch { }
                    }
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
                {
                    break;
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Error broadcasting system stats");
                }

                tick++;
                try { await Task.Delay(1000, stoppingToken); }
                catch (OperationCanceledException) { break; }
            }

            (_metrics as IDisposable)?.Dispose();
        }

        // Pontos de montagem que nao sao disco de usuario (Linux e macOS listam dezenas).
        private static readonly string[] SystemMounts =
        {
            "/boot", "/snap", "/run", "/sys", "/proc", "/dev", "/var/lib/docker", "/var/snap",
            "/System/Volumes", "/private/var/vm",
        };

        /// <summary>
        /// Unidades fixas prontas (HD/SSD; pendrive e rede ficam de fora), em ordem de letra.
        /// No macOS/Linux: a raiz e os discos montados por quem usa (/home, /Volumes/..., /mnt/...).
        /// </summary>
        public static List<DiskStat> SampleDisks()
        {
            var list = new List<DiskStat>();
            var seen = new HashSet<(long, long)>();
            try
            {
                foreach (var d in System.IO.DriveInfo.GetDrives())
                {
                    try
                    {
                        if (d.DriveType != System.IO.DriveType.Fixed || !d.IsReady || d.TotalSize <= 0) continue;
                        var name = d.Name.TrimEnd('\\');
                        if (!OperatingSystem.IsWindows())
                        {
                            name = d.Name.Length > 1 ? d.Name.TrimEnd('/') : d.Name;
                            if (SystemMounts.Any(m => name == m || name.StartsWith(m + "/", StringComparison.Ordinal))) continue;
                            // O mesmo volume montado em dois lugares (APFS, bind mounts): conta uma vez.
                            if (!seen.Add((d.TotalSize, d.TotalFreeSpace))) continue;
                        }
                        list.Add(new DiskStat
                        {
                            Name = name,
                            Label = d.VolumeLabel ?? "",
                            TotalBytes = d.TotalSize,
                            FreeBytes = d.TotalFreeSpace,
                        });
                    }
                    catch { } // unidade que some no meio da leitura
                }
            }
            catch { }
            return list.OrderBy(d => d.Name, StringComparer.OrdinalIgnoreCase).ToList();
        }

        private (float up, float down) SampleNetwork()
        {
            var (sent, recv) = _metrics.NetworkBytes();

            var now = DateTime.UtcNow;
            var elapsed = (now - _lastNetTime).TotalSeconds;
            float up = 0, down = 0;
            if (_lastSent > 0 && elapsed > 0.1)
            {
                up = (float)Math.Max(0, (sent - _lastSent) / elapsed / 1024.0);   // KB/s
                down = (float)Math.Max(0, (recv - _lastRecv) / elapsed / 1024.0); // KB/s
            }
            _lastSent = sent;
            _lastRecv = recv;
            _lastNetTime = now;
            return (up, down);
        }
    }
}
