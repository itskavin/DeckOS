using DeckOS.Audio;
using NAudio.CoreAudioApi;
using System.Collections.Generic;
using System.Linq;

namespace DeckOS
{
    /// <summary>
    /// Snapshot (DTO) de um dispositivo de áudio e suas sessões.
    ///
    /// Regra de ouro deste tipo: ele NUNCA guarda referência COM viva. Todo
    /// <see cref="MMDevice"/>/<see cref="AudioSessionControl"/> usado para montar o snapshot é
    /// descartado antes de o objeto ser devolvido. Sem isso, cada poll de
    /// /api/v1/Mixer/{in,out} (a cada 60s) deixava para trás um proxy COM por dispositivo e
    /// vários por sessão; a liberação só acontecia na finalização do GC, que precisa
    /// marshalar de volta para o apartamento de origem — o que empilhava threads bloqueadas
    /// em espera de RPC (LpcReply) até o processo passar de 14 mil threads / 1 GB de RAM.
    /// </summary>
    public class MixerMaster
    {
        private Dictionary<int, MixerChannel>? channels;

        public MixerMaster()
        {
            channels = new Dictionary<int, MixerChannel>();
        }
        public MixerMaster(MMDevice device)
            : this(device, prefetchedNames: null, processCache: null)
        {
        }

        internal MixerMaster(
            MMDevice device,
            AudioDeviceNames? prefetchedNames,
            Dictionary<int, ProcessSessionMetadata>? processCache)
        {
            newMaster(device, prefetchedNames, processCache);
        }

        public MixerMaster(DeckOS.Audio.IAudioDevice device)
            : this(device, processCache: null)
        {
        }

        internal MixerMaster(
            DeckOS.Audio.IAudioDevice device,
            Dictionary<int, ProcessSessionMetadata>? processCache)
        {
            // construct from abstraction
            Id = device.Id;
            var friendly = device.FriendlyName ?? string.Empty;
            Title = CoreAudioMetadata.ExtractTitle(friendly);
            Description = device.DeviceFriendlyName;
            var masterVolume = device.MasterVolumeLevelScalar;
            Volume = (int)(masterVolume * 100);
            Mute = device.Mute;
            Icon = null;
            if (device.DataFlow == DataFlow.Render)
            {
                var passCache = processCache ?? new Dictionary<int, ProcessSessionMetadata>();
                channels = new Dictionary<int, MixerChannel>();
                foreach (var session in device.Sessions)
                {
                    // A sessão é COM por baixo do adapter; descartar após copiar os valores.
                    using (session)
                    {
                        if (session.IsSystemSoundsSession) continue;
                        var channel = new MixerChannel();
                        // O comentário anterior dizia que a abstração não expunha info de
                        // processo para extrair ícone — mas expõe GetProcessID(), que é tudo
                        // de que o DescribeFromProcess precisa. Sem esta chamada os canais
                        // vinham sem nome e sem ícone por este caminho.
                        var pid = (int)session.GetProcessID();
                        channel.Id = pid;
                        channel.DescribeFromProcess(pid, passCache);
                        channel.Mute = session.Mute;
                        channel.Volume = (int)(session.Volume * masterVolume * 100);
                        channels[channel.Id] = channel;
                    }
                }
            }
        }
        public MixerMaster(string idString)
        {
            using var devices = new MMDeviceEnumerator();
            MMDevice? device = null;
            try
            {
                device = devices.GetDevice(idString);
            }
            catch
            {
                device = null;
            }

            if (device == null) return;

            using (device)
            {
                if (device.State == DeviceState.Unplugged ||
                    device.State == DeviceState.NotPresent ||
                    device.State == DeviceState.Disabled) return;

                newMaster(device, prefetchedNames: null, processCache: null);
            }
        }

