using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using DeckOS.Lib;
using Microsoft.Win32;

namespace DeckOS.Services
{
    /// <summary>
    /// Jogos instalados na Steam: le as bibliotecas (libraryfolders.vdf) e os manifestos
    /// (appmanifest_*.acf), e monta um icone quadrado a partir da capa que a Steam guarda
    /// em appcache/librarycache. Nada disso exige login nem rede.
    /// </summary>
    public class SteamLibrary
    {
        /// <summary>Ferramentas que a Steam instala como "apps" e nao sao jogos.</summary>
        private static readonly HashSet<string> NotGames = new() { "228980", "1070560", "1391110", "1628350", "1493710" };

        private static readonly Regex PathRx = new("\"path\"\\s+\"([^\"]+)\"", RegexOptions.Compiled);
        private static readonly Regex AppIdRx = new("\"appid\"\\s+\"(\\d+)\"", RegexOptions.Compiled);
        private static readonly Regex NameRx = new("\"name\"\\s+\"([^\"]+)\"", RegexOptions.Compiled);

        public record Game(string AppId, string Name);

        public string? SteamPath
        {
            get
            {
                if (!OperatingSystem.IsWindows()) return UnixSteamPath();
                try
                {
                    using var key = Registry.CurrentUser.OpenSubKey(@"Software\Valve\Steam");
                    var path = key?.GetValue("SteamPath") as string;
                    return path != null && Directory.Exists(path) ? Path.GetFullPath(path) : null;
                }
                catch
                {
                    return null;
                }
            }
        }

        /// <summary>Pasta da Steam no macOS e no Linux (nativa, o link ~/.steam/steam e o Flatpak).</summary>
        private static string? UnixSteamPath()
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var candidates = OperatingSystem.IsMacOS()
                ? new[] { Path.Combine(home, "Library", "Application Support", "Steam") }
                : new[]
                {
                    Path.Combine(home, ".steam", "steam"),
                    Path.Combine(home, ".local", "share", "Steam"),
                    Path.Combine(home, ".var", "app", "com.valvesoftware.Steam", ".local", "share", "Steam"),
                };
            return candidates.FirstOrDefault(d => Directory.Exists(Path.Combine(d, "steamapps")));
        }

        public List<Game> Games()
        {
            var steam = SteamPath;
            if (steam == null) return new List<Game>();

            var libraries = new List<string> { steam };
            var vdf = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
            if (File.Exists(vdf))
            {
                foreach (Match m in PathRx.Matches(File.ReadAllText(vdf)))
                    libraries.Add(m.Groups[1].Value.Replace(@"\\", @"\"));
            }

            var games = new Dictionary<string, Game>();
            foreach (var lib in libraries.Distinct(StringComparer.OrdinalIgnoreCase))
            {
                var apps = Path.Combine(lib, "steamapps");
                if (!Directory.Exists(apps)) continue;
                foreach (var acf in Directory.EnumerateFiles(apps, "appmanifest_*.acf"))
                {
                    try
                    {
                        var text = File.ReadAllText(acf);
                        var id = AppIdRx.Match(text).Groups[1].Value;
                        var name = NameRx.Match(text).Groups[1].Value;
                        if (id.Length == 0 || name.Length == 0 || NotGames.Contains(id)) continue;
                        if (name.Contains("Redistributable", StringComparison.OrdinalIgnoreCase) ||
                            name.StartsWith("Proton", StringComparison.OrdinalIgnoreCase) ||
                            name.StartsWith("Steam Linux Runtime", StringComparison.OrdinalIgnoreCase))
                            continue;
                        games[id] = new Game(id, name);
                    }
                    catch (IOException) { }
                }
            }
            return games.Values.OrderBy(g => g.Name, StringComparer.OrdinalIgnoreCase).ToList();
        }

        /// <summary>
        /// Icone quadrado (PNG em base64) para o botao: o miolo da capa vertical, ou a capa
        /// horizontal se a vertical nao estiver no cache. Null se a Steam ainda nao baixou
        /// nenhuma imagem do jogo.
        /// </summary>
        public string? IconBase64(string appId, int size = 192)
        {
            if (!Regex.IsMatch(appId, @"^\d+$")) return null;
            var steam = SteamPath;
            if (steam == null) return null;

            var cache = Path.Combine(steam, "appcache", "librarycache");
            var candidates = new[]
            {
                Path.Combine(cache, appId, "library_600x900.jpg"),
                Path.Combine(cache, $"{appId}_library_600x900.jpg"),
                Path.Combine(cache, appId, "header.jpg"),
                Path.Combine(cache, $"{appId}_header.jpg"),
            };
            var file = candidates.FirstOrDefault(File.Exists);
            if (file == null) return null;

            try
            {
                return Convert.ToBase64String(ImageOps.SquareCropPng(file, size));
            }
            catch
            {
                return null;
            }
        }
    }
}
