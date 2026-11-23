using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading.Tasks;
using DeckOS.Services;
using Microsoft.Extensions.Logging;

namespace DeckOS.Platform.MacOS
{
    /// <summary>
    /// Midia no macOS. O sistema nao tem API publica de "o que esta tocando" (o MediaRemote e
    /// privado), entao: Spotify e Music abertos viram sessoes pelo AppleScript deles (titulo,
    /// capa do Spotify, posicao), e comando sem sessao vai como tecla de midia, que o macOS
    /// entrega ao app que esta tocando (Safari, Chrome, VLC...).
    /// </summary>
    public sealed class MacMediaControl : IMediaControlService
    {
        private static readonly string[] Players = { "Spotify", "Music" };

        // Le os players abertos sem abri-los (running() nao lanca o app).
        private const string ReadScript =
            "function info(n){try{var a=Application(n);if(!a.running())return null;" +
            "var st=String(a.playerState());var t=null;try{t=a.currentTrack();t.name();}catch(e){t=null;}" +
            "var dur=0;try{dur=t?t.duration():0;}catch(e){}" +
            "if(n=='Spotify')dur=dur/1000;" +
            "var art=null;if(n=='Spotify'&&t){try{art=t.artworkUrl();}catch(e){}}" +
            "var pos=0;try{pos=a.playerPosition();}catch(e){}" +
            "return {id:n,state:st,title:t?t.name():null,artist:t?t.artist():null,album:t?t.album():null,pos:pos,dur:dur,art:art};" +
            "}catch(e){return null;}}" +
            "JSON.stringify([info('Spotify'),info('Music')].filter(function(x){return x;}))";

        private readonly ILogger<MacMediaControl> _logger;
        private readonly IHttpClientFactory? _http;

        public MacMediaControl(ILogger<MacMediaControl> logger, IHttpClientFactory? http = null)
        {
            _logger = logger;
            _http = http;
        }

        /// <summary>JSON do script de leitura para sessoes (a capa fica em artUrls).</summary>
        public static List<MediaSessionInfo> ParseSessions(string json, out Dictionary<string, string> artUrls)
        {
            artUrls = new Dictionary<string, string>();
            var list = new List<MediaSessionInfo>();
            using var doc = JsonDocument.Parse(json);
            foreach (var p in doc.RootElement.EnumerateArray())
            {
                string? S(string key) => p.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
                double D(string key) => p.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : 0;
                var id = S("id");
                if (id == null) continue;
                var state = S("state") ?? "";
                list.Add(new MediaSessionInfo
                {
                    Id = id,
                    Title = S("title"),
                    Artist = S("artist"),
                    AlbumTitle = S("album"),
                    // Mesmo vocabulario do Windows (GlobalSystemMediaTransportControlsSessionPlaybackStatus).
                    PlaybackStatus = state.Equals("playing", StringComparison.OrdinalIgnoreCase) ? "Playing"
                        : state.Equals("paused", StringComparison.OrdinalIgnoreCase) ? "Paused" : "Stopped",
                    Position = D("pos"),
                    Duration = D("dur"),
                    CanPlayPause = true,
                    CanGoNext = true,
                    CanGoPrevious = true,
                });
                if (S("art") is { Length: > 0 } art) artUrls[id] = art;
            }
            return list;
        }

        private async Task<(List<MediaSessionInfo> Sessions, Dictionary<string, string> Art)> ReadAsync()
        {
            try
            {
                var json = await Task.Run(() => Osa.Js(ReadScript, 5000));
                var sessions = ParseSessions(json, out var art);
                return (sessions, art);
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "Mídia: leitura dos players falhou");
                return (new List<MediaSessionInfo>(), new Dictionary<string, string>());
            }
        }

        private async Task<MediaSessionInfo> WithThumbnailAsync(MediaSessionInfo s, Dictionary<string, string> art)
        {
            if (s.Id == null || _http == null || !art.TryGetValue(s.Id, out var url) ||
                !url.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return s;
            try
            {
                var client = _http.CreateClient();
                client.Timeout = TimeSpan.FromSeconds(4);
                s.ThumbnailBase64 = "data:image/jpeg;base64," + Convert.ToBase64String(await client.GetByteArrayAsync(url));
            }
            catch (Exception ex)
            {
                _logger.LogDebug(ex, "Mídia: capa de '{Id}' não carregou", s.Id);
            }
            return s;
        }

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
            await Task.Run(() => Osa.Js($"Application({Osa.JsString(s.Id)}).playerPosition={Math.Max(0, seconds).ToString(System.Globalization.CultureInfo.InvariantCulture)};"));
            return true;
        }

        public async Task<bool> IsAnythingPlayingAsync()
        {
            var (sessions, _) = await ReadAsync();
            return sessions.Any(s => s.PlaybackStatus == "Playing");
        }

        public async Task<MediaCommandResult> SendCommandAsync(string? sessionId, string command)
        {
            var cmd = command.ToLowerInvariant();
            var (sessions, _) = await ReadAsync();
            var target = sessions.FirstOrDefault(s => s.Id == sessionId)
                ?? (string.IsNullOrEmpty(sessionId) ? sessions.FirstOrDefault(s => s.PlaybackStatus == "Playing") : null);

            if (target?.Id == null || !Players.Contains(target.Id))
            {
                // Sem player com AppleScript: tecla de midia para quem estiver tocando.
                int? key = cmd switch
                {
                    "playpause" or "toggle" or "play" or "pause" or "stop" => 16,
                    "next" => 17,
                    "previous" => 18,
                    _ => null,
                };
                if (key == null) return new MediaCommandResult { Success = false };
                await Task.Run(() => Osa.MediaKey(key.Value));
                return new MediaCommandResult { Success = true, SessionId = sessionId };
            }

            var verb = cmd switch
            {
                "play" => "play()",
                "pause" => "pause()",
                "playpause" or "toggle" => "playpause()",
                "next" => "nextTrack()",
                "previous" => "previousTrack()",
                // O Spotify nao tem stop.
                "stop" => target.Id == "Music" ? "stop()" : "pause()",
                _ => null,
            };
            if (verb == null)
            {
                _logger.LogWarning("Unknown command: {command}", command);
                return new MediaCommandResult { Success = false, SessionId = target.Id };
            }
            var state = await Task.Run(() => Osa.Js($"var a=Application({Osa.JsString(target.Id)});a.{verb};delay(0.15);String(a.playerState())"));
            _logger.LogInformation("Sent command {command} to session {sessionId}", command, target.Id);
            return new MediaCommandResult
            {
                Success = true,
                SessionId = target.Id,
                Playing = state.Equals("playing", StringComparison.OrdinalIgnoreCase),
            };
        }
    }
}
