using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Lib;

namespace DeckOS.Services
{
    /// <summary>
    /// Uso de IA legado para o botão "Uso de IA": mantém a contagem passiva de tokens
    /// (~/.claude/projects e ~/.codex/sessions) e limites passivos locais (snapshot do statusLine
    /// do Claude Code e registros locais do Codex). Não consulta endpoints não documentados da
    /// Anthropic nem lê arquivos de credenciais OAuth.
    /// </summary>
    public class AiUsageService
    {
        public const string Claude = "claude";
        public const string Codex = "codex";

        private static readonly TimeSpan Keep = TimeSpan.FromDays(8);

        private readonly LogScanner _claudeLogs = new(ParseClaudeLine, "\"usage\"");
        private readonly LogScanner _codexLogs = new(ParseCodexLine, "\"token_count\"");

        public AiUsageService(IHttpClientFactory? http = null)
        {
            _ = http;
        }

        /// <summary>Uma janela de limite: quanto já foi usado (0–100) e quando zera.</summary>
        public record Window(double Percent, DateTimeOffset? ResetsAt);

        public record Plan(Window? Session, Window? Week);

        public record Tokens(long Today, long Week);

        /// <summary>Uma linha lida de um registro: quando, quantos tokens e o id (para não contar repetido).</summary>
        public record Entry(DateTimeOffset At, long Tokens, string? Id, Plan? Plan = null);

        public static string ClaudeDir =>
            Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") is { Length: > 0 } d
                ? d
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude");

        public static string CodexDir =>
            Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } d
                ? d
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");

        // ---- Limites do plano (somente fontes oficiais/passivas locais) ----

        public async Task<Plan> PlanAsync(string provider)
        {
            if (provider == Codex)
            {
                var plan = await Task.Run(() => _codexLogs.LatestPlan(Path.Combine(CodexDir, "sessions")));
                return plan ?? throw new LocalizedException("Sem registros do Codex neste PC.");
            }

            var passive = await Task.Run(ReadPassiveClaudeStatusLinePlan);
            if (passive != null) return passive;

            throw new LocalizedException("Configure o statusLine do Claude Code em AI Limits para ver os limites sem consultas não oficiais.");
        }

        private static Plan? ReadPassiveClaudeStatusLinePlan()
        {
            var dir = Path.Combine(AppPaths.LocalDir, "ai-limits", "snapshots");
            if (!Directory.Exists(dir)) return null;

            try
            {
                var latest = Directory.EnumerateFiles(dir, "claude-statusline-*.json")
                    .Select(p => new FileInfo(p))
                    .OrderByDescending(f => f.LastWriteTimeUtc)
                    .FirstOrDefault();
                if (latest == null) return null;

                using var doc = JsonDocument.Parse(File.ReadAllText(latest.FullName));
                var rl = doc.RootElement.TryGetProperty("rate_limits", out var inner) && inner.ValueKind == JsonValueKind.Object
                    ? inner
                    : doc.RootElement;

                Window? Read(string name)
                {
                    if (!rl.TryGetProperty(name, out var w) || w.ValueKind != JsonValueKind.Object) return null;
                    if (!w.TryGetProperty("used_percentage", out var u) || u.ValueKind != JsonValueKind.Number) return null;
                    DateTimeOffset? resets = null;
                    if (w.TryGetProperty("resets_at", out var r))
                    {
                        if (r.ValueKind == JsonValueKind.Number && r.TryGetInt64(out var unix) && unix > 0)
                            resets = DateTimeOffset.FromUnixTimeSeconds(unix);
                        else if (r.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(r.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dt))
                            resets = dt.ToUniversalTime();
                    }
                    return new Window(u.GetDouble(), resets);
                }

                var s = Read("five_hour");
                var wk = Read("seven_day");
                return s != null || wk != null ? new Plan(s, wk) : null;
            }
            catch
            {
                return null;
            }
        }

        /// <summary>Resposta do /api/oauth/usage: five_hour e seven_day com utilization e resets_at.</summary>
        public static Plan ParseClaudePlan(string json)
        {
            using var doc = JsonDocument.Parse(json);
            Window? Read(string name)
            {
                if (!doc.RootElement.TryGetProperty(name, out var w) || w.ValueKind != JsonValueKind.Object) return null;
                if (!w.TryGetProperty("utilization", out var u) || u.ValueKind != JsonValueKind.Number) return null;
                DateTimeOffset? resets = w.TryGetProperty("resets_at", out var r) && r.ValueKind == JsonValueKind.String
                    && DateTimeOffset.TryParse(r.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.None, out var at)
                    ? at : null;
                return new Window(u.GetDouble(), resets);
            }
            return new Plan(Read("five_hour"), Read("seven_day"));
        }

