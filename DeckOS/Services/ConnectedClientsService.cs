using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Net;

namespace DeckOS.Services
{
    /// <summary>
    /// Identidade declarada por um cliente ao se conectar no SignalR (DeckHub.RegisterClient).
    /// Somente metadados grosseiros (papel, nome amigável, modelo, plataforma e transporte);
    /// nunca números de série, IMEI, chaves de pareamento ou IPs.
    /// </summary>
    public sealed class ClientRegistration
    {
        public string? Role { get; set; }
        public string? Name { get; set; }
        public string? Model { get; set; }
        public string? Platform { get; set; }
        public string? Transport { get; set; }
    }

    public sealed record ConnectedClientInfo(
        string Id,
        string Role,
        string? Name,
        string? Model,
        string Platform,
        string Transport,
        bool Connected,
        DateTimeOffset ConnectedAt);

    public sealed record ConnectedClientsSnapshot(IReadOnlyList<ConnectedClientInfo> Clients);

    /// <summary>
    /// Mantém a lista de clientes ativos autenticados no DeckHub para que o configurador web
    /// mostre o celular (ou deck no navegador) realmente conectado, sem confundir o PC com o celular.
    /// </summary>
    public class ConnectedClientsService
    {
        private const int MaxLabelLength = 64;

        private sealed class Entry
        {
            public required string PublicId { get; init; }
            public required string Role { get; set; }
            public string? Name { get; set; }
            public string? Model { get; set; }
            public required string Platform { get; set; }
            public required string Transport { get; set; }
            public required DateTimeOffset ConnectedAt { get; init; }
            public long Sequence { get; set; }
        }

        private readonly ConcurrentDictionary<string, Entry> _entries = new(StringComparer.Ordinal);
        private long _seq;

        public ConnectedClientsSnapshot Register(
            string connectionId,
            ClientRegistration? registration,
            bool isLoopback,
            bool isUsbForwarded)
        {
            if (string.IsNullOrWhiteSpace(connectionId)) return Snapshot();

            var platform = NormalizePlatform(registration?.Platform);
            var role = NormalizeRole(registration?.Role, platform);
            var model = SanitizeLabel(registration?.Model);
            var name = SanitizeLabel(registration?.Name) ?? model;
            var transport = NormalizeTransport(registration?.Transport, role, isLoopback, isUsbForwarded);
            var seq = System.Threading.Interlocked.Increment(ref _seq);

            _entries.AddOrUpdate(
                connectionId,
                _ => new Entry
                {
                    PublicId = Guid.NewGuid().ToString("N")[..8],
                    Role = role,
                    Name = name,
                    Model = model,
                    Platform = platform,
                    Transport = transport,
                    ConnectedAt = DateTimeOffset.UtcNow,
                    Sequence = seq,
                },
                (_, existing) =>
                {
                    existing.Role = role;
                    existing.Name = name;
                    existing.Model = model;
                    existing.Platform = platform;
                    existing.Transport = transport;
                    existing.Sequence = seq;
                    return existing;
                });

            return Snapshot();
        }

        public bool Unregister(string connectionId, out ConnectedClientsSnapshot snapshot)
        {
            var removed = !string.IsNullOrWhiteSpace(connectionId) && _entries.TryRemove(connectionId, out _);
            snapshot = Snapshot();
            return removed;
        }

        public ConnectedClientsSnapshot Snapshot()
        {
            var list = _entries.Values
                .OrderBy(e => RolePriority(e.Role))
                .ThenByDescending(e => e.Sequence)
                .Select(e => new ConnectedClientInfo(
                    e.PublicId,
                    e.Role,
                    e.Name,
                    e.Model,
                    e.Platform,
                    e.Transport,
                    Connected: true,
                    e.ConnectedAt))
                .ToList();
            return new ConnectedClientsSnapshot(list);
        }

        private static int RolePriority(string role) => role switch
        {
            "mobile" => 0,
            "web_deck" => 1,
            _ => 2,
        };

        public static string NormalizePlatform(string? raw) => (raw ?? "").Trim().ToLowerInvariant() switch
        {
            "android" => "android",
            "ios" or "iphone" or "ipad" => "ios",
            "web" or "browser" => "web",
            "windows" or "win" => "windows",
            "macos" or "darwin" or "osx" => "macos",
            "linux" => "linux",
            _ => "unknown",
        };

        public static string NormalizeRole(string? raw, string platform) => (raw ?? "").Trim().ToLowerInvariant() switch
        {
            "mobile" => "mobile",
            "web_deck" or "webdeck" => "web_deck",
            "configurator" or "editor" => "configurator",
            "deck" => platform is "android" or "ios" ? "mobile" : "web_deck",
            _ => platform is "android" or "ios" ? "mobile" : "web_deck",
        };

        public static string NormalizeTransport(string? raw, string role, bool isLoopback, bool isUsbForwarded)
        {
            var hinted = (raw ?? "").Trim().ToLowerInvariant();
            if (hinted is "usb" or "wifi" or "local") return hinted;

            if (isUsbForwarded) return "usb";
            if (isLoopback) return role == "mobile" ? "usb" : "local";
            return "wifi";
        }

        public static string? SanitizeLabel(string? raw)
        {
            if (string.IsNullOrWhiteSpace(raw)) return null;
            var cleaned = new char[Math.Min(raw.Length, MaxLabelLength * 2)];
            var len = 0;
            var prevSpace = false;
            foreach (var ch in raw.Trim())
            {
                if (char.IsControl(ch)) continue;
                if (char.IsWhiteSpace(ch))
                {
                    if (prevSpace || len == 0) continue;
                    cleaned[len++] = ' ';
                    prevSpace = true;
                }
                else
                {
                    cleaned[len++] = ch;
                    prevSpace = false;
                }
                if (len >= MaxLabelLength) break;
            }
            var text = new string(cleaned, 0, len).Trim();
            return text.Length > 0 ? text : null;
        }
    }
}
