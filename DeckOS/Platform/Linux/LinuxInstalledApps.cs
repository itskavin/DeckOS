using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading.Tasks;

namespace DeckOS.Platform.Linux
{
    /// <summary>
    /// Apps do menu: os .desktop das pastas do XDG (e as exportacoes do Flatpak e do Snap).
    /// Um id de arquivo repetido vale o da pasta de maior prioridade, como no menu.
    /// </summary>
    public sealed class LinuxInstalledApps : InstalledAppsBase
    {
        private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        protected override IEnumerable<InstalledApp> Scan()
        {
            var locale = Environment.GetEnvironmentVariable("LC_ALL") is { Length: > 0 } all ? all
                : Environment.GetEnvironmentVariable("LC_MESSAGES") is { Length: > 0 } msg ? msg
                : Environment.GetEnvironmentVariable("LANG");
            var desktop = Environment.GetEnvironmentVariable("XDG_CURRENT_DESKTOP");
            var seen = new HashSet<string>(StringComparer.Ordinal);

            foreach (var dir in DesktopEntry.ApplicationDirs(Environment.GetEnvironmentVariable, Home))
            {
                if (!Directory.Exists(dir)) continue;
                IEnumerable<string> files;
                try { files = Directory.EnumerateFiles(dir, "*.desktop", SearchOption.AllDirectories).ToList(); }
                catch (Exception) { continue; }
                foreach (var file in files)
                {
                    // Id do arquivo: caminho relativo com / trocado por - (kde4/foo.desktop -> kde4-foo.desktop).
                    var fileId = Path.GetRelativePath(dir, file).Replace('/', '-');
                    if (!seen.Add(fileId)) continue;
                    DesktopEntry entry;
                    try { entry = DesktopEntry.Parse(File.ReadAllText(file)); }
                    catch (Exception) { continue; }
                    if (!entry.IsVisibleApplication(desktop)) continue;
                    if (entry.TryExec is { Length: > 0 } tryExec && Tools.Which(tryExec) == null) continue;
                    yield return new InstalledApp(MakeId(file), entry.Name(locale)!.Trim(), file)
                    {
                        IconSource = entry.Icon,
                    };
                }
            }
        }

        protected override async Task<(byte[] Data, string ContentType)?> LoadIconAsync(InstalledApp app)
        {
            if (string.IsNullOrWhiteSpace(app.IconSource)) return null;
            var file = IconResolver.Find(app.IconSource, IconResolver.IconRoots(Environment.GetEnvironmentVariable, Home), IconResolver.PixmapDirs);
            if (file == null) return null;
            var type = file.EndsWith(".svg", StringComparison.OrdinalIgnoreCase) ? "image/svg+xml" : "image/png";
            return (await File.ReadAllBytesAsync(file), type);
        }
    }

    /// <summary>
    /// Icone de um .desktop pelo tema (Icon Theme Specification): caminho absoluto, ou o nome
    /// procurado no hicolor e nos outros temas instalados, do maior PNG ao SVG, e por fim no
    /// /usr/share/pixmaps. XPM fica de fora (o navegador nao mostra).
    /// </summary>
    public static class IconResolver
    {
        // Do melhor para o pior num botao de ~150 px.
        private static readonly string[] Sizes =
        {
            "256x256", "512x512", "scalable", "192x192", "128x128", "96x96", "72x72", "64x64", "48x48", "32x32",
        };

        private static readonly string[] Extensions = { ".png", ".svg" };

        public static readonly string[] PixmapDirs = { "/usr/share/pixmaps", "/usr/local/share/pixmaps" };

        /// <summary>Pastas "icons" do XDG (a do usuario primeiro).</summary>
        public static List<string> IconRoots(Func<string, string?> env, string home)
        {
            var dataHome = env("XDG_DATA_HOME") is { Length: > 0 } dh ? dh : Path.Combine(home, ".local", "share");
            var dataDirs = (env("XDG_DATA_DIRS") is { Length: > 0 } dd ? dd : "/usr/local/share:/usr/share")
                .Split(':', StringSplitOptions.RemoveEmptyEntries);
            var roots = new List<string> { Path.Combine(home, ".icons"), Path.Combine(dataHome, "icons") };
            roots.AddRange(dataDirs.Select(d => Path.Combine(d, "icons")));
            roots.Add(Path.Combine(dataHome, "flatpak", "exports", "share", "icons"));
            roots.Add("/var/lib/flatpak/exports/share/icons");
            return roots.Distinct().ToList();
        }

        public static string? Find(string icon, IReadOnlyList<string> roots, IReadOnlyList<string> pixmapDirs)
        {
            icon = icon.Trim();
            if (icon.Length == 0) return null;
            if (Path.IsPathRooted(icon))
                return File.Exists(icon) && Extensions.Contains(Path.GetExtension(icon).ToLowerInvariant()) ? icon : null;

            // "firefox.png" no Icon= e permitido (fora da especificacao, mas comum).
            var name = Extensions.Contains(Path.GetExtension(icon).ToLowerInvariant()) ? Path.GetFileNameWithoutExtension(icon) : icon;

            // hicolor primeiro (e onde os apps instalam); depois qualquer outro tema que tiver o icone.
            foreach (var root in roots.Where(Directory.Exists))
            {
                var themes = new List<string> { Path.Combine(root, "hicolor") };
                try
                {
                    themes.AddRange(Directory.EnumerateDirectories(root)
                        .Where(d => !string.Equals(Path.GetFileName(d), "hicolor", StringComparison.Ordinal))
                        .OrderBy(d => d, StringComparer.Ordinal));
                }
                catch (Exception) { }

                foreach (var theme in themes.Where(Directory.Exists))
                {
                    foreach (var size in Sizes)
                    {
                        foreach (var ext in Extensions)
                        {
                            var candidate = Path.Combine(theme, size, "apps", name + ext);
                            if (File.Exists(candidate)) return candidate;
                        }
                    }
                }
            }

            foreach (var dir in pixmapDirs)
            {
                foreach (var ext in Extensions)
                {
                    var candidate = Path.Combine(dir, name + ext);
                    if (File.Exists(candidate)) return candidate;
                }
            }
            return null;
        }
    }
}
