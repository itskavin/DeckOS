using DeckOS.Services;
using Microsoft.AspNetCore.Http;

namespace DeckOS.Auth;

/// <summary>Runs before static files and auth. Never trust proxy headers for local administration.</summary>
public static class TransportBoundary
{
    public static bool IsLocalAdmin(HttpContext ctx) => !ctx.Request.IsHttps &&
        ActionPolicy.IsLocal(ctx.Connection) && Uri.TryCreate("http://" + ctx.Request.Host, UriKind.Absolute, out var host) && host.IsLoopback;

    public static bool Allowed(HttpContext ctx)
    {
        if (ctx.Request.Headers.Keys.Any(k => k.Equals("Forwarded", StringComparison.OrdinalIgnoreCase) || k.StartsWith("X-Forwarded-", StringComparison.OrdinalIgnoreCase))) return false;
        if (!ctx.Request.IsHttps && !IsLocalAdmin(ctx)) return false;
        var origin = ctx.Request.Headers.Origin.ToString();
        if (origin.Length > 0 && !string.Equals(origin, $"{ctx.Request.Scheme}://{ctx.Request.Host}", StringComparison.OrdinalIgnoreCase)) return false;
        var fetch = ctx.Request.Headers["Sec-Fetch-Site"].ToString();
        return fetch.Length == 0 || fetch == "same-origin" || fetch == "none";
    }
}
