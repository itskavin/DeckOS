using DeckOS.Audio;
using NAudio.CoreAudioApi;
using System.Collections.Generic;
using System.Linq;

namespace DeckOS.Audio
{
    internal class NAudioSessionAdapter : IAudioSession
    {
        private readonly AudioSessionControl _session;

        public NAudioSessionAdapter(AudioSessionControl session)
        {
            _session = session;
        }

        public bool IsSystemSoundsSession => _session.IsSystemSoundsSession;

        public uint GetProcessID() => _session.GetProcessID;

        public float Volume => _session.SimpleAudioVolume.Volume;

        public bool Mute
        {
            get => _session.SimpleAudioVolume.Mute;
            set => _session.SimpleAudioVolume.Mute = value;
        }

        public void Dispose() => _session.Dispose();
    }

    internal class NAudioDeviceAdapter : IAudioDevice
    {
        private readonly MMDevice _device;
        private readonly string _id;
        private AudioDeviceNames? _names;
        private bool _namesResolved;

        public NAudioDeviceAdapter(MMDevice device, string? id = null, AudioDeviceNames? names = null)
        {
            _device = device;
            _id = id ?? device.ID;
            if (names.HasValue)
            {
                _names = names;
                _namesResolved = true;
            }
        }

        public string Id => _id;

        public string FriendlyName => ResolveNames().FriendlyName;

        public string DeviceFriendlyName => ResolveNames().DeviceFriendlyName;

        private AudioDeviceNames ResolveNames()
        {
            if (!_namesResolved)
            {
                _names = CoreAudioMetadata.TryReadDeviceNames(_id);
                _namesResolved = true;
            }
            return _names ?? new AudioDeviceNames("Unknown", "Unknown");
        }

        public DataFlow DataFlow => _device.DataFlow;

        public float MasterVolumeLevelScalar => _device.AudioEndpointVolume.MasterVolumeLevelScalar;

        public bool Mute => _device.AudioEndpointVolume.Mute;

        public IEnumerable<IAudioSession> Sessions
        {
            get
            {
                var sessions = _device.AudioSessionManager.Sessions;
                for (int i = 0; i < sessions.Count; i++)
                {
                    // sessions[i] cria um AudioSessionControl novo a cada acesso; ler uma vez
                    // e entregar a posse ao chamador, que descarta via using.
                    yield return new NAudioSessionAdapter(sessions[i]);
                }
            }
        }

        public void Dispose() => _device.Dispose();
    }

    public class NAudioDeviceEnumerator : IAudioDeviceEnumerator
    {
        public IEnumerable<IAudioDevice> EnumerateAudioEndPoints(DataFlow dataFlow, DeviceState deviceState)
        {
            // Lê FriendlyName/DeviceFriendlyName direto via IPropertyStore.GetValue em ~1–6ms
            // para evitar a varredura linear de ~196 propriedades do NAudio por endpoint.
            var deviceNames = CoreAudioMetadata.ReadActiveDeviceNames(dataFlow, deviceState);

            // O enumerador em si é IDisposable e não é mais preciso após materializar a
            // lista (os MMDevice ficam nos adapters). Descartá-lo evita acumular objetos COM.
            // Os devices retornados são do chamador — ele é quem os descarta.
            using var enumerator = new MMDeviceEnumerator();
            return enumerator.EnumerateAudioEndPoints(dataFlow, deviceState)
                .Select(d =>
                {
                    var id = d.ID;
                    AudioDeviceNames? names = deviceNames.TryGetValue(id, out var found) ? found : null;
                    return (IAudioDevice)new NAudioDeviceAdapter(d, id, names);
                })
                .ToList();
        }

        public IAudioDevice? GetDevice(string id)
        {
            try
            {
                using var devices = new MMDeviceEnumerator();
                var dev = devices.GetDevice(id);
                if (dev == null) return null;
                if (dev.State != DeviceState.Active)
                {
                    dev.Dispose();
                    return null;
                }
                var devId = dev.ID;
                var names = CoreAudioMetadata.TryReadDeviceNames(devId);
                return new NAudioDeviceAdapter(dev, devId, names);
            }
            catch
            {
                return null;
            }
        }
    }
}
