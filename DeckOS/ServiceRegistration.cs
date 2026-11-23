using System;
using DeckOS.Actions;
using DeckOS.Actions.Providers;
using DeckOS.Integrations;
using DeckOS.Platform;
using DeckOS.Services;
using DeckOS.Services.AiLimits;
using Microsoft.Extensions.DependencyInjection;

namespace DeckOS
{
    /// <summary>
    /// Registro dos servicos do DeckOS no DI, por area. O Program.cs so chama estes metodos.
    /// </summary>
    public static class ServiceRegistration
    {
        /// <summary>
        /// O que cada sistema faz do seu jeito (ver Platform/Interfaces.cs): Windows com o codigo
        /// de sempre (NAudio, WinRT, user32); macOS com osascript/pmset; Linux com xdotool,
        /// wpctl/pactl, playerctl, loginctl e o /proc.
        /// </summary>
        public static IServiceCollection AddPlatform(this IServiceCollection services)
        {
            services.AddSingleton(PlatformServices.Keyboard);
            services.AddSingleton(PlatformServices.Foreground);
#if WINDOWS
            if (OperatingSystem.IsWindows())
            {
                services.AddSingleton<DeckOS.Audio.IAudioDeviceEnumerator, DeckOS.Audio.NAudioDeviceEnumerator>();
                services.AddSingleton<MixerService>();
                services.AddSingleton<IAudioControlService, AudioControlService>();
                services.AddSingleton<IAppActivator, AppActivator>();
                services.AddSingleton<IMediaControlService, MediaControlService>();
                services.AddSingleton<ISystemVolume, Platform.Windows.WindowsSystemVolume>();
                services.AddSingleton<IPowerActions, Platform.Windows.WindowsPower>();
                services.AddSingleton<ISystemMetrics, Platform.Windows.WindowsSystemMetrics>();
                services.AddSingleton<IInstalledApps, Platform.Windows.WindowsInstalledApps>();
                return services;
            }
#endif
            if (OperatingSystem.IsMacOS())
            {
                // Sem mudo por app no macOS: o IAudioControlService fica de fora (a API responde 501).
                services.AddSingleton<IAppActivator, Platform.MacOS.MacAppActivator>();
                services.AddSingleton<IMediaControlService, Platform.MacOS.MacMediaControl>();
                services.AddSingleton<ISystemVolume, Platform.MacOS.MacSystemVolume>();
                services.AddSingleton<IPowerActions, Platform.MacOS.MacPower>();
                services.AddSingleton<ISystemMetrics, Platform.MacOS.MacSystemMetrics>();
                services.AddSingleton<IInstalledApps, Platform.MacOS.MacInstalledApps>();
            }
            else if (OperatingSystem.IsLinux())
            {
                services.AddSingleton<IAudioControlService, Platform.Linux.LinuxAudioControl>();
                services.AddSingleton<IAppActivator, Platform.Linux.LinuxAppActivator>();
                services.AddSingleton<IMediaControlService, Platform.Linux.LinuxMediaControl>();
                services.AddSingleton<ISystemVolume, Platform.Linux.LinuxSystemVolume>();
                services.AddSingleton<IPowerActions, Platform.Linux.LinuxPower>();
                services.AddSingleton<ISystemMetrics, Platform.Linux.LinuxSystemMetrics>();
                services.AddSingleton<IInstalledApps, Platform.Linux.LinuxInstalledApps>();
            }
            else
            {
                services.AddSingleton<IAppActivator, UnsupportedAppActivator>();
                services.AddSingleton<IMediaControlService, UnsupportedMedia>();
                services.AddSingleton<ISystemVolume, UnsupportedVolume>();
                services.AddSingleton<IPowerActions, UnsupportedPower>();
                services.AddSingleton<ISystemMetrics, UnsupportedMetrics>();
                services.AddSingleton<IInstalledApps, NoInstalledApps>();
            }
            return services;
        }

