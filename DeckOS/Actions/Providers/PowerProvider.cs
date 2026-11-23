using System.Threading.Tasks;
using DeckOS.Platform;
using Microsoft.Extensions.Logging;

namespace DeckOS.Actions.Providers
{
    /// <summary>
    /// Travar, suspender e desligar a tela no macOS e no Linux. Usa o mesmo tipo do
    /// <c>WindowsProvider</c> ("windows"), entao um perfil feito no Windows continua valendo;
    /// so a troca do dispositivo de audio padrao fica de fora (capacidade audio.defaultDevice).
    /// </summary>
    public sealed class PowerProvider : IActionProvider
    {
        private readonly IPowerActions _power;
        private readonly ILogger<PowerProvider> _logger;

        public PowerProvider(IPowerActions power, ILogger<PowerProvider> logger)
        {
            _power = power;
            _logger = logger;
        }

        public string Type => "windows";

        public ActionSchema Describe() => new()
        {
            Type = Type,
            Title = "Este computador",
            Icon = "computer",
            Category = "Sistema",
            Fields =
            {
                ActionField.Select("operation", "Ação",
                    ("lock", "Travar o computador"),
                    ("sleep", "Suspender"),
                    ("displayOff", "Desligar a tela")),
            },
        };

        public Task ExecuteAsync(ActionContext c)
        {
            switch (c.Operation("lock"))
            {
                case "lock":
                    _power.Lock();
                    break;
                case "sleep":
                    _power.Sleep();
                    break;
                case "displayoff":
                    _power.DisplayOff();
                    break;
                default:
                    // Trocar o audio padrao: so o Windows tem (a interface esconde a opcao).
                    throw new PlatformFeatureException("Trocar o dispositivo de áudio padrão só funciona no Windows.");
            }
            _logger.LogInformation("Computador: {Operation}", c.Operation("lock"));
            return Task.CompletedTask;
        }
    }
}
