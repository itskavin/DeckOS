#if !WINDOWS
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using DeckOS.Platform;
using Microsoft.Extensions.Logging;

namespace DeckOS.Services
{
    /// <summary>
    /// Reproducao no macOS e no Linux: um player de linha de comando no dispositivo padrao
    /// (afplay no Mac; mpv, ffplay, paplay ou pw-play no Linux, o primeiro que existir).
    /// Escolher o "cabo" e o monitor e so do Windows (capacidade soundboard.devices).
    /// </summary>
    public partial class SoundboardService
    {
        private Process? _player;

        /// <summary>Comando para tocar <paramref name="path"/> com volume 0..1. Publico para os testes.</summary>
        public static (string Tool, List<string> Args)? PlayerCommand(string path, float volume, Func<string, bool> has)
        {
            var v = Math.Clamp(volume, 0, 1);
            string F(double d) => d.ToString("0.##", CultureInfo.InvariantCulture);
            if (OperatingSystem.IsMacOS())
                return ("afplay", new List<string> { "-v", F(v), path });
            if (has("mpv")) return ("mpv", new List<string> { "--no-video", "--really-quiet", $"--volume={(int)(v * 100)}", path });
            if (has("ffplay")) return ("ffplay", new List<string> { "-nodisp", "-autoexit", "-loglevel", "quiet", "-volume", ((int)(v * 100)).ToString(CultureInfo.InvariantCulture), path });
            // paplay e pw-play leem MP3 pelo libsndfile >= 1.1.
            if (has("paplay")) return ("paplay", new List<string> { $"--volume={(int)(v * 65536)}", path });
            if (has("pw-play")) return ("pw-play", new List<string> { "--volume", F(v), path });
            return null;
        }

        private void StartPlayback(string path, SoundboardConfig cfg, string? title)
        {
            var command = PlayerCommand(path, Math.Clamp(cfg.Volume, 0, 100) / 100f, Tools.Has)
                ?? throw new ToolMissingException("mpv", "mpv");
            var psi = new ProcessStartInfo(Tools.Which(command.Tool) ?? command.Tool)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            foreach (var a in command.Args) psi.ArgumentList.Add(a);

            lock (_lock)
            {
                try
                {
                    var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
                    p.Exited += (_, _) => OnPlayerExited(p);
                    p.Start();
                    // Ninguem le a saida: descarta para o buffer nao travar o player.
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                    _player = p;
                    NowPlayingTitle = title ?? "";
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Falha ao iniciar o player {Tool}", command.Tool);
                    NowPlayingTitle = null;
                }
            }
        }

        private void OnPlayerExited(Process p)
        {
            var becameEmpty = false;
            lock (_lock)
            {
                if (ReferenceEquals(_player, p))
                {
                    _player = null;
                    NowPlayingTitle = null;
                    becameEmpty = true;
                }
            }
            try { p.Dispose(); } catch { }
            if (becameEmpty) _ = BroadcastAsync();
        }

        public void StopAll(bool broadcast = true)
        {
            Process? p;
            lock (_lock)
            {
                p = _player;
                _player = null;
                NowPlayingTitle = null;
            }
            // Exited ainda dispara, mas _player ja nao e este: o handler vira no-op.
            try { if (p != null && !p.HasExited) p.Kill(); } catch { }
            if (broadcast) _ = BroadcastAsync();
        }

        /// <summary>Fora do Windows o som sai no dispositivo padrao: nao ha lista para escolher.</summary>
        public List<object> GetOutputDevices() => new();
    }
}
#endif
