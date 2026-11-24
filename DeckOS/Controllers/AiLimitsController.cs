using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Models;
using DeckOS.Services;
using DeckOS.Services.AiLimits;
using Microsoft.AspNetCore.Mvc;

namespace DeckOS.Controllers
{
    /// <summary>
    /// Normalized AI subscription limits API (/api/ai-limits).
    /// Protected by DeckOS's fallback ApiKey authentication policy; never echoes secrets,
    /// auth filenames or upstream tokens. Display names respect the shared privacy setting.
    /// </summary>
    [Route("api/ai-limits")]
    [ApiController]
    public sealed class AiLimitsController : ControllerBase
    {
        private readonly AiLimitsService _service;

        public AiLimitsController(AiLimitsService service)
        {
            _service = service;
        }

        [HttpGet]
        public async Task<ActionResult<AiLimitsSnapshotResponse>> GetSnapshot(CancellationToken ct)
        {
            return Ok(await _service.GetSnapshotAsync(refreshEnv: false, ct));
        }

        [HttpGet("sources")]
        public async Task<ActionResult> ListSources(CancellationToken ct)
        {
            var snap = await _service.GetSnapshotAsync(refreshEnv: false, ct);
            return Ok(snap.Sources);
        }

        [HttpPost("sources/test")]
        public async Task<ActionResult<AiLimitsSourceTestResponse>> TestSource([FromBody] AiLimitsSourceTestRequest? req, CancellationToken ct)
        {
            if (req == null)
                return BadRequest(new { errorCode = AiLimitsErrorCodes.InvalidUrl, message = "Request body is required." });

            if (!IsLocalRequest() && (!string.IsNullOrWhiteSpace(req.ConfigDir) || !string.IsNullOrWhiteSpace(req.SnapshotFile)))
            {
                return StatusCode(403, new
                {
                    errorCode = AiLimitsErrorCodes.LocalOnlyAction,
                    message = "Custom PC directory or file paths can only be configured from the host PC.",
                });
            }

            return Ok(await _service.TestSourceAsync(req, ct));
        }

        [HttpPost("sources")]
        public async Task<ActionResult> CreateSource([FromBody] AiLimitsSourceUpsertRequest? req, CancellationToken ct)
        {
            if (req == null)
                return BadRequest(new { errorCode = AiLimitsErrorCodes.InvalidUrl, message = "Request body is required." });

            if (!IsLocalRequest() && (!string.IsNullOrWhiteSpace(req.ConfigDir) || !string.IsNullOrWhiteSpace(req.SnapshotFile)))
            {
                return StatusCode(403, new
                {
                    errorCode = AiLimitsErrorCodes.LocalOnlyAction,
                    message = "Custom PC directory or file paths can only be configured from the host PC.",
                });
            }

            var (source, accounts, snapshot, errCode, errMsg) = await _service.CreateSourceAsync(req, ct);
            if (errCode != null || source == null)
                return BadRequest(new { errorCode = errCode, message = errMsg });

            return Created($"/api/ai-limits/sources/{source.Id}", new { source, accounts, snapshot });
        }

        [HttpPut("sources/{sourceId}")]
        public async Task<ActionResult> UpdateSource(string sourceId, [FromBody] AiLimitsSourceUpsertRequest? req, CancellationToken ct)
        {
            if (req == null)
                return BadRequest(new { errorCode = AiLimitsErrorCodes.InvalidUrl, message = "Request body is required." });

            var existing = _service.FindSourceConfig(sourceId);
            if (existing == null) return NotFound();

            if (!IsLocalRequest() &&
                (!string.Equals(req.ConfigDir?.Trim(), existing.ConfigDir, StringComparison.Ordinal) && !string.IsNullOrWhiteSpace(req.ConfigDir) ||
                 !string.Equals(req.SnapshotFile?.Trim(), existing.SnapshotFile, StringComparison.Ordinal) && !string.IsNullOrWhiteSpace(req.SnapshotFile)))
            {
                return StatusCode(403, new
                {
                    errorCode = AiLimitsErrorCodes.LocalOnlyAction,
                    message = "Custom PC directory or file paths can only be configured from the host PC.",
                });
            }

            var (source, accounts, snapshot, errCode, errMsg, notFound) = await _service.UpdateSourceAsync(sourceId, req, ct);
            if (notFound) return NotFound();
            if (errCode != null || source == null)
                return BadRequest(new { errorCode = errCode, message = errMsg });

            return Ok(new { source, accounts, snapshot });
        }

