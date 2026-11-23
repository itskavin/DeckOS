using DeckOS.Audio;
using NAudio.CoreAudioApi;
using System;
using System.Collections.Generic;

namespace DeckOS
{
    /// <summary>
    /// Snapshot (DTO) de uma sessão de áudio. NÃO guarda o <see cref="AudioSessionControl"/>:
    /// ele é COM e ficava vivo enquanto o objeto sobrevivia à serialização, vazando um proxy
    /// por sessão por poll (o app consulta /api/v1/Mixer/{in,out} a cada 60s). Todos os campos
    /// abaixo já são cópias por valor, então o COM pode ser liberado assim que o snapshot é
    /// montado. Para escrever, use <see cref="Apply"/> com uma sessão resolvida na hora.
    /// </summary>
    public class MixerChannel
    {
        public MixerChannel() { }

        public MixerChannel(AudioSessionControl session, float masterVolume)
            : this(session, masterVolume, passCache: null)
        {
        }

        internal MixerChannel(
            AudioSessionControl session,
            float masterVolume,
            Dictionary<int, ProcessSessionMetadata>? passCache)
        {
            Id = 0;
            Description = "Windows";

            if (!session.IsSystemSoundsSession)
            {
                DescribeFromProcess((int)session.GetProcessID, passCache);
            }

            Volume = (int)(session.SimpleAudioVolume.Volume * masterVolume * 100);
            Mute = session.SimpleAudioVolume.Mute;
        }

        /// <summary>
        /// Preenche Id/Descrição/Ícone a partir do PID da sessão.
        ///
        /// Compartilhado pelos dois caminhos de enumeração (NAudio direto e a abstração
        /// <see cref="DeckOS.Audio.IAudioDevice"/>): antes só o caminho do NAudio fazia
        /// isto, e a abstração devolvia canais sem nome nem ícone — divergência silenciosa,
        /// já que ambos populam o mesmo DTO.
        ///
        /// Um único lookup por PID por passagem; o ícone PNG é cacheado por caminho de
        /// executável validado pelo timestamp do arquivo, evitando extração GDI/PNG repetida
        /// sem mascarar processos encerrados ou títulos alterados.
        /// </summary>
        public void DescribeFromProcess(int pid) => DescribeFromProcess(pid, passCache: null);

        internal void DescribeFromProcess(int pid, Dictionary<int, ProcessSessionMetadata>? passCache)
        {
            var meta = ProcessMetadataCache.Shared.Resolve(pid, passCache);
            if (!meta.Found) return;

            Id = meta.Pid;
            Description = meta.Description;
            Icon = meta.Icon;
        }

        /// <summary>
        /// Aplica volume/mute numa sessão viva. Estático de propósito: quem chama é dono do
        /// <paramref name="session"/> e o descarta logo em seguida.
        /// </summary>
        public static void Apply(AudioSessionControl session, MixerData data, float masterVolume)
        {
            if (data.Volume.HasValue)
            {
                float volume = Math.Clamp(data.Volume.Value / 100.0f, 0.0f, 1.0f);
                float newVolume = masterVolume > 0.0f
                    ? Math.Clamp(volume / masterVolume, 0.0f, 1.0f)
                    : 0.0f;
                session.SimpleAudioVolume.Volume = newVolume;
                if (data.Mute.HasValue)
                    session.SimpleAudioVolume.Mute = data.Mute.Value;
                else if (newVolume > 0.0f)
                    session.SimpleAudioVolume.Mute = false;
            }
            else if (data.Mute.HasValue)
            {
                session.SimpleAudioVolume.Mute = data.Mute.Value;
            }
        }

        public int Id { get; set; }
        public string? Description { get; set; }
        public int Volume { get; set; }
        public string? Icon { get; set; }
        public bool Mute { get; set; }
    }
}
