using System;
using System.Threading.Tasks;
using DeckOS.Hubs;
using DeckOS.Services;
using Microsoft.AspNetCore.SignalR;
using Microsoft.Extensions.Logging;

namespace DeckOS.Actions.Providers
{
    /// <summary>
    /// Volume e mudo por aplicativo ou por dispositivo.
    /// Parâmetros aceitos:
    ///   operation   : "toggleMute" (padrão) | "mute" | "unmute" | "setVolume"
    ///                 | "volumeUp" | "volumeDown"
    ///   processName : nome do processo (ex.: "Spotify") -> controla o áudio daquele app
    ///                 (só as operações de mudo)
    ///   deviceId    : id do dispositivo -> controla o dispositivo inteiro.
    ///                 "default" = dispositivo padrão do Windows (preferir isto a um id
    ///                 fixo: o id muda quando o usuário troca de fone/monitor)
    ///   deviceKind  : "output" (padrão) | "input" — só importa para deviceId="default"
    ///   volume      : 0-100 (usado com setVolume)
    ///   step        : passo em pontos percentuais do volumeUp/volumeDown (padrão 5)
    /// </summary>
    public class MixerProvider : IActionProvider
    {
        private readonly Platform.ISystemVolume _volume;
        private readonly IAudioControlService? _audio;
        private readonly IHubContext<DeckHub> _hub;
        private readonly ILogger<MixerProvider> _logger;

        public MixerProvider(Platform.ISystemVolume volume, IHubContext<DeckHub> hub, ILogger<MixerProvider> logger,
            IAudioControlService? audio = null)
        {
            _volume = volume;
            _audio = audio;
            _hub = hub;
            _logger = logger;
        }

        public string Type => "mixer";

        public ActionSchema Describe() => new()
        {
            Type = Type,
            Title = "Volume e mudo",
            Icon = "volume_up",
            Category = "Mídia",
            Stateful = true,
            Editor = "mixer",
        };

        public async Task ExecuteAsync(ActionContext c)
        {
            var operation = c.Operation("togglemute");
            var processName = c.Get("processName");
            var deviceId = c.Get("deviceId");

            int? volume = c.Get("volume").Length > 0 ? Math.Clamp(c.Int("volume", 0), 0, 100) : null;
            // Passo do volumeUp/volumeDown, em pontos percentuais.
            var step = Math.Clamp(c.Int("step", 5), 1, 50);

            var isVolumeOp = operation is "setvolume" or "volumeup" or "volumedown";

            // Alvo = aplicativo (por nome de processo): mute/toggle por sessao de audio.
            if (!string.IsNullOrWhiteSpace(processName))
            {
                if (isVolumeOp)
                {
                    // O IAudioControlService so expoe mudo por processo; volume por app ainda
                    // nao existe. Avisa em vez de silenciosamente nao fazer nada.
                    _logger.LogWarning(
                        "Mixer: '{Op}' nao e suportado por processo ('{Proc}'). " +
                        "Use um dispositivo como alvo para controlar volume.", operation, processName);
                    return;
                }

                // macOS: sem mudo por app.
                if (_audio == null)
                    throw new Platform.PlatformFeatureException("Mudo por app não está disponível neste sistema.");

                switch (operation)
                {
                    case "mute":
                        _audio.MuteByProcessName(processName, true);
                        break;
                    case "unmute":
                        _audio.MuteByProcessName(processName, false);
                        break;
                    default: // toggleMute
                        _audio.ToggleMuteByProcessName(processName);
                        break;
                }
                var muted = _audio.GetMuteStateByProcessName(processName);
                await _hub.Clients.All.SendAsync("ReceiveMuteState", new { processName, muted });
                _logger.LogInformation("Mixer: '{Op}' no processo '{Proc}' (muted={Muted})", operation, processName, muted);
                return;
            }

            // Alvo = dispositivo (por id): volume/mudo do dispositivo inteiro.
            if (!string.IsNullOrWhiteSpace(deviceId))
            {
                var isInput = string.Equals(c.Get("deviceKind"), "input", StringComparison.OrdinalIgnoreCase);

                // "default" (o padrao do sistema) e resolvido pelo ISystemVolume na hora: o id do
                // endpoint muda quando o usuario troca de fone/monitor. Fora do Windows, todo id
                // vale o padrao.
                var state = operation switch
                {
                    "mute" => _volume.Apply(deviceId, isInput, mute: true),
                    "unmute" => _volume.Apply(deviceId, isInput, mute: false),
                    "setvolume" => _volume.Apply(deviceId, isInput, volume: volume ?? 0),
                    "volumeup" => _volume.Apply(deviceId, isInput, delta: step),
                    "volumedown" => _volume.Apply(deviceId, isInput, delta: -step),
                    _ => _volume.Apply(deviceId, isInput, toggleMute: true),
                };

                if (state == null)
                {
                    _logger.LogWarning("Mixer: '{Op}' falhou no dispositivo '{Dev}' ({Kind})", operation, deviceId, isInput ? "entrada" : "saida");
                    return;
                }

                await _hub.Clients.All.SendAsync("ReceiveVolumeChange", new
                {
                    deviceId = state.Id,
                    type = isInput ? "input" : "output",
                    data = state
                });

                _logger.LogInformation("Mixer: '{Op}' em '{Title}' -> volume={Vol} mudo={Mute}",
                    operation, state.Title, state.Volume, state.Mute);
                return;
            }

            _logger.LogWarning("Mixer action ignorada: faltou 'processName' ou 'deviceId'.");
        }
    }
}
