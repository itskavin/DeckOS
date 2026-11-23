using System;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DeckOS.Lib;
using DeckOS.Models;

namespace DeckOS.Services.AiLimits
{
    /// <summary>
    /// Atomic versioned persistence for AI Limits configuration and encrypted local secrets.
    /// Stores config and secrets strictly in AppPaths.LocalDir (never inside RoamingDir profiles
    /// or .deckos profile backups).
    /// </summary>
    public sealed class AiLimitsConfigStore
    {
        private static readonly JsonSerializerOptions JsonOpts = new()
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            PropertyNameCaseInsensitive = true,
            WriteIndented = true,
        };

        private readonly object _gate = new();
        private readonly string _baseDir;

        public AiLimitsConfigStore(string? baseDirOverride = null)
        {
            _baseDir = string.IsNullOrWhiteSpace(baseDirOverride) ? AppPaths.LocalDir : baseDirOverride;
        }

        public string BaseDir => _baseDir;
        public string ConfigPath => Path.Combine(_baseDir, "ai-limits.json");
        public string SecretsPath => Path.Combine(_baseDir, "ai-limits-secrets.json");
        public string SnapshotsDir => Path.Combine(_baseDir, "ai-limits", "snapshots");
        public string ScriptsDir => Path.Combine(_baseDir, "ai-limits", "scripts");

        public string DefaultClaudeSnapshotPath(string sourceId) =>
            Path.Combine(SnapshotsDir, $"claude-statusline-{SanitizeFileSegment(sourceId)}.json");

        public AiLimitsConfigDocument LoadConfig()
        {
            lock (_gate)
            {
                if (!File.Exists(ConfigPath))
                    return new AiLimitsConfigDocument();

                try
                {
                    var text = File.ReadAllText(ConfigPath);
                    var doc = JsonSerializer.Deserialize<AiLimitsConfigDocument>(text, JsonOpts)
                        ?? new AiLimitsConfigDocument();
                    doc.Sources ??= new List<AiLimitsSourceConfig>();
                    doc.AccountOverrides ??= new Dictionary<string, AiLimitsAccountOverride>(StringComparer.Ordinal);
                    doc.HiddenAccountIds ??= new HashSet<string>(StringComparer.Ordinal);
                    if (doc.SchemaVersion <= 0) doc.SchemaVersion = 1;
                    doc.AutoRefreshIntervalSeconds = Math.Clamp(doc.AutoRefreshIntervalSeconds <= 0 ? 180 : doc.AutoRefreshIntervalSeconds, 60, 3600);
                    doc.ManualCooldownSeconds = Math.Clamp(doc.ManualCooldownSeconds <= 0 ? 15 : doc.ManualCooldownSeconds, 5, 300);
                    return doc;
                }
                catch
                {
                    // Keep the unreadable file aside so the next save can't silently destroy the user's sources.
                    PreserveCorrupt(ConfigPath);
                    return new AiLimitsConfigDocument();
                }
            }
        }

        private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> PreservedCorrupt = new(StringComparer.OrdinalIgnoreCase);

        private static void PreserveCorrupt(string path)
        {
            // Secrets are read on every snapshot; copy an unreadable file aside only once per process.
            if (!PreservedCorrupt.TryAdd(path, true)) return;
            try
            {
                File.Copy(path, path + ".corrupt-" + DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmss", System.Globalization.CultureInfo.InvariantCulture), overwrite: false);
            }
            catch { }
        }

        public void SaveConfig(AiLimitsConfigDocument doc)
        {
            lock (_gate)
            {
                Directory.CreateDirectory(_baseDir);
                doc.SchemaVersion = 1;
                var json = JsonSerializer.Serialize(doc, JsonOpts);
                WriteAtomic(ConfigPath, json);
            }
        }

        public string? GetSecret(string sourceId)
        {
            if (string.IsNullOrWhiteSpace(sourceId)) return null;
            lock (_gate)
            {
                var map = LoadSecretsUnlocked();
                return map.TryGetValue(sourceId, out var value) && !string.IsNullOrEmpty(value) ? value : null;
            }
        }

        public bool HasSecret(string sourceId) => GetSecret(sourceId) != null;

        public void SetSecret(string sourceId, string? secret)
        {
            if (string.IsNullOrWhiteSpace(sourceId)) return;
            lock (_gate)
            {
                var map = LoadSecretsUnlocked();
                if (string.IsNullOrWhiteSpace(secret))
                    map.Remove(sourceId);
                else
                    map[sourceId] = secret.Trim();
                SaveSecretsUnlocked(map);
            }
        }

        public void DeleteSecret(string sourceId) => SetSecret(sourceId, null);

        public static string NewSourceId()
        {
            var bytes = RandomNumberGenerator.GetBytes(8);
            return "src_" + Convert.ToHexString(bytes).ToLowerInvariant();
        }

        /// <summary>
        /// Derives a stable, opaque, secret-free account ID from sourceId and a raw upstream identity key
        /// (such as auth_index or hashed account slot) without ever exposing raw emails, tokens, or filenames.
        /// </summary>
        public static string DeriveOpaqueAccountId(string sourceId, string stableKey)
        {
            var input = Encoding.UTF8.GetBytes($"deckos.ai_limits.v1|{sourceId}|{stableKey}");
            var hash = SHA256.HashData(input);
            return "acct_" + Convert.ToHexString(hash, 0, 8).ToLowerInvariant();
        }

        public static string SanitizeFileSegment(string value)
        {
            var sb = new StringBuilder(value.Length);
            foreach (var c in value)
            {
                if (char.IsLetterOrDigit(c) || c == '_' || c == '-')
                    sb.Append(c);
            }
            return sb.Length > 0 ? sb.ToString() : "default";
        }

        private Dictionary<string, string> LoadSecretsUnlocked()
        {
            if (!File.Exists(SecretsPath))
                return new Dictionary<string, string>(StringComparer.Ordinal);
            try
            {
                var text = SecretFile.ReadAllText(SecretsPath);
                var map = JsonSerializer.Deserialize<Dictionary<string, string>>(text, JsonOpts);
                return map != null
                    ? new Dictionary<string, string>(map, StringComparer.Ordinal)
                    : new Dictionary<string, string>(StringComparer.Ordinal);
            }
            catch
            {
                // Still encrypted/owner-only; kept aside rather than overwritten by the next write.
                PreserveCorrupt(SecretsPath);
                return new Dictionary<string, string>(StringComparer.Ordinal);
            }
        }

        private void SaveSecretsUnlocked(Dictionary<string, string> map)
        {
            Directory.CreateDirectory(_baseDir);
            if (map.Count == 0)
            {
                try { if (File.Exists(SecretsPath)) File.Delete(SecretsPath); } catch { }
                return;
            }
            var json = JsonSerializer.Serialize(map, JsonOpts);
            SecretFile.WriteAllText(SecretsPath, json);
        }

        private static void WriteAtomic(string path, string contents)
        {
            var dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
            var tmp = path + ".tmp." + Guid.NewGuid().ToString("N")[..8];
            try
            {
                File.WriteAllText(tmp, contents, Encoding.UTF8);
                if (!OperatingSystem.IsWindows())
                {
                    try { File.SetUnixFileMode(tmp, UnixFileMode.UserRead | UnixFileMode.UserWrite); }
                    catch { }
                }
                File.Move(tmp, path, overwrite: true);
            }
            catch
            {
                try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
                throw;
            }
        }
    }
}
