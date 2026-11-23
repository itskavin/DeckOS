using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.RegularExpressions;
using DeckOS.Services;

namespace DeckOS.Platform.Linux
{
    /// <summary>Leitura da saida do wpctl e do pactl. Separado para os testes.</summary>
    public static class PulseParse
    {
        /// <summary>"Volume: 0.40 [MUTED]" (wpctl get-volume) para (40, true).</summary>
        public static (int Volume, bool Mute)? Wpctl(string output)
        {
            var m = Regex.Match(output, @"Volume:\s*([0-9]+(?:\.[0-9]+)?)");
            if (!m.Success) return null;
            var v = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
            return ((int)Math.Round(v * 100), output.Contains("[MUTED]", StringComparison.OrdinalIgnoreCase));
        }

        /// <summary>Primeiro "NN%" de uma linha de volume do pactl (os canais costumam andar juntos).</summary>
        public static int? Percent(string output)
        {
            var m = Regex.Match(output, @"(\d+)%");
            return m.Success ? int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) : null;
        }

        /// <summary>"Mute: yes" / "Mudo: sim"... o pactl traduz; vale o sim/yes.</summary>
        public static bool Mute(string output)
        {
            var value = output.Split(':', 2).ElementAtOrDefault(1)?.Trim().ToLowerInvariant() ?? "";
            return value is "yes" or "sim" or "sí" or "si" or "oui" or "ja" or "true" or "1";
        }

        /// <summary>Um fluxo de audio de app (Sink Input) do "pactl list sink-inputs".</summary>
        public sealed record SinkInput(int Index, string? Binary, string? AppName, int Volume, bool Mute);

        /// <summary>
        /// Blocos "Sink Input #N" com o volume, o mudo e o processo. Le por posicao e pelas
        /// chaves das propriedades (application.*), que o pactl nao traduz.
        /// </summary>
        public static List<SinkInput> SinkInputs(string output)
        {
            var list = new List<SinkInput>();
            foreach (var block in Regex.Split(output, @"^(?=\S.*#\d+\s*$)", RegexOptions.Multiline))
            {
                var header = Regex.Match(block, @"^\S.*#(\d+)\s*$", RegexOptions.Multiline);
                if (!header.Success) continue;
                var index = int.Parse(header.Groups[1].Value, CultureInfo.InvariantCulture);
                string? Prop(string key)
                {
                    var m = Regex.Match(block, "^\\s*" + Regex.Escape(key) + "\\s*=\\s*\"(.*)\"\\s*$", RegexOptions.Multiline);
                    return m.Success ? m.Groups[1].Value : null;
                }
                // Linhas de volume e mudo: as primeiras com "%" e com ":" sim/nao depois de "Sink:".
                var volumeLine = block.Split('\n').FirstOrDefault(l => l.Contains('%') && !l.TrimStart().StartsWith("balance", StringComparison.OrdinalIgnoreCase));
                var muteLine = block.Split('\n').Select(l => l.Trim())
                    .FirstOrDefault(l => Regex.IsMatch(l, @"^(Mute|Mudo|Silencio|Silenciado|Muet|Stumm)\s*:", RegexOptions.IgnoreCase));
                list.Add(new SinkInput(index,
                    Prop("application.process.binary"),
                    Prop("application.name"),
                    volumeLine != null ? Percent(volumeLine) ?? 0 : 0,
                    muteLine != null && Mute(muteLine)));
            }
            return list;
        }

