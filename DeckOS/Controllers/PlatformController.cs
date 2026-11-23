using System.Linq;
using System.Text.Json.Serialization;
using System.Threading.Tasks;
using DeckOS.Platform;
using Microsoft.AspNetCore.Mvc;

namespace DeckOS.Controllers
{
    /// <summary>
    /// O que este PC sabe fazer (GET /api/platform) e os apps instalados (GET /api/apps), para
    /// a biblioteca "Apps deste computador" do configurador.
    /// </summary>
    [ApiController]
    public class PlatformController : ControllerBase
    {
        private readonly IInstalledApps _apps;
        private readonly DiscoveryAvailability _discovery;

        public PlatformController(IInstalledApps apps, DiscoveryAvailability discovery)
        {
            _apps = apps;
            _discovery = discovery;
        }

        /// <summary>
        /// Um app na resposta do /api/apps. Arguments so vem quando existe: app da Store do
        /// Windows e explorer.exe + "shell:AppsFolder\...", e sem ele o botao abria o Explorer.
        /// </summary>
        public sealed record AppDto(string Id, string Name, string Path, string IconUrl,
            [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Arguments = null);

        public static AppDto ToDto(InstalledApp app) =>
            new(app.Id, app.Name, app.Path, $"/api/apps/{app.Id}/icon",
                string.IsNullOrWhiteSpace(app.Arguments) ? null : app.Arguments);

        /// <summary>{ os, osVersion, arch, version, machineName, session, capabilities: [...], missing: [...] }</summary>
        [HttpGet("api/platform")]
        public IActionResult Platform() => Ok(Capabilities.Current(_discovery));

        /// <summary>[{ id, name, path, iconUrl, arguments? }], em ordem de nome.</summary>
        [HttpGet("api/apps")]
        public IActionResult Apps() => Ok(_apps.List().Select(ToDto));

        /// <summary>
        /// Icone do app: PNG (SVG em alguns apps do Linux), com cache no disco. O img do
        /// navegador nao manda o header da chave: use ?access_token=CHAVE, como o SignalR
        /// (ver ApiKeyAuthenticationHandler), ou busque com fetch e o header X-API-KEY.
        /// </summary>
        [HttpGet("api/apps/{id}/icon")]
        public async Task<IActionResult> Icon(string id)
        {
            var icon = await _apps.GetIconAsync(id);
            if (icon == null) return NotFound();
            Response.Headers.CacheControl = "private, max-age=86400";
            return File(icon.Value.Data, icon.Value.ContentType);
        }
    }
}