        [HttpDelete("sources/{sourceId}")]
        public async Task<ActionResult> DeleteSource(string sourceId, CancellationToken ct)
        {
            var (deleted, snapshot) = await _service.DeleteSourceAsync(sourceId, ct);
            if (!deleted) return NotFound();
            return Ok(new { deleted = true, snapshot });
        }

        [HttpPost("refresh")]
        public async Task<ActionResult> Refresh([FromBody] AiLimitsRefreshRequest? req, CancellationToken ct)
        {
            return await ExecuteRefreshAsync(req?.SourceId, ct);
        }

        [HttpPost("sources/{sourceId}/refresh")]
        public async Task<ActionResult> RefreshSource(string sourceId, CancellationToken ct)
        {
            if (_service.FindSourceConfig(sourceId) == null) return NotFound();
            return await ExecuteRefreshAsync(sourceId, ct);
        }

        private async Task<ActionResult> ExecuteRefreshAsync(string? sourceId, CancellationToken ct)
        {
            var outcome = await _service.ManualRefreshAsync(sourceId, ct);
            if (outcome.CooldownBlocked)
            {
                var secs = outcome.RetryAfterSeconds ?? 1;
                Response.Headers["Retry-After"] = secs.ToString(System.Globalization.CultureInfo.InvariantCulture);
                return StatusCode(429, new
                {
                    errorCode = AiLimitsErrorCodes.CooldownActive,
                    message = $"Please wait {secs}s before refreshing again.",
                    retryAfterSeconds = secs,
                    nextRefreshAllowedAt = outcome.NextRefreshAllowedAt,
                    snapshot = outcome.Snapshot,
                });
            }
            return Ok(outcome.Snapshot);
        }

        [HttpPut("privacy")]
        public async Task<ActionResult> UpdatePrivacy([FromBody] AiLimitsPrivacyUpdateRequest? req, CancellationToken ct)
        {
            if (req == null) return BadRequest(new { message = "Request body is required." });
            return Ok(await _service.UpdatePrivacyAsync(req.HideAccountNames, ct));
        }

        [HttpGet("accounts")]
        public async Task<ActionResult> ListAccounts(CancellationToken ct)
        {
            var snap = await _service.GetSnapshotAsync(refreshEnv: false, ct);
            return Ok(snap.Accounts);
        }

        [HttpPatch("accounts/{accountId}")]
        [HttpPut("accounts/{accountId}")]
        public async Task<ActionResult> UpdateAccount(string accountId, [FromBody] AiLimitsAccountUpdateRequest? req, CancellationToken ct)
        {
            if (req == null)
                return BadRequest(new { errorCode = AiLimitsErrorCodes.InvalidUrl, message = "Request body is required." });

            if (!string.IsNullOrWhiteSpace(req.DashboardUrl) && AiLimitsUrlValidator.ValidateDashboardUrl(req.DashboardUrl) == null)
                return BadRequest(new { errorCode = AiLimitsErrorCodes.InvalidUrl, message = "Dashboard URL must be a valid https:// URL." });

            try { AiAccountDisplay.ValidateAlias(req.Alias); }
            catch (ArgumentException) { return BadRequest(new { message = "Alias must be at most 60 characters and contain no control or direction characters." }); }
            var (account, snapshot) = await _service.UpdateAccountAsync(accountId, req, ct);
            if (account == null) return NotFound();
            return Ok(new { account, snapshot });
        }

