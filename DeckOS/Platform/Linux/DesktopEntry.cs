using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

namespace DeckOS.Platform.Linux
{
    /// <summary>
    /// Arquivo .desktop (Desktop Entry Specification 1.5): so o grupo [Desktop Entry], que e
    /// o que o menu de apps usa. Chaves localizadas (Name[pt_BR]) ficam com o sufixo.
    /// </summary>
    public sealed class DesktopEntry
    {
        private readonly Dictionary<string, string> _values;

        private DesktopEntry(Dictionary<string, string> values) => _values = values;

        public string? this[string key] => _values.TryGetValue(key, out var v) ? v : null;

        public string? Type => this["Type"];
        public string? Exec => this["Exec"];
        public string? Icon => this["Icon"];
        public string? TryExec => this["TryExec"];
        public string? WorkingDirectory => this["Path"];
        public bool NoDisplay => IsTrue(this["NoDisplay"]);
        public bool Hidden => IsTrue(this["Hidden"]);
        public bool Terminal => IsTrue(this["Terminal"]);
        public IReadOnlyList<string> OnlyShowIn => List(this["OnlyShowIn"]);
        public IReadOnlyList<string> NotShowIn => List(this["NotShowIn"]);

        private static bool IsTrue(string? v) => string.Equals(v?.Trim(), "true", StringComparison.OrdinalIgnoreCase);

        private static IReadOnlyList<string> List(string? v) =>
            v?.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) ?? Array.Empty<string>();

        /// <summary>
        /// Name no idioma pedido ("pt_BR.UTF-8" tenta Name[pt_BR], depois Name[pt]), senao o Name.
        /// </summary>
        public string? Name(string? locale = null)
        {
            if (!string.IsNullOrEmpty(locale))
            {
                var clean = locale.Split('.', '@')[0];
                if (this[$"Name[{clean}]"] is { Length: > 0 } full) return full;
                var lang = clean.Split('_')[0];
                if (this[$"Name[{lang}]"] is { Length: > 0 } shortName) return shortName;
            }
            return this["Name"];
        }

        /// <summary>E um app que o menu mostraria (Application, sem NoDisplay/Hidden, com Exec)?</summary>
        public bool IsVisibleApplication(string? currentDesktop = null)
        {
            if (!string.Equals(Type, "Application", StringComparison.Ordinal) || NoDisplay || Hidden) return false;
            if (string.IsNullOrWhiteSpace(Exec) || string.IsNullOrWhiteSpace(Name())) return false;
            if (!string.IsNullOrEmpty(currentDesktop))
            {
                var desktops = currentDesktop.Split(':', StringSplitOptions.RemoveEmptyEntries);
                if (OnlyShowIn.Count > 0 && !OnlyShowIn.Intersect(desktops, StringComparer.OrdinalIgnoreCase).Any()) return false;
                if (NotShowIn.Intersect(desktops, StringComparer.OrdinalIgnoreCase).Any()) return false;
            }
            return true;
        }

        /// <summary>Le o texto de um .desktop. Comentarios e outros grupos ([Desktop Action ...]) ficam de fora.</summary>
        public static DesktopEntry Parse(string text)
        {
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            var inEntry = false;
            foreach (var raw in text.Split('\n'))
            {
                var line = raw.TrimEnd('\r').Trim();
                if (line.Length == 0 || line.StartsWith('#')) continue;
                if (line.StartsWith('[') && line.EndsWith(']'))
                {
                    inEntry = line == "[Desktop Entry]";
                    continue;
                }
                if (!inEntry) continue;
                var eq = line.IndexOf('=');
                if (eq <= 0) continue;
                var key = line[..eq].Trim();
                // A primeira ocorrencia vale (a especificacao proibe repetir).
                values.TryAdd(key, Unescape(line[(eq + 1)..].Trim()));
            }
            return new DesktopEntry(values);
        }

