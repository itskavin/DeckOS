using System.Collections.Generic;
using System.Threading.Tasks;
using DeckOS.Lib.Input;
using DeckOS.Models;
using DeckOS.Services;

namespace DeckOS.Platform
{
    // Servicos que cada sistema faz do seu jeito. O registro por sistema fica em
    // ServiceRegistration.AddPlatform; as implementacoes, em Platform/Windows, MacOS e Linux.
    // Quem nao tem um recurso lanca ToolMissingException (falta um pacote) ou
    // PlatformFeatureException (o sistema nao tem), e o /api/platform avisa a interface antes.

    /// <summary>
    /// Teclado. As teclas sao virtual-keys do Windows (o que os botoes salvos ja guardam):
    /// macOS e Linux traduzem para os codigos deles.
    /// </summary>
    public interface IKeyboardInput
    {
        void KeyDown(ushort vk);
        void KeyUp(ushort vk);

        /// <summary>Uma sequencia ja lida (<see cref="KeySequence.Parse"/>), toque a toque.</summary>
        void Send(IReadOnlyList<KeyStroke> strokes);

        /// <summary>A tecla que produz o caractere (pontuacao) no layout em uso, se souber.</summary>
        bool TryResolveChar(char c, out ushort vk);
    }

    /// <summary>Volume e mudo do dispositivo padrao (ou de um especifico, no Windows).</summary>
    public interface ISystemVolume
    {
        /// <summary>
        /// Le (sem nada para mudar) ou aplica volume/mudo. deviceId nulo ou "default" = o
        /// padrao do sistema. Null se nao ha dispositivo.
        /// </summary>
        DeviceAudioState? Apply(string? deviceId, bool input, int? volume = null, int? delta = null,
            bool? mute = null, bool toggleMute = false);

        /// <summary>Volume (0-100) e mudo das sessoes de um app; null se o app nao toca nada.</summary>
        (int Volume, bool Mute)? AppVolume(string app, int? volume);
    }

    /// <summary>Travar, suspender e desligar a tela.</summary>
    public interface IPowerActions
    {
        void Lock();
        void Sleep();
        void DisplayOff();
    }

    /// <summary>Leituras do monitor de sistema (CPU, RAM, GPU, rede, discos).</summary>
    public interface ISystemMetrics
    {
        /// <summary>Uso de CPU desde a ultima leitura, 0-100.</summary>
        float CpuPercent();

        /// <summary>RAM em MB e % usada; zeros se nao der para ler.</summary>
        (float TotalMb, float AvailableMb, float LoadPercent) Memory();

        /// <summary>Uso de GPU 0-100; 0 onde nao ha como ler.</summary>
        float GpuPercent();

        /// <summary>Bytes enviados e recebidos desde o boot, somando as placas ativas.</summary>
        (long Sent, long Received) NetworkBytes();

        List<DiskStat> Disks();
    }

    /// <summary>A janela em foco e os apps com janela (troca automatica de perfil).</summary>
    public interface IForegroundWindow
    {
        /// <summary>Processo da janela em foco (sem .exe), ou null.</summary>
        (int Pid, string? Process)? Foreground();

        /// <summary>Apps com janela visivel: processo e titulo.</summary>
        IReadOnlyList<(string Process, string Title)> VisibleApps();
    }

    /// <summary>Midia que esta tocando: listar, comandar, posicao.</summary>
    public interface IMediaControlService
    {
        Task<List<MediaSessionInfo>> GetAllSessionsAsync(bool includeThumbnails = true);
        Task<MediaSessionInfo?> GetSessionByIdAsync(string sessionId);
        Task<MediaSessionInfo?> GetNowPlayingAsync(bool includeThumbnail);
        Task<bool> SeekAsync(double seconds);
        Task<bool> IsAnythingPlayingAsync();
        Task<MediaCommandResult> SendCommandAsync(string? sessionId, string command);
    }

    /// <summary>Um app instalado no computador (biblioteca "Apps deste computador").</summary>
    public sealed record InstalledApp(string Id, string Name, string Path)
    {
        /// <summary>Argumentos para abrir (Store do Windows, Exec do .desktop); vazio quase sempre.</summary>
        public string? Arguments { get; init; }

        /// <summary>Onde achar o icone (arquivo, .icns, nome do tema...); interno.</summary>
        public string? IconSource { get; init; }
    }

    /// <summary>Apps instalados e os icones deles.</summary>
    public interface IInstalledApps
    {
        IReadOnlyList<InstalledApp> List();

        InstalledApp? Find(string id);

        /// <summary>PNG (ou SVG, no Linux) do icone; null se o app nao tem um que sirva.</summary>
        Task<(byte[] Data, string ContentType)?> GetIconAsync(string id);
    }
}

namespace DeckOS.Services
{
    /// <summary>Resultado de um comando de transporte: qual sessão recebeu e como ela ficou.</summary>
    public class MediaCommandResult
    {
        public bool Success { get; set; }

        /// <summary>Sessão que de fato recebeu o comando — pode não ser a pedida, quando o id
        /// configurado no botão já não existe.</summary>
        public string? SessionId { get; set; }

        /// <summary>Estado de reprodução logo após o comando; null quando não deu pra ler.</summary>
        public bool? Playing { get; set; }
    }

    public class MediaSessionInfo
    {
        public string? Id { get; set; }
        public string? Title { get; set; }
        public string? Artist { get; set; }
        public string? AlbumTitle { get; set; }
        public string? ThumbnailBase64 { get; set; }
        public string? PlaybackStatus { get; set; }
        public bool CanPlayPause { get; set; }
        public bool CanGoNext { get; set; }
        public bool CanGoPrevious { get; set; }
        public double Position { get; set; }
        public double Duration { get; set; }
    }

    /// <summary>Estado de audio de um dispositivo depois de uma mudanca.</summary>
    public class DeviceAudioState
    {
        public string Id { get; set; } = string.Empty;
        public string Title { get; set; } = string.Empty;

        /// <summary>0-100.</summary>
        public int Volume { get; set; }

        public bool Mute { get; set; }
    }
}