        /// <summary>O fluxo e deste app? Compara o binario e o nome, sem diferenciar maiusculas nem .exe.</summary>
        public static bool IsApp(SinkInput s, string app)
        {
            app = app.Trim();
            if (app.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) app = app[..^4];
            return string.Equals(s.Binary, app, StringComparison.OrdinalIgnoreCase) ||
                   string.Equals(s.AppName, app, StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>
    /// Volume e mudo do padrao pelo wpctl (PipeWire/WirePlumber), ou pelo pactl (PulseAudio,
    /// e pipewire-pulse) quando nao ha wpctl.
    /// </summary>
    public sealed class LinuxSystemVolume : ISystemVolume
    {
        public DeviceAudioState? Apply(string? deviceId, bool input, int? volume = null, int? delta = null,
            bool? mute = null, bool toggleMute = false)
        {
            // Um id de dispositivo do Windows nao existe aqui: vale o padrao.
            var current = Read(input);
            if (current == null) return null;
            var (vol, muted) = current.Value;

            if (volume.HasValue || delta.HasValue)
            {
                var target = Math.Clamp(volume ?? vol + delta!.Value, 0, 100);
                SetVolume(input, target);
                // Mesmo comportamento do Windows: subir o volume de um mudo desmuta.
                if (target > 0 && !mute.HasValue && !toggleMute && muted) SetMute(input, false);
            }
            if (toggleMute) SetMute(input, !muted);
            else if (mute.HasValue) SetMute(input, mute.Value);

            var after = Read(input) ?? current.Value;
            return new DeviceAudioState
            {
                Id = "default",
                Title = input ? "Microfone" : "Saída de áudio",
                Volume = after.Volume,
                Mute = after.Mute,
            };
        }

        private static bool UseWpctl => Tools.Has("wpctl");

        private static string WpTarget(bool input) => input ? "@DEFAULT_AUDIO_SOURCE@" : "@DEFAULT_AUDIO_SINK@";

        private static string PaTarget(bool input) => input ? "@DEFAULT_SOURCE@" : "@DEFAULT_SINK@";

        private static string PaKind(bool input) => input ? "source" : "sink";

        private static (int Volume, bool Mute)? Read(bool input)
        {
            if (UseWpctl) return PulseParse.Wpctl(Tools.Check("wpctl", new[] { "get-volume", WpTarget(input) }));
            Tools.Require("pactl", "pulseaudio-utils");
            var vol = PulseParse.Percent(Tools.Check("pactl", new[] { $"get-{PaKind(input)}-volume", PaTarget(input) }));
            if (vol == null) return null;
            return (vol.Value, PulseParse.Mute(Tools.Check("pactl", new[] { $"get-{PaKind(input)}-mute", PaTarget(input) })));
        }

        private static void SetVolume(bool input, int percent)
        {
            if (UseWpctl) Tools.Check("wpctl", new[] { "set-volume", WpTarget(input), (percent / 100.0).ToString("0.00", CultureInfo.InvariantCulture) });
            else Tools.Check("pactl", new[] { $"set-{PaKind(input)}-volume", PaTarget(input), percent + "%" });
        }

        private static void SetMute(bool input, bool mute)
        {
            if (UseWpctl) Tools.Check("wpctl", new[] { "set-mute", WpTarget(input), mute ? "1" : "0" });
            else Tools.Check("pactl", new[] { $"set-{PaKind(input)}-mute", PaTarget(input), mute ? "1" : "0" });
        }

        /// <summary>Volume por app pelos Sink Inputs do pactl (funciona no PipeWire com pipewire-pulse).</summary>
        public (int Volume, bool Mute)? AppVolume(string app, int? volume)
        {
            var streams = LinuxAudioControl.Streams().Where(s => PulseParse.IsApp(s, app)).ToList();
            if (streams.Count == 0) return null;
            if (volume.HasValue)
            {
                foreach (var s in streams)
                    Tools.Check("pactl", new[] { "set-sink-input-volume", s.Index.ToString(CultureInfo.InvariantCulture), Math.Min(volume.Value, 100) + "%" });
                return (Math.Min(volume.Value, 100), streams.Any(s => s.Mute));
            }
            return (streams[0].Volume, streams.Any(s => s.Mute));
        }
    }

    /// <summary>Mudo por app (o IAudioControlService do Windows) pelos Sink Inputs do pactl.</summary>
    public sealed class LinuxAudioControl : IAudioControlService
    {
        internal static List<PulseParse.SinkInput> Streams()
        {
            Tools.Require("pactl", "pulseaudio-utils");
            return PulseParse.SinkInputs(Tools.Check("pactl", new[] { "list", "sink-inputs" }));
        }

        public int MuteByProcessName(string processName, bool mute)
        {
            if (string.IsNullOrEmpty(processName)) return 0;
            var affected = 0;
            foreach (var s in Streams().Where(s => PulseParse.IsApp(s, processName)))
            {
                Tools.Check("pactl", new[] { "set-sink-input-mute", s.Index.ToString(CultureInfo.InvariantCulture), mute ? "1" : "0" });
                affected++;
            }
            return affected;
        }

        public bool ToggleMuteByProcessName(string processName)
        {
            var newState = !(GetMuteStateByProcessName(processName) ?? false);
            MuteByProcessName(processName, newState);
            return newState;
        }

        public bool? GetMuteStateByProcessName(string processName)
        {
            if (string.IsNullOrEmpty(processName)) return null;
            return Streams().FirstOrDefault(s => PulseParse.IsApp(s, processName))?.Mute;
        }
    }
}
