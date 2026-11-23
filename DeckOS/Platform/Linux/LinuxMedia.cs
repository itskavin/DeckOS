using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Threading.Tasks;
using DeckOS.Services;
using Microsoft.Extensions.Logging;

namespace DeckOS.Platform.Linux
{
    /// <summary>
    /// Midia no Linux pelo MPRIS, via playerctl: Spotify, navegadores, VLC, mpv... Cada player
    /// e uma sessao; o id e o nome que o playerctl usa (-p).
    /// </summary>
    public sealed class LinuxMediaControl : IMediaControlService
    {
        // Um player por linha, campos separados por tab. position e mpris:length em microssegundos.
        internal const string Format = "{{playerName}}\t{{status}}\t{{title}}\t{{artist}}\t{{album}}\t{{position}}\t{{mpris:length}}\t{{mpris:artUrl}}";

        private readonly ILogger<LinuxMediaControl> _logger;
        private readonly IHttpClientFactory? _http;

        public LinuxMediaControl(ILogger<LinuxMediaControl> logger, IHttpClientFactory? http = null)
        {
            _logger = logger;
            _http = http;
        }

        /// <summary>Saida do "playerctl -a metadata --format" para sessoes (sem capa).</summary>
        public static List<MediaSessionInfo> ParseSessions(string output, out Dictionary<string, string> artUrls)
        {
            artUrls = new Dictionary<string, string>();
            var list = new List<MediaSessionInfo>();
            foreach (var line in output.Split('\n'))
            {
                var f = line.TrimEnd('\r').Split('\t');
                if (f.Length < 7 || f[0].Length == 0) continue;
                static double Seconds(string v) =>
                    double.TryParse(v, NumberStyles.Float, CultureInfo.InvariantCulture, out var us) ? us / 1_000_000.0 : 0;
                list.Add(new MediaSessionInfo
                {
                    Id = f[0],
                    PlaybackStatus = f[1],
                    Title = f[2].Length > 0 ? f[2] : null,
                    Artist = f[3].Length > 0 ? f[3] : null,
                    AlbumTitle = f[4].Length > 0 ? f[4] : null,
                    Position = Seconds(f[5]),
                    Duration = Seconds(f[6]),
                    CanPlayPause = true,
                    CanGoNext = true,
                    CanGoPrevious = true,
                });
                if (f.Length > 7 && f[7].Length > 0) artUrls[f[0]] = f[7];
            }
            return list;
        }

        private static bool Available => Tools.Has("playerctl");

        private Task<(List<MediaSessionInfo> Sessions, Dictionary<string, string> Art)> ReadAsync() => Task.Run(() =>
        {
            if (!Available) return (new List<MediaSessionInfo>(), new Dictionary<string, string>());
            // Sem player nenhum o playerctl sai com 1 ("No players found"): lista vazia.
            var r = Tools.Run("playerctl", new[] { "-a", "metadata", "--format", Format });
            var sessions = ParseSessions(r.Ok ? r.Output : "", out var art);
            return (sessions, art);
        });

        private async Task<MediaSessionInfo> WithThumbnailAsync(MediaSessionInfo s, Dictionary<string, string> art)
        {
            if (s.Id == null || !art.TryGetValue(s.Id, out var url)) return s;
            try
            {
                byte[]? bytes = null;
                if (url.StartsWith("file://", StringComparison.OrdinalIgnoreCase))
                {
                    var path = Uri.UnescapeDataString(new Uri(url).AbsolutePath);
                    if (File.Exists(path) && new FileInfo(path).Length < 5 * 1024 * 1024) bytes = await File.ReadAllBytesAsync(path);
                }
                else if (url.StartsWith("https://", StringComparison.OrdinalIgnoreCase) && _http != null)
                {
                    var client = _http.CreateClient();
                    client.Timeout = TimeSpan.FromSeconds(4);
                    bytes = await client.GetByteArrayAsync(url);
                }
                if (bytes != null) s.ThumbnailBase64 = "data:image/png;base64," + Convert.ToBase64String(bytes);
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "Mídia: capa de '{Id}' não carregou", s.Id);
            }
            return s;
        }

        /// <summary>A sessao "atual": a que esta tocando, senao a primeira (como o playerctl sem -p).</summary>
        private static MediaSessionInfo? Current(List<MediaSessionInfo> sessions) =>
            sessions.FirstOrDefault(s => s.PlaybackStatus == "Playing") ?? sessions.FirstOrDefault();

        public async Task<List<MediaSessionInfo>> GetAllSessionsAsync(bool includeThumbnails = true)
        {
            var (sessions, art) = await ReadAsync();
            if (includeThumbnails)
                foreach (var s in sessions) await WithThumbnailAsync(s, art);
            return sessions;
        }

        public async Task<MediaSessionInfo?> GetSessionByIdAsync(string sessionId)
        {
            var (sessions, art) = await ReadAsync();
            var s = sessions.FirstOrDefault(x => x.Id == sessionId);
            return s == null ? null : await WithThumbnailAsync(s, art);
        }

        public async Task<MediaSessionInfo?> GetNowPlayingAsync(bool includeThumbnail)
        {
            var (sessions, art) = await ReadAsync();
            var s = Current(sessions);
            if (s == null) return null;
            return includeThumbnail ? await WithThumbnailAsync(s, art) : s;
        }

        public async Task<bool> SeekAsync(double seconds)
        {
            var (sessions, _) = await ReadAsync();
            var s = Current(sessions);
            if (s?.Id == null) return false;
            var r = await Tools.RunAsync("playerctl", new[] { "-p", s.Id, "position", Math.Max(0, seconds).ToString("0.###", CultureInfo.InvariantCulture) });
            return r.Ok;
        }

        public async Task<bool> IsAnythingPlayingAsync()
        {
            if (!Available) return false;
            var r = await Tools.RunAsync("playerctl", new[] { "-a", "status" }, 3000);
            return r.Ok && r.Output.Split('\n').Any(l => l.Trim() == "Playing");
        }

        public async Task<MediaCommandResult> SendCommandAsync(string? sessionId, string command)
        {
            Tools.Require("playerctl", "playerctl");
            var verb = command.ToLowerInvariant() switch
            {
                "play" => "play",
                "pause" => "pause",
                "playpause" or "toggle" => "play-pause",
                "next" => "next",
                "previous" => "previous",
                "stop" => "stop",
                _ => null,
            };
            if (verb == null)
            {
                _logger.LogWarning("Unknown command: {command}", command);
                return new MediaCommandResult { Success = false, SessionId = sessionId };
            }

            var (sessions, _) = await ReadAsync();
            // Id que nao existe mais (player fechado): a sessao atual, como as teclas de midia.
            var target = sessions.FirstOrDefault(s => s.Id == sessionId) ?? Current(sessions);
            if (target?.Id == null)
            {
                _logger.LogWarning("Mídia: comando '{Command}' ignorado — nenhuma sessão de mídia ativa.", command);
                return new MediaCommandResult { Success = false };
            }

            var r = await Tools.RunAsync("playerctl", new[] { "-p", target.Id, verb });
            if (!r.Ok) return new MediaCommandResult { Success = false, SessionId = target.Id };
            var status = await Tools.RunAsync("playerctl", new[] { "-p", target.Id, "status" }, 2000);
            _logger.LogInformation("Sent command {command} to session {sessionId}", command, target.Id);
            return new MediaCommandResult
            {
                Success = true,
                SessionId = target.Id,
                Playing = status.Ok ? status.Output.Trim() == "Playing" : null,
            };
        }
    }
}
