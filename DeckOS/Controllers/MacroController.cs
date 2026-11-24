using System;
using System.Text.Json;
using DeckOS.Lib;
using DeckOS.Lib.Input;
using DeckOS.Services;
using Microsoft.AspNetCore.Mvc;

namespace DeckOS.Controllers
{
    /// <summary>
    /// Gravacao de macro pelo teclado do PC. Le tudo o que se digita, entao so responde a
    /// pedidos do proprio PC (o configurador em localhost), nunca do celular.
    /// </summary>
    [Route("api/macro")]
    [ApiController]
    public class MacroController : ControllerBase
    {
        private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

        private readonly MacroRecorder _recorder;

        public MacroController(MacroRecorder recorder) => _recorder = recorder;

        private bool Local => DeckOS.Auth.TransportBoundary.IsLocalAdmin(HttpContext);

        private ObjectResult OnlyOnPc() =>
            StatusCode(403, new { error = L.T("Gravar macro só funciona no configurador do PC (http://localhost:4787).") });

        [HttpGet]
        public ActionResult Status()
        {
            if (!Local) return OnlyOnPc();
            return Ok(new
            {
                recording = _recorder.Recording,
                keys = _recorder.Count,
                seconds = _recorder.StartedAt is { } at ? (int)(DateTime.UtcNow - at).TotalSeconds : 0,
                maxSeconds = (int)MacroRecorder.MaxDuration.TotalSeconds,
            });
        }

        [HttpPost("start")]
        public ActionResult Start()
        {
            if (!Local) return OnlyOnPc();
            if (!OperatingSystem.IsWindows())
                return StatusCode(501, new { error = "Gravar macro do teclado só funciona no Windows.", capability = Platform.Capabilities.MacroRecord });
            _recorder.Start();
            return Ok(new { recording = _recorder.Recording });
        }

        /// <summary>Para e devolve os passos no formato da multi-acao (parameters["steps"]).</summary>
        [HttpPost("stop")]
        public ActionResult Stop()
        {
            if (!Local) return OnlyOnPc();
            var steps = MacroRecorder.ToSteps(_recorder.Stop());
            return Ok(new { steps = JsonSerializer.Serialize(steps, Json), count = steps.Count });
        }
    }
}
