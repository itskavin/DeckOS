using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Models;

namespace DeckOS.Services.AiLimits
{
    /// <summary>
    /// Security validator and bounded HTTP reader for local/LAN AI Limits sources.
    /// Enforces loopback-by-default, blocks redirects (preventing credential forwarding),
    /// strips embedded userinfo/query from stored URLs, and bounds response sizes.
    /// </summary>
    public static class AiLimitsUrlValidator
    {
        public const int DefaultMaxResponseBytes = 2 * 1024 * 1024; // 2 MiB
        public static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(8);

        public readonly record struct ValidationResult(
            bool Ok,
            Uri? NormalizedUri,
            string? ErrorCode,
            string? ErrorMessage,
            bool IsLoopback,
            bool IsNonLoopbackHttp);

        public static ValidationResult ValidateSourceUrl(string? rawUrl, bool allowNonLoopback)
        {
            if (string.IsNullOrWhiteSpace(rawUrl))
                return new(false, null, AiLimitsErrorCodes.InvalidUrl, "Management URL is required.", false, false);

            var trimmed = rawUrl.Trim();
            if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var uri))
                return new(false, null, AiLimitsErrorCodes.InvalidUrl, "Enter a valid http:// or https:// URL.", false, false);

            if (!string.Equals(uri.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase) &&
                !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            {
                return new(false, null, AiLimitsErrorCodes.InvalidUrl, "Only http:// and https:// URLs are allowed.", false, false);
            }

            if (!string.IsNullOrEmpty(uri.UserInfo))
                return new(false, null, AiLimitsErrorCodes.InvalidUrl, "Do not embed credentials in the URL; use the dedicated credential field.", false, false);

            if (string.IsNullOrWhiteSpace(uri.Host))
                return new(false, null, AiLimitsErrorCodes.InvalidUrl, "URL must include a valid host.", false, false);

            var loopback = IsLoopbackHost(uri.Host);
            if (!loopback && !allowNonLoopback)
            {
                return new(
                    false,
                    null,
                    AiLimitsErrorCodes.NonLoopbackBlocked,
                    "Only localhost/loopback URLs are enabled by default. Enable explicit non-loopback opt-in for LAN hosts.",
                    false,
                    false);
            }

            // Users often paste a full management URL; keep only the proxy base path.
            var path = uri.AbsolutePath;
            foreach (var marker in new[] { "/v0/management", "/v8/management" })
            {
                var idx = path.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
                if (idx >= 0) path = path[..idx];
            }

            var builder = new UriBuilder(uri.Scheme.ToLowerInvariant(), uri.Host, uri.IsDefaultPort ? -1 : uri.Port, path.TrimEnd('/'))
            {
                Query = string.Empty,
                Fragment = string.Empty,
                UserName = string.Empty,
                Password = string.Empty,
            };
            var normalized = builder.Uri;
            var isNonLoopbackHttp = !loopback && string.Equals(normalized.Scheme, Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase);

            return new(true, normalized, null, null, loopback, isNonLoopbackHttp);
        }

        public static string? ValidateDashboardUrl(string? rawUrl)
        {
            if (string.IsNullOrWhiteSpace(rawUrl)) return null;
            if (!Uri.TryCreate(rawUrl.Trim(), UriKind.Absolute, out var uri)) return null;
            if (!string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)) return null;
            if (!string.IsNullOrEmpty(uri.UserInfo)) return null;
            return uri.ToString();
        }

        public static bool IsLoopbackHost(string host)
        {
            if (string.IsNullOrWhiteSpace(host)) return false;
            var clean = host.Trim().Trim('[', ']');
            if (clean.Equals("localhost", StringComparison.OrdinalIgnoreCase)) return true;
            if (IPAddress.TryParse(clean, out var ip))
            {
                if (ip.IsIPv4MappedToIPv6) ip = ip.MapToIPv4();
                return IPAddress.IsLoopback(ip);
            }
            return false;
        }

        public static bool IsRedirectStatus(HttpStatusCode statusCode)
        {
            var code = (int)statusCode;
            return code is >= 300 and <= 399;
        }

        public static TimeSpan? ParseRetryAfter(HttpResponseMessage response, DateTimeOffset now, TimeSpan maxBackoff)
        {
            var header = response.Headers.RetryAfter;
            if (header == null) return null;

            TimeSpan? delay = null;
            if (header.Delta is { } delta)
                delay = delta;
            else if (header.Date is { } date)
                delay = date - now;

            if (delay is not { } value || value <= TimeSpan.Zero) return null;
            return value > maxBackoff ? maxBackoff : value;
        }

        public static async Task<(bool TooLarge, string Body)> ReadBoundedStringAsync(
            HttpContent content,
            int maxBytes = DefaultMaxResponseBytes,
            CancellationToken ct = default)
        {
            if (content.Headers.ContentLength is { } cl && cl > maxBytes)
                return (true, string.Empty);

            await using var stream = await content.ReadAsStreamAsync(ct);
            using var ms = new MemoryStream();
            var buffer = new byte[8192];
            long total = 0;
            int read;
            while ((read = await stream.ReadAsync(buffer.AsMemory(0, buffer.Length), ct)) > 0)
            {
                total += read;
                if (total > maxBytes)
                    return (true, string.Empty);
                ms.Write(buffer, 0, read);
            }
            return (false, Encoding.UTF8.GetString(ms.GetBuffer(), 0, (int)ms.Length));
        }
    }
}
