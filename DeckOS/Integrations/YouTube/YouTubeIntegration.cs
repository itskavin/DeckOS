using System;
using System.Collections.Generic;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Actions;
using DeckOS.Hubs;
using DeckOS.Lib;
using DeckOS.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.SignalR;
using Microsoft.Extensions.Logging;

namespace DeckOS.Integrations
{
    /// <summary>
    /// YouTube Data API v3 com um cliente OAuth "App para computador" do proprio usuario
    /// (Client ID + Client Secret, que nesse tipo de app nao sao secretos de verdade).
    /// Le a transmissao ao vivo a cada minuto (a cota diaria e pequena) e manda mensagens no chat.
    /// </summary>
    public class YouTubeIntegration : AccountIntegration
    {
        public const string Event = "ReceiveYouTubeState";
        private const string Api = "https://www.googleapis.com/youtube/v3";

        private readonly IHttpClientFactory _http;
        private readonly OAuthTokens _tokens;
        private string? _pendingState;
        private string? _pendingVerifier;
        private string? _error;
        private bool _live;
        private int? _viewers;
        private string? _title;
        private string? _chatId;
        private DateTime _nextRefresh;

        public YouTubeIntegration(ILogger<YouTubeIntegration> logger, IHubContext<DeckHub> hub, StreamDeckConfigService config,
            IHttpClientFactory http) : base(logger, hub, config)
        {
            _http = http;
            _tokens = new OAuthTokens(Get, v => Set(v), http)
            {
                TokenEndpoint = "https://oauth2.googleapis.com/token",
                ClientFields = () => new() { ["client_id"] = Get("clientId") ?? "", ["client_secret"] = Get("clientSecret") ?? "" },
            };
        }

        public override string Name => "youtube";
        public override string Title => "YouTube";
        public override string StateEvent => Event;

        private string? Channel => Get("channel");
        private bool Connected => _tokens.HasToken && Channel != null;

        public override IntegrationStatus GetStatus() => new()
        {
            Connected = Connected,
            Configured = Get("clientId") != null && Get("clientSecret") != null,
            Account = Connected ? Channel : null,
            Message = Connected ? null : _error,
            LoginPending = _pendingState != null,
            RedirectUri = RedirectUriFor(Name),
            Fields = new() { ["clientId"] = Get("clientId") ?? "" },
        };

        public override object GetState() => new
        {
            connected = Connected,
            account = Connected ? Channel : null,
            live = _live,
            viewers = _viewers,
            title = _title,
        };

        public override Task<IntegrationStatus> ConfigureAsync(Dictionary<string, string> fields)
        {
            var clientId = (fields.GetValueOrDefault("clientId") ?? Get("clientId") ?? "").Trim();
            var secret = (fields.GetValueOrDefault("clientSecret") ?? "").Trim();
            if (!clientId.EndsWith(".apps.googleusercontent.com"))
                throw new InvalidOperationException("O Client ID termina em .apps.googleusercontent.com.");
            if (secret.Length == 0) secret = Get("clientSecret") ?? "";
            if (secret.Length == 0) throw new InvalidOperationException("Falta o Client Secret.");
            if (clientId != Get("clientId")) Clear();
            Set(("clientId", clientId), ("clientSecret", secret));

            var (verifier, challenge) = OAuthTokens.NewPkce();
            _pendingVerifier = verifier;
            _pendingState = OAuthTokens.NewState();
            _error = null;
            OpenBrowser("https://accounts.google.com/o/oauth2/v2/auth?response_type=code&access_type=offline&prompt=consent" +
                        "&client_id=" + Uri.EscapeDataString(clientId) +
                        "&redirect_uri=" + Uri.EscapeDataString(RedirectUriFor(Name)) +
                        "&scope=" + Uri.EscapeDataString("https://www.googleapis.com/auth/youtube") +
                        "&code_challenge_method=S256&code_challenge=" + challenge +
                        "&state=" + _pendingState);
            return Task.FromResult(GetStatus());
        }