        /// <summary>Deck, estado dos botoes e servicos do sistema (audio, midia, janelas).</summary>
        public static IServiceCollection AddDeckCore(this IServiceCollection services)
        {
            services.AddSingleton<StreamDeckConfigService>();
            services.AddSingleton<ConnectedClientsService>();
            services.AddSingleton<ActionExecutorService>();
            services.AddHostedService<SystemMonitorService>();
            services.AddSingleton<SteamLibrary>();
            services.AddSingleton<BackupService>();
            services.AddSingleton<ButtonToggleService>();
            services.AddSingleton<Conditions>();
            services.AddSingleton<Lib.Input.MacroRecorder>();
            services.AddHostedSingleton<TimerService>();
            services.AddSingleton<AiUsageService>();
            services.AddSingleton(_ => new AiLimitsConfigStore());
            services.AddSingleton<IAiLimitsEnvironmentDetector, LocalAiLimitsEnvironmentDetector>();
            services.AddSingleton<ICodexAppServerRunner, ProcessCodexAppServerRunner>();
            services.AddSingleton<CliProxyPassiveAdapter>();
            services.AddSingleton<CodexLocalAdapter>();
            services.AddSingleton<ClaudeStatusLineAdapter>();
            services.AddSingleton<GeminiOtelAdapter>();
            services.AddSingleton<ManualDashboardAdapter>();
            services.AddSingleton<IAiLimitsSourceAdapter>(sp => sp.GetRequiredService<CliProxyPassiveAdapter>());
            services.AddSingleton<IAiLimitsSourceAdapter>(sp => sp.GetRequiredService<CodexLocalAdapter>());
            services.AddSingleton<IAiLimitsSourceAdapter>(sp => sp.GetRequiredService<ClaudeStatusLineAdapter>());
            services.AddSingleton<IAiLimitsSourceAdapter>(sp => sp.GetRequiredService<GeminiOtelAdapter>());
            services.AddSingleton<IAiLimitsSourceAdapter>(sp => sp.GetRequiredService<ManualDashboardAdapter>());
            services.AddHostedSingleton<AiLimitsService>();
            services.AddHostedSingleton<InfoService>();
            services.AddHostedSingleton<ForegroundWatcher>();
            services.AddHostedSingleton<Lib.UsbBridge>();
            services.AddHostedSingleton<TriggerService>();
            return services;
        }

        /// <summary>
        /// Tipos de acao do deck (ver Actions/IActionProvider.cs). A ordem aqui e a ordem do
        /// seletor de tipo no editor; as integracoes entram em <see cref="AddIntegrations"/>.
        /// </summary>
        public static IServiceCollection AddActionProviders(this IServiceCollection services)
        {
            services.AddSingleton<IActionProvider, KeyProvider>();
            services.AddSingleton<IActionProvider, HotkeyProvider>();
            services.AddSingleton<IActionProvider, LaunchAppProvider>();
            services.AddSingleton<IActionProvider, ActivateWindowProvider>();
            services.AddSingleton<IActionProvider, MediaProvider>();
            services.AddSingleton<IActionProvider, MixerProvider>();
            services.AddSingleton<IActionProvider, MultiProvider>();
            services.AddSingleton<IActionProvider, DiscordProvider>();
            services.AddSingleton<IActionProvider, ObsProvider>();
            services.AddSingleton<IActionProvider, SoundboardProvider>();
            services.AddSingleton<IActionProvider, TuyaProvider>();
#if WINDOWS
            if (OperatingSystem.IsWindows()) services.AddSingleton<IActionProvider, WindowsProvider>();
            else services.AddSingleton<IActionProvider, PowerProvider>();
#else
            // Mesmo tipo "windows" (travar, suspender, apagar a tela): perfis feitos no Windows seguem valendo.
            services.AddSingleton<IActionProvider, PowerProvider>();
#endif
            services.AddSingleton<IActionProvider, HttpProvider>();
            services.AddSingleton<IActionProvider, NetworkProvider>();
            services.AddSingleton<IActionProvider, ScriptProvider>();
            services.AddSingleton<IActionProvider, TimerProvider>();
            services.AddSingleton<IActionProvider, SteamProvider>();
            services.AddSingleton<IActionProvider, HomeAssistantProvider>();
            services.AddSingleton<IActionProvider, SpotifyProvider>();
            services.AddSingleton<IActionProvider, TwitchProvider>();
            services.AddSingleton<IActionProvider, YouTubeProvider>();
            services.AddSingleton<IActionProvider, StreamerBotProvider>();
            services.AddSingleton<IActionProvider, VTubeStudioProvider>();
            // O Voicemeeter so existe no Windows.
            if (OperatingSystem.IsWindows()) services.AddSingleton<IActionProvider, VoicemeeterProvider>();
            services.AddSingleton<IActionProvider, HueProvider>();
            services.AddSingleton<IActionProvider, KeyLightProvider>();
            services.AddSingleton<IActionProvider, GoveeProvider>();
            services.AddSingleton<IActionProvider, MqttProvider>();
            services.AddSingleton<IActionProvider, TallyProvider>();
            services.AddSingleton<IActionProvider, VmixProvider>();
            services.AddSingleton<IActionProvider, CompanionProvider>();
            services.AddSingleton<IActionProvider, MairlistProvider>();
            services.AddSingleton<IActionProvider, RadioDjProvider>();
            foreach (var clientOnly in ClientOnlyProvider.All())
                services.AddSingleton(clientOnly);
            return services;
        }

