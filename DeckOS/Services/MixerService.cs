using System.Diagnostics;
using DeckOS.Audio;
using DeckOS.Mixer;
using NAudio.CoreAudioApi;
using Microsoft.Extensions.Logging;

namespace DeckOS.Services
{
    public class MixerService
    {
        private readonly ILogger<MixerService> _logger;
        private readonly DeckOS.Audio.IAudioDeviceEnumerator _enumerator;

        public MixerService(ILogger<MixerService> logger, DeckOS.Audio.IAudioDeviceEnumerator enumerator)
        {
            _logger = logger;
            _enumerator = enumerator;
        }

        public List<MixerEntity> FindAllOutputs()
        {
            var sw = _logger.IsEnabled(LogLevel.Debug) ? Stopwatch.StartNew() : null;
            var result = MixerMaster.GetAllMixers(_enumerator, DataFlow.Render, DeviceState.Active)
                .Select(m => new MixerEntity(m))
                .ToList();
            if (sw != null)
            {
                sw.Stop();
                _logger.LogDebug("FindAllOutputs completed in {ElapsedMs}ms ({Count} devices)", sw.ElapsedMilliseconds, result.Count);
            }
            return result;
        }

        public List<MixerEntity> FindAllInputs()
        {
            var sw = _logger.IsEnabled(LogLevel.Debug) ? Stopwatch.StartNew() : null;
            var result = MixerMaster.GetAllMixers(_enumerator, DataFlow.Capture, DeviceState.Active)
                .Select(m => new MixerEntity(m))
                .ToList();
            if (sw != null)
            {
                sw.Stop();
                _logger.LogDebug("FindAllInputs completed in {ElapsedMs}ms ({Count} devices)", sw.ElapsedMilliseconds, result.Count);
            }
            return result;
        }

        /// <summary>
        /// Id do dispositivo padrao do Windows para o fluxo pedido, ou null se nao houver.
        /// Botao de volume guarda "default" em vez de um id fixo: o id do endpoint muda
        /// quando o usuario troca de fone/monitor, e um botao apontando pro id antigo passa a
        /// nao fazer nada.
        /// </summary>
        public string? GetDefaultDeviceId(DataFlow flow = DataFlow.Render)
        {
            try
            {
                using var en = new MMDeviceEnumerator();
                using var device = en.GetDefaultAudioEndpoint(flow, Role.Multimedia);
                return device?.ID;
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Mixer: sem dispositivo padrao para {Flow}", flow);
                return null;
            }
        }

        /// <summary>
        /// Aplica volume e/ou mudo no dispositivo inteiro e devolve o estado resultante
        /// (null se o dispositivo nao existe mais ou nao esta ativo).
        ///
        /// Existe separado do caminho MixerData/MixerMaster.SetOptions porque aquele nao
        /// consegue expressar "volume zero": ele so aplica o volume quando > 0 e, com 0,
        /// caia no ramo de mudo -- entao "setVolume 0" apenas desmutava o dispositivo.
        /// </summary>
        /// <param name="volume">Volume absoluto 0-100, ou null.</param>
        /// <param name="delta">Ajuste relativo em pontos percentuais, ou null.</param>
        /// <param name="mute">Estado de mudo desejado, ou null para nao mexer.</param>
        /// <param name="toggleMute">true = inverte o mudo atual (ignora <paramref name="mute"/>).</param>
        public DeviceAudioState? SetDeviceAudio(
            string deviceId, int? volume = null, int? delta = null, bool? mute = null, bool toggleMute = false)
        {
            using var en = new MMDeviceEnumerator();

            MMDevice? device;
            try { device = en.GetDevice(deviceId); }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Mixer: dispositivo '{Id}' nao encontrado", deviceId);
                return null;
            }
            if (device == null) return null;

            // O MMDevice e um proxy COM: liberar aqui, sempre. Guardar um vivo por chamada foi
            // o que um dia levou o processo a 14 mil threads (ver MixerMaster).
            using (device)
            {
                if (device.State != DeviceState.Active)
                {
                    _logger.LogWarning("Mixer: dispositivo '{Id}' nao esta ativo ({State})", deviceId, device.State);
                    return null;
                }

                var endpoint = device.AudioEndpointVolume;

                if (volume.HasValue || delta.HasValue)
                {
                    var current = (int)Math.Round(endpoint.MasterVolumeLevelScalar * 100);
                    var target = Math.Clamp(volume ?? current + delta!.Value, 0, 100);
                    endpoint.MasterVolumeLevelScalar = target / 100f;

                    // Subir o volume de um dispositivo mudo nao produz som nenhum, e o botao
                    // pareceria quebrado. Volume > 0 sem pedido explicito de mudo => desmuta.
                    if (target > 0 && !mute.HasValue && !toggleMute && endpoint.Mute)
                        endpoint.Mute = false;
                }

                if (toggleMute)
                    endpoint.Mute = !endpoint.Mute;
                else if (mute.HasValue)
                    endpoint.Mute = mute.Value;

                var id = device.ID;
                var friendly = CoreAudioMetadata.TryReadDeviceNames(id)?.FriendlyName ?? string.Empty;

                return new DeviceAudioState
                {
                    Id = id,
                    Title = CoreAudioMetadata.ExtractTitle(friendly),
                    Volume = (int)Math.Round(endpoint.MasterVolumeLevelScalar * 100),
                    Mute = endpoint.Mute
                };
            }
        }

        public MixerEntity? FindOne(string id)
        {
            _logger.LogDebug("Finding mixer by id {id}", id);
            if (string.IsNullOrWhiteSpace(id)) return null;

            var direct = _enumerator.GetDevice(id);
            if (direct != null)
            {
                using (direct)
                {
                    var directMaster = new MixerMaster(direct);
                    return string.IsNullOrEmpty(directMaster.Id) ? null : new MixerEntity(directMaster);
                }
            }

            var master = MixerMaster.GetAllMixers(_enumerator, DataFlow.Render, DeviceState.Active).FirstOrDefault(d => d.Id == id)
                      ?? MixerMaster.GetAllMixers(_enumerator, DataFlow.Capture, DeviceState.Active).FirstOrDefault(d => d.Id == id);

            return master != null ? new MixerEntity(master) : null;
        }
    }
}
