using DeckOS.Auth;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace DeckOS.Controllers;

[ApiController, Route("api/pairing")]
public sealed class SecurePairingController : ControllerBase
{
    public sealed record PairRequest(string Token, string? Name);
    [HttpPost("exchange"), AllowAnonymous]
    public IActionResult Exchange(PairRequest request)
    {
        if (!Request.IsHttps) return StatusCode(403);
        var result = SecurePairing.Shared.Exchange(request.Token ?? "", request.Name ?? "DeckOS device");
        return result is { } pair ? Ok(new { deviceId = pair.Id, credential = pair.Credential }) : StatusCode(410, new { error = "Pairing code expired or already used. Open a new code on your PC." });
    }
    [HttpGet("qr")]
    public IActionResult Qr() => TransportBoundary.IsLocalAdmin(HttpContext) ? Ok(new { code = Lib.PairingInfo.BuildUri() }) : StatusCode(403);
    [HttpGet("devices")]
    public IActionResult Devices() => TransportBoundary.IsLocalAdmin(HttpContext) ? Ok(SecurePairing.Shared.List()) : StatusCode(403);
    [HttpDelete("devices/{id}")]
    public IActionResult Revoke(string id) => TransportBoundary.IsLocalAdmin(HttpContext) ? Ok(new { revoked = SecurePairing.Shared.Revoke(id) }) : StatusCode(403);
}