        [HttpDelete("accounts/{accountId}")]
        public async Task<ActionResult> RemoveAccount(string accountId, CancellationToken ct)
        {
            var (removed, snapshot) = await _service.RemoveAccountLocalAsync(accountId, ct);
            if (!removed) return NotFound();
            return Ok(new { removed = true, snapshot });
        }

        [HttpGet("sources/{sourceId}/setup")]
        public ActionResult<AiLimitsSetupGuideResponse> GetSetupGuide(string sourceId)
        {
            var guide = _service.GetSetupGuide(sourceId, IsLocalRequest());
            return guide != null ? Ok(guide) : NotFound();
        }

        [HttpPost("sources/{sourceId}/install-hook")]
        public async Task<ActionResult> InstallHook(string sourceId, CancellationToken ct)
        {
            if (!IsLocalRequest())
            {
                return StatusCode(403, new
                {
                    errorCode = AiLimitsErrorCodes.LocalOnlyAction,
                    message = "Claude statusLine hook installation must be triggered from the host PC.",
                });
            }

            var (guide, snapshot) = await _service.InstallClaudeHookAsync(sourceId, ct);
            if (guide == null) return NotFound();
            return Ok(new { setup = guide, snapshot });
        }

        [HttpPost("sources/{sourceId}/uninstall-hook")]
        public async Task<ActionResult> UninstallHook(string sourceId, CancellationToken ct)
        {
            if (!IsLocalRequest())
            {
                return StatusCode(403, new
                {
                    errorCode = AiLimitsErrorCodes.LocalOnlyAction,
                    message = "Claude statusLine hook removal must be triggered from the host PC.",
                });
            }

            var (guide, snapshot) = await _service.UninstallClaudeHookAsync(sourceId, ct);
            if (guide == null) return NotFound();
            return Ok(new { setup = guide, snapshot });
        }

        [HttpPost("sources/{sourceId}/ingest")]
        public async Task<ActionResult> IngestClaudeStatusLine(string sourceId, CancellationToken ct)
        {
            if (!IsLocalRequest())
            {
                return StatusCode(403, new
                {
                    errorCode = AiLimitsErrorCodes.LocalOnlyAction,
                    message = "Local statusLine ingest is only accepted from the host PC.",
                });
            }

            string body;
            using (var reader = new StreamReader(Request.Body, Encoding.UTF8, leaveOpen: true))
            {
                var buf = new char[65536];
                var read = await reader.ReadBlockAsync(buf, 0, buf.Length);
                if (read >= buf.Length && reader.Peek() >= 0)
                {
                    return StatusCode(413, new
                    {
                        errorCode = AiLimitsErrorCodes.ResponseTooLarge,
                        message = "Ingest payload exceeds 64 KiB limit.",
                    });
                }
                body = new string(buf, 0, read);
            }

            if (string.IsNullOrWhiteSpace(body))
                return BadRequest(new { errorCode = AiLimitsErrorCodes.InvalidUrl, message = "JSON payload is required." });

            try
            {
                var (ok, snapshot) = await _service.IngestClaudeStatusLineAsync(sourceId, body, ct);
                if (!ok) return NotFound();
                return Ok(snapshot);
            }
            catch (System.Text.Json.JsonException)
            {
                return BadRequest(new { errorCode = AiLimitsErrorCodes.InvalidUrl, message = "Invalid JSON payload." });
            }
        }

        private bool IsLocalRequest()
        {
            // In-memory TestServer leaves RemoteIpAddress null; treat TestServer loopback as local unless explicitly overridden.
            if (HttpContext.Connection.RemoteIpAddress == null) return true;
            return DeckOS.Auth.TransportBoundary.IsLocalAdmin(HttpContext);
        }
    }
}
