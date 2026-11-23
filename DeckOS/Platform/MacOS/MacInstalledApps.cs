using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using System.Xml.Linq;

namespace DeckOS.Platform.MacOS
{
    /// <summary>
    /// Info.plist de um .app: so as chaves de texto do dicionario de cima (CFBundleName,
    /// CFBundleIconFile...). O plist binario (bplist00) passa antes pelo plutil.
    /// </summary>
    public static class Plist
    {
        public static Dictionary<string, string> ParseXml(string xml)
        {
            var result = new Dictionary<string, string>(StringComparer.Ordinal);
            // DTD da Apple no cabecalho: ignorado (nada de buscar o .dtd na rede).
            var settings = new System.Xml.XmlReaderSettings { DtdProcessing = System.Xml.DtdProcessing.Ignore, XmlResolver = null };
            using var reader = System.Xml.XmlReader.Create(new StringReader(xml), settings);
            var doc = XDocument.Load(reader);
            var dict = doc.Root?.Element("dict");
            if (dict == null) return result;
            string? key = null;
            foreach (var el in dict.Elements())
            {
                if (el.Name.LocalName == "key")
                {
                    key = el.Value;
                    continue;
                }
                if (key == null) continue;
                switch (el.Name.LocalName)
                {
                    case "string":
                    case "integer":
                    case "real":
                        result[key] = el.Value;
                        break;
                    case "true":
                    case "false":
                        result[key] = el.Name.LocalName;
                        break;
                }
                key = null;
            }
            return result;
        }

        /// <summary>Le um Info.plist do disco (XML direto; binario pelo plutil). Vazio se nao der.</summary>
        public static Dictionary<string, string> Read(string path)
        {
            try
            {
                var bytes = File.ReadAllBytes(path);
                string xml;
                if (bytes.Length > 6 && Encoding.ASCII.GetString(bytes, 0, 6) == "bplist")
                {
                    var r = Tools.Run("plutil", new[] { "-convert", "xml1", "-o", "-", path }, 3000);
                    if (!r.Ok) return new Dictionary<string, string>();
                    xml = r.Output;
                }
                else
                {
                    xml = Encoding.UTF8.GetString(bytes);
                }
                return ParseXml(xml);
            }
            catch (Exception)
            {
                return new Dictionary<string, string>();
            }
        }

        /// <summary>
        /// O .icns do app: CFBundleIconFile (com ou sem extensao) em Contents/Resources; sem ele,
        /// AppIcon.icns ou o primeiro .icns da pasta. Apps so com Assets.car (CFBundleIconName)
        /// e sem .icns ficam sem icone.
        /// </summary>
        public static string? IconPath(string appPath, IReadOnlyDictionary<string, string> info)
        {
            var resources = Path.Combine(appPath, "Contents", "Resources");
            if (!Directory.Exists(resources)) return null;
            var candidates = new List<string>();
            if (info.TryGetValue("CFBundleIconFile", out var file) && file.Trim().Length > 0)
            {
                file = file.Trim();
                candidates.Add(Path.Combine(resources, file));
                if (!file.EndsWith(".icns", StringComparison.OrdinalIgnoreCase)) candidates.Add(Path.Combine(resources, file + ".icns"));
            }
            if (info.TryGetValue("CFBundleIconName", out var name) && name.Trim().Length > 0)
                candidates.Add(Path.Combine(resources, name.Trim() + ".icns"));
            candidates.Add(Path.Combine(resources, "AppIcon.icns"));
            var found = candidates.FirstOrDefault(File.Exists);
            if (found != null) return found;
            try { return Directory.EnumerateFiles(resources, "*.icns").OrderBy(f => f, StringComparer.Ordinal).FirstOrDefault(); }
            catch (Exception) { return null; }
        }

        /// <summary>Nome do app: CFBundleDisplayName, CFBundleName ou o nome da pasta sem .app.</summary>
        public static string DisplayName(string appPath, IReadOnlyDictionary<string, string> info)
        {
            var folder = Path.GetFileNameWithoutExtension(appPath.TrimEnd('/'));
            // O Finder mostra o nome da pasta; o plist so ajuda quando ela tem sufixo de versao.
            if (info.TryGetValue("CFBundleDisplayName", out var display) && display.Trim().Length > 0 &&
                folder.StartsWith(display.Trim(), StringComparison.OrdinalIgnoreCase))
                return display.Trim();
            return folder;
        }
    }

    /// <summary>Apps de /Applications, /System/Applications e ~/Applications (e as subpastas de primeiro nivel).</summary>
    public sealed class MacInstalledApps : InstalledAppsBase
    {
        public static IEnumerable<string> Roots()
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            return new[]
            {
                "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                Path.Combine(home, "Applications"),
            };
        }

        protected override IEnumerable<InstalledApp> Scan()
        {
            foreach (var root in Roots().Where(Directory.Exists))
            {
                IEnumerable<string> dirs;
                try { dirs = Directory.EnumerateDirectories(root).ToList(); }
                catch (Exception) { continue; }
                foreach (var dir in dirs)
                {
                    if (dir.EndsWith(".app", StringComparison.OrdinalIgnoreCase))
                    {
                        if (Describe(dir) is { } app) yield return app;
                        continue;
                    }
                    // Pasta de fabricante (/Applications/Adobe.../Foo.app), um nivel so.
                    if (string.Equals(Path.GetFileName(dir), "Utilities", StringComparison.Ordinal)) continue;
                    IEnumerable<string> inner;
                    try { inner = Directory.EnumerateDirectories(dir, "*.app").ToList(); }
                    catch (Exception) { continue; }
                    foreach (var nested in inner)
                        if (Describe(nested) is { } app) yield return app;
                }
            }
        }

        private static InstalledApp? Describe(string appPath)
        {
            var info = Plist.Read(Path.Combine(appPath, "Contents", "Info.plist"));
            // Agentes e apps de fundo (LSUIElement/LSBackgroundOnly) nao abrem janela.
            if (info.TryGetValue("LSBackgroundOnly", out var bg) && bg == "true") return null;
            return new InstalledApp(MakeId(appPath), Plist.DisplayName(appPath, info), appPath)
            {
                IconSource = Plist.IconPath(appPath, info),
            };
        }

        protected override async Task<(byte[] Data, string ContentType)?> LoadIconAsync(InstalledApp app)
        {
            if (app.IconSource == null || !File.Exists(app.IconSource)) return null;
            var output = Path.Combine(Path.GetTempPath(), $"deckos-icon-{app.Id}.png");
            try
            {
                var r = await Tools.RunAsync("sips", new[] { "-s", "format", "png", "--resampleHeightWidthMax", "256", app.IconSource, "--out", output }, 10000);
                if (!r.Ok || !File.Exists(output)) return null;
                return (await File.ReadAllBytesAsync(output), "image/png");
            }
            finally
            {
                try { File.Delete(output); } catch { }
            }
        }
    }
}