        /// <summary>Integracoes: cada uma tambem entra na lista comum (<see cref="IIntegration"/>).</summary>
        public static IServiceCollection AddIntegrations(this IServiceCollection services)
        {
            // Com controlador proprio e servico de reconexao.
            services.AddIntegration<DiscordRpcService>();
            services.AddHostedService<DiscordAutoConnect>();
            services.AddIntegration<ObsService>();
            services.AddHostedService<ObsAutoConnect>();
            services.AddIntegration<TuyaService>();
            services.AddHostedService<TuyaAutoConnect>();
            services.AddIntegration<SoundboardService>();

            // Com conta: tela de configuracao comum em /api/integrations/{nome}.
            services.AddAccountIntegration<HomeAssistantIntegration>();
            services.AddAccountIntegration<SpotifyIntegration>();
            services.AddAccountIntegration<TwitchIntegration>();
            services.AddAccountIntegration<YouTubeIntegration>();

            // Locais, sem conta na nuvem: com tela (pareamento, broker, endereco)...
            services.AddAccountIntegration<HueIntegration>();
            services.AddAccountIntegration<MqttIntegration>();
            services.AddAccountIntegration<StreamerBotIntegration>();
            services.AddAccountIntegration<VTubeStudioIntegration>();
            services.AddAccountIntegration<VmixIntegration>();
            services.AddAccountIntegration<CompanionIntegration>();
            services.AddAccountIntegration<MairlistIntegration>();
            services.AddAccountIntegration<RadioDjIntegration>();
            // ...e sem tela nenhuma (o IP vai em cada botao, o Voicemeeter e o do PC).
            services.AddSingleton<IVoicemeeterApi, VoicemeeterRemote>();
            services.AddSingleton<MicHoldService>();
            services.AddHostedSingleton<TallyService>();
            services.AddSingleton<GoveeLan>();
            return services;
        }

        private static void AddIntegration<T>(this IServiceCollection services) where T : class, IIntegration
        {
            services.AddSingleton<T>();
            services.AddSingleton<IIntegration>(sp => sp.GetRequiredService<T>());
        }

        private static void AddAccountIntegration<T>(this IServiceCollection services) where T : AccountIntegration
        {
            services.AddIntegration<T>();
            services.AddSingleton<AccountIntegration>(sp => sp.GetRequiredService<T>());
            services.AddHostedService(sp => sp.GetRequiredService<T>());
        }

        /// <summary>Servico em segundo plano que outros tambem injetam (uma instancia so).</summary>
        private static void AddHostedSingleton<T>(this IServiceCollection services)
            where T : class, Microsoft.Extensions.Hosting.IHostedService
        {
            services.AddSingleton<T>();
            services.AddHostedService(sp => sp.GetRequiredService<T>());
        }
    }
}
