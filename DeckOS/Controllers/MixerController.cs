#if WINDOWS
using DeckOS.Services;
using DeckOS.Hubs;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.SignalR;
using NAudio.CoreAudioApi;
using Microsoft.Extensions.Logging;

namespace DeckOS.Controllers
{
    [Route("api/v1/[controller]")]
    [ApiController]
    public class MixerController : ControllerBase
    {
        private readonly MixerService _mixerService;
        private readonly Microsoft.Extensions.Logging.ILogger<MixerController> _logger;
        private readonly IHubContext<DeckHub> _hubContext;

        public MixerController(
            MixerService mixerService,
            Microsoft.Extensions.Logging.ILogger<MixerController> logger,
            IHubContext<DeckHub> hubContext)
        {
            _mixerService = mixerService;
            _logger = logger;
            _hubContext = hubContext;
        }

        [HttpGet("out")]
        public IActionResult GetAllOutputs()
        {
            _logger.LogDebug("GetAllOutputs called");
            return Ok(_mixerService.FindAllOutputs());
        }

        [HttpGet("out/{id}")]
        public IActionResult GetOutput(string id)
        {
            var mixer = _mixerService.FindOne(id);
            if (mixer != null)
                return Ok(mixer);
            return BadRequest();
        }

        [HttpPut("out/{id}")]
        public async Task<IActionResult> SetOutput(string id, [FromBody] MixerData data)
        {
            _logger.LogDebug("SetOutput called for {id}", id);
            var device = new MixerMaster(id);
            if (device.Id == null) return NotFound(); // id inexistente/desconectado

            MixerMaster? result;
            try { result = device.SetOptions(id, data); }
            catch (Exception ex)
            {
                // Ex.: COMException se o device sumiu entre a checagem e o SetOptions.
                _logger.LogWarning(ex, "SetOutput falhou para {id}", id);
                return BadRequest();
            }
            if (result == null) return NotFound();

            // Broadcast volume change to all connected clients
            await _hubContext.Clients.All.SendAsync("ReceiveVolumeChange", new
            {
                deviceId = id,
                type = "output",
                data = result
            });

            return Ok(result);
        }

        [HttpGet("in")]
        public IActionResult GetAllInputs()
        {
            _logger.LogDebug("GetAllInputs called");
            return Ok(_mixerService.FindAllInputs());
        }

        [HttpGet("in/{id}")]
        public IActionResult GetInput(string id)
        {
            var device = _mixerService.FindOne(id);
            if (device == null)
                return BadRequest();
            return Ok(device);
        }

        [HttpPut("in/{id}")]
        public async Task<IActionResult> SetInput(string id, [FromBody] MixerData data)
        {
            _logger.LogDebug("SetInput called for {id}", id);
            var device = new MixerMaster(id);
            if (device.Id == null) return NotFound(); // id inexistente/desconectado

            MixerMaster? result;
            try { result = device.SetOptions(id, data); }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "SetInput falhou para {id}", id);
                return BadRequest();
            }
            if (result == null) return NotFound();

            // Broadcast volume change to all connected clients
            await _hubContext.Clients.All.SendAsync("ReceiveVolumeChange", new
            {
                deviceId = id,
                type = "input",
                data = result
            });

            return Ok(result);
        }
    }
}
#else
using DeckOS.Platform;
using Microsoft.AspNetCore.Mvc;

namespace DeckOS.Controllers
{
    /// <summary>
    /// macOS/Linux: o mixer por dispositivo e por app e do Core Audio do Windows (capacidade
    /// audio.mixer). As listas vem vazias, para o app que consulta de tempo em tempo nao ver
    /// erro; mudar um dispositivo responde 501. O volume do padrao segue pelo controle
    /// deslizante e pela acao "mixer" (ISystemVolume).
    /// </summary>
    [Route("api/v1/[controller]")]
    [ApiController]
    public class MixerController : ControllerBase
    {
        [HttpGet("out")]
        public IActionResult GetAllOutputs() => Ok(System.Array.Empty<object>());

        [HttpGet("in")]
        public IActionResult GetAllInputs() => Ok(System.Array.Empty<object>());

        [HttpGet("out/{id}")]
        [HttpGet("in/{id}")]
        public IActionResult GetOne(string id) => NotFound();

        [HttpPut("out/{id}")]
        [HttpPut("in/{id}")]
        public IActionResult Set(string id) =>
            StatusCode(501, new { error = "Mixer por dispositivo só existe no Windows.", capability = Capabilities.AudioMixer });
    }
}
#endif
