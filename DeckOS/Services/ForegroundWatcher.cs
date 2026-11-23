using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using DeckOS.Platform;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Hubs;
using Microsoft.AspNetCore.SignalR;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace DeckOS.Services
{
    /// <summary>
    /// Troca de perfil pelo app em foco: observa a janela em primeiro plano e, quando o
    /// processo dela esta na lista AutoSwitchApps de um perfil, avisa os celulares
    /// (ReceiveAutoProfile). Quando o foco vai para um app sem perfil, avisa com profileId
    /// nulo e o celular volta para onde estava.
    ///
    /// Le o foco a cada 500 ms em vez de usar SetWinEventHook: o hook exige uma thread com
    /// laco de mensagens so para isso, e meio segundo de atraso nao se nota numa troca de
    /// perfil. Sem celular conectado, nao faz nada.
    /// </summary>
    public class ForegroundWatcher : BackgroundService
    {
        public const string Event = "ReceiveAutoProfile";

        private readonly IHubContext<DeckHub> _hub;
        private readonly StreamDeckConfigService _config;
        private readonly ILogger<ForegroundWatcher> _logger;

        private uint _lastPid;
        private string? _lastProcess;
        private string? _currentProfileId;

        private readonly IForegroundWindow _foreground;

        public ForegroundWatcher(IHubContext<DeckHub> hub, StreamDeckConfigService config, ILogger<ForegroundWatcher> logger,
            IForegroundWindow? foreground = null)
        {
            _hub = hub;
            _config = config;
            _logger = logger;
            _foreground = foreground ?? PlatformServices.Foreground;
        }

        /// <summary>Estado atual, enviado a quem conecta.</summary>
        public object GetState() => new { profileId = _currentProfileId, app = _lastProcess };

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            var ownPid = (uint)Environment.ProcessId;
            // Fora do Windows cada leitura e um processo (osascript, xdotool): le menos vezes e
            // so quando algum perfil usa a troca automatica.
            var windows = OperatingSystem.IsWindows();
            var interval = windows ? 500 : 1000;
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    if (DeckHub.ConnectedCount > 0 &&
                        (windows || _config.GetProfiles().Any(p => p.AutoSwitchApps?.Count > 0)))
                    {
                        var fg = _foreground.Foreground();
                        var pid = (uint)(fg?.Pid ?? 0);
                        // A propria janela do DeckOS (QR, avisos) nao conta como troca.
                        if (pid != 0 && pid != _lastPid && pid != ownPid)
                        {
                            _lastPid = pid;
                            _lastProcess = fg?.Process;
                            var profileId = Match(_config.GetProfiles(), _lastProcess);
                            if (profileId != _currentProfileId)
                            {
                                _currentProfileId = profileId;
                                _logger.LogInformation("Perfil automatico: {App} -> {Profile}", _lastProcess, profileId ?? "(nenhum)");
                                await _hub.Clients.All.SendAsync(Event, GetState(), stoppingToken);
                            }
                        }
                    }
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    _logger.LogDebug(ex, "ForegroundWatcher");
                }

                try { await Task.Delay(interval, stoppingToken); } catch (OperationCanceledException) { }
            }
        }

        /// <summary>Primeiro perfil cuja lista contem o processo (sem diferenciar maiusculas, com ou sem .exe).</summary>
        public static string? Match(IEnumerable<Models.DeckProfile> profiles, string? process)
        {
            if (string.IsNullOrEmpty(process)) return null;
            var name = Normalize(process);
            return profiles.FirstOrDefault(p => p.AutoSwitchApps?.Any(a => Normalize(a) == name) == true)?.Id;
        }

        private static string Normalize(string app)
        {
            var s = app.Trim();
            if (s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) s = s[..^4];
            return s.ToLowerInvariant();
        }

        /// <summary>Processo (sem .exe) da janela em foco agora, ou null.</summary>
        public static string? ForegroundProcess()
        {
            try { return PlatformServices.Foreground.Foreground()?.Process; }
            catch { return null; }
        }

        /// <summary>Apps com janela visivel agora, para o editor sugerir.</summary>
        public static List<Actions.FieldOption> RunningApps()
        {
            IReadOnlyList<(string Process, string Title)> apps;
            try { apps = PlatformServices.Foreground.VisibleApps(); }
            catch { return new List<Actions.FieldOption>(); }
            return apps
                .GroupBy(t => t.Process, StringComparer.OrdinalIgnoreCase)
                .Select(g => new Actions.FieldOption(g.Key, $"{g.Key} — {g.First().Title}"))
                .OrderBy(o => o.Value, StringComparer.OrdinalIgnoreCase)
                .ToList();
        }
    }
}