        /// <summary>Escapes de valor string: \s \n \t \r \\ (os de Exec sao tratados depois).</summary>
        private static string Unescape(string value)
        {
            if (!value.Contains('\\')) return value;
            var sb = new StringBuilder(value.Length);
            for (var i = 0; i < value.Length; i++)
            {
                var c = value[i];
                if (c == '\\' && i + 1 < value.Length)
                {
                    var n = value[++i];
                    sb.Append(n switch { 's' => ' ', 'n' => '\n', 't' => '\t', 'r' => '\r', '\\' => '\\', _ => '\\' });
                    if (n is not ('s' or 'n' or 't' or 'r' or '\\')) sb.Append(n);
                }
                else
                {
                    sb.Append(c);
                }
            }
            return sb.ToString();
        }

        /// <summary>
        /// Exec em argumentos, sem os codigos de campo (%f %U %i...): o DeckOS abre o app sem
        /// arquivo. Aspas duplas agrupam; dentro delas \" \` \$ \\ escapam.
        /// </summary>
        public List<string> ExecArgs()
        {
            var exec = Exec;
            var args = new List<string>();
            if (string.IsNullOrWhiteSpace(exec)) return args;

            var current = new StringBuilder();
            var quoted = false;
            var hasToken = false;
            for (var i = 0; i < exec.Length; i++)
            {
                var c = exec[i];
                if (quoted)
                {
                    if (c == '\\' && i + 1 < exec.Length && exec[i + 1] is '"' or '`' or '$' or '\\') { current.Append(exec[++i]); continue; }
                    if (c == '"') { quoted = false; continue; }
                    current.Append(c);
                    continue;
                }
                if (c == '"') { quoted = true; hasToken = true; continue; }
                if (char.IsWhiteSpace(c))
                {
                    if (hasToken || current.Length > 0) Flush();
                    continue;
                }
                current.Append(c);
                hasToken = true;
            }
            if (hasToken || current.Length > 0) Flush();
            return args;

            void Flush()
            {
                var token = current.ToString();
                current.Clear();
                hasToken = false;
                // Argumento que e so um codigo de campo some; %% vira %.
                if (token.Length == 2 && token[0] == '%' && token[1] != '%') return;
                token = RemoveFieldCodes(token);
                if (token.Length > 0) args.Add(token);
            }
        }

        private static string RemoveFieldCodes(string token)
        {
            if (!token.Contains('%')) return token;
            var sb = new StringBuilder();
            for (var i = 0; i < token.Length; i++)
            {
                if (token[i] == '%' && i + 1 < token.Length)
                {
                    if (token[i + 1] == '%') sb.Append('%');
                    i++;
                    continue;
                }
                sb.Append(token[i]);
            }
            return sb.ToString();
        }

        /// <summary>Pastas de .desktop do XDG, na ordem de prioridade (a do usuario primeiro).</summary>
        public static List<string> ApplicationDirs(Func<string, string?> env, string home)
        {
            var dataHome = env("XDG_DATA_HOME") is { Length: > 0 } dh ? dh : Path.Combine(home, ".local", "share");
            var dataDirs = (env("XDG_DATA_DIRS") is { Length: > 0 } dd ? dd : "/usr/local/share:/usr/share")
                .Split(':', StringSplitOptions.RemoveEmptyEntries);
            var dirs = new List<string> { Path.Combine(dataHome, "applications") };
            dirs.AddRange(dataDirs.Select(d => Path.Combine(d, "applications")));
            // Flatpak e Snap nem sempre entram no XDG_DATA_DIRS de um servico do systemd --user.
            dirs.Add(Path.Combine(dataHome, "flatpak", "exports", "share", "applications"));
            dirs.Add("/var/lib/flatpak/exports/share/applications");
            dirs.Add("/var/lib/snapd/desktop/applications");
            return dirs.Select(d => d.TrimEnd('/')).Distinct().ToList();
        }

        /// <summary>O .desktop esta numa pasta onde o gtk-launch o acha pelo id?</summary>
        public static bool InXdgDirs(string path)
        {
            var dir = Path.GetDirectoryName(Path.GetFullPath(path))?.TrimEnd('/');
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return dir != null && ApplicationDirs(Environment.GetEnvironmentVariable, home).Contains(dir);
        }
    }
}