        // ---- Tokens ----

        public Task<Tokens> TokensAsync(string provider) => Task.Run(() =>
        {
            var entries = provider == Codex
                ? _codexLogs.Entries(Path.Combine(CodexDir, "sessions"))
                : _claudeLogs.Entries(Path.Combine(ClaudeDir, "projects"));
            return Sum(entries, DateTimeOffset.Now);
        });

        /// <summary>Hoje (desde a meia-noite local) e os últimos 7 dias, contando hoje.</summary>
        public static Tokens Sum(IEnumerable<Entry> entries, DateTimeOffset now)
        {
            var today = new DateTimeOffset(now.Date, now.Offset);
            var week = today.AddDays(-6);
            long t = 0, w = 0;
            foreach (var e in entries)
            {
                if (e.At >= week && e.At <= now.AddMinutes(5)) w += e.Tokens;
                if (e.At >= today && e.At <= now.AddMinutes(5)) t += e.Tokens;
            }
            return new Tokens(t, w);
        }

        /// <summary>
        /// Uma linha do Claude Code com "usage". A mesma resposta aparece em várias linhas (uma por
        /// bloco), então o id da mensagem evita contar duas vezes. Conta entrada, saída e cache.
        /// </summary>
        public static Entry? ParseClaudeLine(string line)
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            if (!root.TryGetProperty("message", out var msg) || msg.ValueKind != JsonValueKind.Object) return null;
            if (!msg.TryGetProperty("usage", out var u) || u.ValueKind != JsonValueKind.Object) return null;
            if (!root.TryGetProperty("timestamp", out var ts) || !DateTimeOffset.TryParse(ts.GetString(),
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out var at)) return null;
            long Num(string k) => u.TryGetProperty(k, out var v) && v.TryGetInt64(out var n) ? n : 0;
            var tokens = Num("input_tokens") + Num("output_tokens")
                + Num("cache_creation_input_tokens") + Num("cache_read_input_tokens");
            var id = msg.TryGetProperty("id", out var i) ? i.GetString() : null;
            if (root.TryGetProperty("requestId", out var rq)) id += "|" + rq.GetString();
            return new Entry(at, tokens, id);
        }

        /// <summary>
        /// Evento token_count do Codex: last_token_usage é o gasto daquela chamada; rate_limits traz a
        /// janela primária (5 h) e a secundária (semana), com resets_at (segundos Unix) ou
        /// resets_in_seconds nas versões antigas.
        /// </summary>
        public static Entry? ParseCodexLine(string line)
        {
            using var doc = JsonDocument.Parse(line);
            var root = doc.RootElement;
            if (!root.TryGetProperty("payload", out var p) || p.ValueKind != JsonValueKind.Object) return null;
            if (!p.TryGetProperty("type", out var type) || type.GetString() != "token_count") return null;
            if (!root.TryGetProperty("timestamp", out var ts) || !DateTimeOffset.TryParse(ts.GetString(),
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out var at)) return null;

            long tokens = 0;
            if (p.TryGetProperty("info", out var info) && info.ValueKind == JsonValueKind.Object
                && info.TryGetProperty("last_token_usage", out var last) && last.ValueKind == JsonValueKind.Object)
            {
                if (last.TryGetProperty("total_tokens", out var tt) && tt.TryGetInt64(out var n)) tokens = n;
                else
                {
                    long Num(string k) => last.TryGetProperty(k, out var v) && v.TryGetInt64(out var x) ? x : 0;
                    tokens = Num("input_tokens") + Num("output_tokens");
                }
            }

            Plan? plan = null;
            if (p.TryGetProperty("rate_limits", out var rl) && rl.ValueKind == JsonValueKind.Object)
            {
                Window? Read(string name)
                {
                    if (!rl.TryGetProperty(name, out var w) || w.ValueKind != JsonValueKind.Object) return null;
                    if (!w.TryGetProperty("used_percent", out var u) || u.ValueKind != JsonValueKind.Number) return null;
                    DateTimeOffset? resets = null;
                    if (w.TryGetProperty("resets_at", out var r) && r.TryGetInt64(out var unix))
                        resets = DateTimeOffset.FromUnixTimeSeconds(unix);
                    else if (w.TryGetProperty("resets_in_seconds", out var s) && s.TryGetInt64(out var secs))
                        resets = at.AddSeconds(secs);
                    return new Window(u.GetDouble(), resets);
                }
                var primary = Read("primary");
                var secondary = Read("secondary");
                if (primary != null || secondary != null) plan = new Plan(primary, secondary);
            }
            return new Entry(at, tokens, null, plan);
        }

        /// <summary>
        /// Lê os .jsonl recentes de uma pasta aos poucos: guarda até onde leu cada arquivo e só
        /// processa o que foi acrescentado. Linhas sem o marcador nem são interpretadas.
        /// </summary>
        public sealed class LogScanner
        {
            private readonly Func<string, Entry?> _parse;
            private readonly string _marker;
            private readonly object _gate = new();
            private readonly Dictionary<string, FileState> _files = new(StringComparer.OrdinalIgnoreCase);

            private sealed class FileState
            {
                public long Offset;
                public readonly List<Entry> Entries = new();
                public readonly HashSet<string> Ids = new();
            }

            public LogScanner(Func<string, Entry?> parse, string marker)
            {
                _parse = parse;
                _marker = marker;
            }

            public List<Entry> Entries(string dir)
            {
                lock (_gate)
                {
                    Scan(dir);
                    var cutoff = DateTimeOffset.UtcNow - Keep;
                    return _files.Values.SelectMany(f => f.Entries).Where(e => e.At >= cutoff).ToList();
                }
            }

            public Plan? LatestPlan(string dir)
            {
                lock (_gate)
                {
                    Scan(dir);
                    return _files.Values.SelectMany(f => f.Entries)
                        .Where(e => e.Plan != null)
                        .OrderByDescending(e => e.At)
                        .Select(e => e.Plan)
                        .FirstOrDefault();
                }
            }

            private void Scan(string dir)
            {
                if (!Directory.Exists(dir)) return;
                var since = DateTime.UtcNow - Keep;
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var path in Directory.EnumerateFiles(dir, "*.jsonl", SearchOption.AllDirectories))
                {
                    FileInfo fi;
                    try { fi = new FileInfo(path); }
                    catch { continue; }
                    if (fi.LastWriteTimeUtc < since) continue;
                    seen.Add(path);
                    if (!_files.TryGetValue(path, out var st)) _files[path] = st = new FileState();
                    if (fi.Length < st.Offset)
                    {
                        // Arquivo reescrito: começa de novo.
                        st.Offset = 0;
                        st.Entries.Clear();
                        st.Ids.Clear();
                    }
                    if (fi.Length == st.Offset) continue;
                    try { ReadFrom(path, st); }
                    catch (IOException) { }
                    catch (UnauthorizedAccessException) { }
                }
                foreach (var gone in _files.Keys.Where(k => !seen.Contains(k)).ToList())
                    _files.Remove(gone);
            }

            private void ReadFrom(string path, FileState st)
            {
                // O Claude Code e o Codex continuam escrevendo enquanto lemos; um registro passa
                // de centenas de MB, então vai em pedaços e só linhas completas contam.
                using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                fs.Seek(st.Offset, SeekOrigin.Begin);
                var marker = Encoding.UTF8.GetBytes(_marker);
                var chunk = new byte[1 << 20];
                var line = new MemoryStream();
                int n;
                while ((n = fs.Read(chunk, 0, chunk.Length)) > 0)
                {
                    var start = 0;
                    for (var i = 0; i < n; i++)
                    {
                        if (chunk[i] != (byte)'\n') continue;
                        line.Write(chunk, start, i - start);
                        st.Offset += line.Length + 1;
                        Handle(line, marker, st);
                        line.SetLength(0);
                        start = i + 1;
                    }
                    line.Write(chunk, start, n - start);
                }
            }

            private void Handle(MemoryStream line, byte[] marker, FileState st)
            {
                var bytes = new ReadOnlySpan<byte>(line.GetBuffer(), 0, (int)line.Length);
                if (bytes.IndexOf(marker) < 0) return;
                Entry? e;
                try { e = _parse(Encoding.UTF8.GetString(bytes)); }
                catch (JsonException) { return; }
                catch (FormatException) { return; }
                catch (InvalidOperationException) { return; }
                if (e == null) return;
                if (e.Id != null && !st.Ids.Add(e.Id)) return;
                st.Entries.Add(e);
            }
        }
    }
}
