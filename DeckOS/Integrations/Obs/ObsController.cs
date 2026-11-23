using System.Threading.Tasks;
using DeckOS.Services;
using DeckOS.Lib;
using Microsoft.AspNetCore.Mvc;

namespace DeckOS.Controllers
{
    [Route("api/[controller]")]
    [ApiController]
    public class ObsController : ControllerBase
    {
        private readonly ObsService _obs;

        public ObsController(ObsService obs)
        {
            _obs = obs;
        }

        public class ObsConfigDto
        {
            public string? Host { get; set; }
            public int? Port { get; set; }
            public string? Password { get; set; }
        }

        [HttpPost("config")]
        public async Task<IActionResult> Config([FromBody] ObsConfigDto? dto)
        {
            var cfg = _obs.LoadConfig();
            if (!string.IsNullOrWhiteSpace(dto?.Host))
            {
                try { cfg.Host = ObsService.NormalizeHost(dto!.Host!); }
                catch (System.InvalidOperationException ex) { return BadRequest(new { error = L.Message(ex) }); }
            }
            if (dto?.Port is int p)
            {
                if (p is < 1 or > 65535)
                    return BadRequest(new { error = L.T("Porta inválida (1 a 65535).") });
                cfg.Port = p;
            }
            cfg.Password = string.IsNullOrEmpty(dto?.Password) ? null : dto!.Password; // pode ser vazio/null (OBS sem senha)
            _obs.SaveConfig(cfg);
            await _obs.BroadcastStateAsync();
            return Ok(_obs.GetStatePayload());
        }

        [HttpPost("disconnect")]
        public async Task<IActionResult> Disconnect()
        {
            _obs.Disconnect();
            await _obs.BroadcastStateAsync();
            return Ok(_obs.GetStatePayload());
        }

        [HttpDelete("config")]
        public async Task<IActionResult> Forget()
        {
            _obs.ClearConfig();
            await _obs.BroadcastStateAsync();
            return Ok(_obs.GetStatePayload());
        }

        [HttpPost("connect")]
        public async Task<IActionResult> Connect()
        {
            try { await _obs.ConnectAsync(); return Ok(_obs.GetStatePayload()); }
            catch (System.Exception ex) { return StatusCode(502, new { error = L.Message(ex) }); }
        }

        [HttpGet("state")]
        public IActionResult State() => Ok(_obs.GetStatePayload());

        [HttpGet("scenes")]
        public async Task<IActionResult> Scenes()
        {
            try { return Ok(await _obs.GetScenesAsync()); }
            catch (System.Exception ex) { return StatusCode(502, new { error = L.Message(ex) }); }
        }

        [HttpGet("sources")]
        public async Task<IActionResult> Sources()
        {
            try { return Ok(await _obs.GetSourcesAsync()); }
            catch (System.Exception ex) { return StatusCode(502, new { error = L.Message(ex) }); }
        }

        [HttpGet("scene-items")]
        public async Task<IActionResult> SceneItems([FromQuery] string scene)
        {
            try { return Ok(await _obs.GetSceneItemsAsync(scene)); }
            catch (System.Exception ex) { return StatusCode(502, new { error = L.Message(ex) }); }
        }

        [HttpGet("filters")]
        public async Task<IActionResult> Filters([FromQuery] string source)
        {
            try { return Ok(await _obs.GetFiltersAsync(source)); }
            catch (System.Exception ex) { return StatusCode(502, new { error = L.Message(ex) }); }
        }

        [HttpGet("audio-inputs")]
        public async Task<IActionResult> AudioInputs()
        {
            try { return Ok(await _obs.GetAudioInputsAsync()); }
            catch (System.Exception ex) { return StatusCode(502, new { error = L.Message(ex) }); }
        }
    }
}