        private void newMaster(
            MMDevice device,
            AudioDeviceNames? prefetchedNames,
            Dictionary<int, ProcessSessionMetadata>? processCache)
        {
            Id = device.ID;
            var names = prefetchedNames ?? CoreAudioMetadata.TryReadDeviceNames(Id);
            var friendly = names?.FriendlyName ?? string.Empty;
            Title = CoreAudioMetadata.ExtractTitle(friendly);
            Description = names?.DeviceFriendlyName ?? "Unknown";
            var endpointVolume = device.AudioEndpointVolume;
            var masterVolume = endpointVolume.MasterVolumeLevelScalar;
            Volume = (int)(masterVolume * 100);
            Mute = endpointVolume.Mute;
            Icon = null;
            if (device.DataFlow == DataFlow.Render)
            {
                var passCache = processCache ?? new Dictionary<int, ProcessSessionMetadata>();
                var sessions = device.AudioSessionManager.Sessions;
                channels = new Dictionary<int, MixerChannel>();
                for (int i = 0; i < sessions.Count; i++)
                {
                    // sessions[i] materializa um AudioSessionControl NOVO a cada acesso
                    // (SessionCollection não cacheia). Ler o indexer uma única vez por
                    // iteração e descartar: antes eram três leituras por sessão, ou seja,
                    // três proxies COM vazados por sessão por chamada.
                    using var session = sessions[i];
                    if (session.IsSystemSoundsSession) continue;
                    channels[(int)session.GetProcessID] = new MixerChannel(session, masterVolume, passCache);
                }
            }
        }
        public static List<MixerMaster> GetAllMixers(DataFlow dataFlow, DeviceState deviceState)
        {
            var devices = new List<MixerMaster>();
            var deviceNames = CoreAudioMetadata.ReadActiveDeviceNames(dataFlow, deviceState);
            var processCache = dataFlow == DataFlow.Render
                ? new Dictionary<int, ProcessSessionMetadata>()
                : null;
            using var en = new MMDeviceEnumerator();
            foreach (MMDevice d in en.EnumerateAudioEndPoints(dataFlow, deviceState))
            {
                // O MixerMaster copia tudo que precisa no construtor, então o MMDevice pode
                // (e deve) morrer aqui — ele não sobrevive até a serialização da resposta.
                using (d)
                {
                    AudioDeviceNames? names = deviceNames.TryGetValue(d.ID, out var found) ? found : null;
                    devices.Add(new MixerMaster(d, names, processCache));
                }
            }
            return devices;
        }

        public static List<MixerMaster> GetAllMixers(DeckOS.Audio.IAudioDeviceEnumerator enumerator, DataFlow dataFlow, DeviceState deviceState)
        {
            var devices = new List<MixerMaster>();
            var processCache = dataFlow == DataFlow.Render
                ? new Dictionary<int, ProcessSessionMetadata>()
                : null;
            foreach (var d in enumerator.EnumerateAudioEndPoints(dataFlow, deviceState))
            {
                using (d)
                {
                    devices.Add(new MixerMaster(d, processCache));
                }
            }
            return devices;
        }
        public MixerChannel? GetChannel(int id)
        {
            if (channels == null) return null;
            channels.TryGetValue(id, out var ch);
            return ch;
        }

        public MixerMaster? SetOptions(string id, MixerData data)
        {
            using var devices = new MMDeviceEnumerator();
            MMDevice? device;
            try { device = devices.GetDevice(id); }
            catch { return null; }
            if (device == null) return null;

            using (device)
            {
                var masterVolume = device.AudioEndpointVolume.MasterVolumeLevelScalar;

                if (data.Session >= 0 && device.DataFlow.CompareTo(DataFlow.Render) == 0)
                {
                    // Resolve a sessão AO VIVO pelo PID, no device recém-aberto. Antes usava
                    // o AudioSessionControl que este MixerMaster tinha guardado desde a
                    // construção — um proxy COM potencialmente obsoleto (e vazado).
                    var sessions = device.AudioSessionManager.Sessions;
                    for (int i = 0; i < sessions.Count; i++)
                    {
                        using var session = sessions[i];
                        if (session.IsSystemSoundsSession) continue;
                        if ((int)session.GetProcessID != data.Session) continue;
                        MixerChannel.Apply(session, data, masterVolume);
                        break;
                    }
                }
                else
                {
                    if (data.Volume.HasValue)
                    {
                        var clamped = Math.Clamp(data.Volume.Value / 100.0f, 0.0f, 1.0f);
                        device.AudioEndpointVolume.MasterVolumeLevelScalar = clamped;
                        if (data.Mute.HasValue)
                            device.AudioEndpointVolume.Mute = data.Mute.Value;
                        else if (clamped > 0.0f)
                            device.AudioEndpointVolume.Mute = false;
                    }
                    else if (data.Mute.HasValue)
                    {
                        device.AudioEndpointVolume.Mute = data.Mute.Value;
                    }
                }

                return new MixerMaster(device);
            }
        }

        public string? Id { get; set; }
        public string? Title { get; set; }
        public string? Description { get; set; }
        public int Volume { get; set; }
        public string? Icon { get; set; }
        public bool Mute { get; set; }
        public List<MixerChannel>? Channels => channels?.Values.ToList();
    }
}