        public override async Task<string> CallbackAsync(IQueryCollection query)
        {
            if (_pendingState == null || query["state"] != _pendingState)
                return Html("YouTube", L.T("Este link de login expirou. Comece de novo pelo DeckOS."));
            _pendingState = null;
            if (!string.IsNullOrEmpty(query["error"]))
            {
                _error = query["error"] == "access_denied" ? "Login cancelado." : $"O Google recusou: {query["error"]}";
                return Html("YouTube", query["error"] == "access_denied"
                    ? L.T("Login cancelado.")
                    : L.T("O Google recusou: {error}", ("error", query["error"].ToString())));
            }
            var code = query["code"].ToString();
            if (string.IsNullOrWhiteSpace(code))
            {
                _error = "O Google não devolveu o código de autorização.";
                return Html("YouTube", L.T("O Google não devolveu o código de autorização."));
            }
            try
            {
                await _tokens.RequestAsync(new()
                {
                    ["grant_type"] = "authorization_code",
                    ["code"] = code,
                    ["redirect_uri"] = RedirectUriFor(Name),
                    ["client_id"] = Get("clientId") ?? "",
                    ["client_secret"] = Get("clientSecret") ?? "",
                    ["code_verifier"] = _pendingVerifier ?? "",
                });
                using var me = await CallAsync(HttpMethod.Get, "/channels?part=snippet&mine=true");
                if (me == null || !me.RootElement.TryGetProperty("items", out var items) ||
                    items.ValueKind != JsonValueKind.Array || items.GetArrayLength() == 0)
                    throw new InvalidOperationException("Esta conta Google não tem canal no YouTube.");
                Set(("channel", items[0].GetProperty("snippet").GetProperty("title").GetString()));
                _nextRefresh = DateTime.MinValue;
                await BroadcastAsync();
                return Html(L.T("YouTube conectado"), L.T("Canal {channel}. Pode fechar esta aba.", ("channel", Channel)));
            }
            catch (Exception ex)
            {
                _error = ex.Message;
                return Html("YouTube", L.T("Não deu certo: {error}", ("error", L.Message(ex))));
            }
        }

        public override async Task LogoutAsync()
        {
            var hadSession = Connected || _tokens.HasToken || _pendingState != null;
            if (hadSession) Clear("clientId", "clientSecret");
            else Clear();
            _pendingState = null;
            _pendingVerifier = null;
            _error = null;
            _live = false;
            _viewers = null;
            _title = null;
            _chatId = null;
            await BroadcastAsync();
        }

        public Task<JsonDocument?> CallAsync(HttpMethod method, string path, object? body = null) =>
            ApiCall.SendAsync(_http, _tokens, method, Api + path, body);

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                if (Connected && DateTime.UtcNow >= _nextRefresh && DeckHub.ConnectedCount > 0 && ActionsOfType(YouTubeProvider.TypeName).Any())
                {
                    _nextRefresh = DateTime.UtcNow.AddSeconds(60);
                    try { await RefreshAsync(); }
                    catch (Exception ex) { Logger.LogDebug(ex, "YouTube: falha ao ler a transmissão"); }
                }
                await Wait(TimeSpan.FromSeconds(2), stoppingToken);
            }
        }

        public async Task RefreshAsync()
        {
            using var doc = await CallAsync(HttpMethod.Get, "/liveBroadcasts?part=snippet&broadcastStatus=active&broadcastType=all");
            JsonElement items = default;
            var live = doc != null &&
                       doc.RootElement.TryGetProperty("items", out items) &&
                       items.ValueKind == JsonValueKind.Array &&
                       items.GetArrayLength() > 0;
            string? title = null, chatId = null;
            int? viewers = null;
            if (live)
            {
                var b = items[0];
                title = b.GetProperty("snippet").GetProperty("title").GetString();
                chatId = b.GetProperty("snippet").TryGetProperty("liveChatId", out var c) ? c.GetString() : null;
                using var video = await CallAsync(HttpMethod.Get, "/videos?part=liveStreamingDetails&id=" + b.GetProperty("id").GetString());
                if (video != null &&
                    video.RootElement.TryGetProperty("items", out var details) &&
                    details.ValueKind == JsonValueKind.Array &&
                    details.GetArrayLength() > 0 &&
                    details[0].TryGetProperty("liveStreamingDetails", out var lsd) &&
                    lsd.TryGetProperty("concurrentViewers", out var cv) && int.TryParse(cv.GetString(), out var n))
                    viewers = n;
            }
            var changed = live != _live || viewers != _viewers || title != _title;
            (_live, _viewers, _title, _chatId) = (live, viewers, title, chatId);
            if (changed) await BroadcastAsync();
        }

        public async Task SendChatAsync(string message)
        {
            if (_chatId == null) await RefreshAsync();
            if (_chatId == null) throw new InvalidOperationException("Nenhuma transmissão ao vivo no canal.");
            await CallAsync(HttpMethod.Post, "/liveChat/messages?part=snippet", new
            {
                snippet = new
                {
                    liveChatId = _chatId,
                    type = "textMessageEvent",
                    textMessageDetails = new { messageText = message },
                },
            });
        }

        public void RefreshSoon() => _nextRefresh = DateTime.UtcNow.AddSeconds(2);
    }
}
