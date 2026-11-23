using System;
using System.IO;

namespace DeckOS.Lib
{
    /// <summary>
    /// Pastas de dados do DeckOS.
    ///   Windows: Local   (%LocalAppData%\DeckOS): chave, segredos das integracoes, cache.
    ///            Roaming (%AppData%\DeckOS):      perfis e grade.
    ///   macOS:   ~/Library/Application Support/DeckOS (e Roaming/ dentro dela).
    ///   Linux:   $XDG_CONFIG_HOME/deckos, ou ~/.config/deckos (e Roaming/ dentro dela).
    ///
    /// DECKOS_DATA_DIR troca as duas por uma pasta so (Roaming vira um subdiretorio).
    /// Existe para os testes: sem ela, subir o servidor num teste lia e regravava a chave e
    /// os segredos reais de quem estava desenvolvendo.
    ///
    /// O projeto se chamava DroidDeck: na primeira execucao, se a pasta antiga existe e a nova
    /// ainda nao, copia tudo para a nova (a antiga fica onde estava).
    /// </summary>
    public static class AppPaths
    {
        public const string DataDirEnvVar = "DECKOS_DATA_DIR";

        private static string? Override =>
            Environment.GetEnvironmentVariable(DataDirEnvVar) is { Length: > 0 } dir ? dir : null;

        private static readonly Lazy<bool> Migrated = new(MigrateLegacyDirs);

        public static string LocalDir => Ensure(Override ?? Default(DefaultLocal()));

        public static string RoamingDir => Ensure(Override is { } dir
            ? Path.Combine(dir, "Roaming")
            : OperatingSystem.IsWindows()
                ? Default(WindowsRoaming("DeckOS"))
                : Path.Combine(Default(DefaultLocal()), "Roaming"));

        /// <summary>A pasta Local de cada sistema (a do Windows nao muda: quem atualiza nao perde nada).</summary>
        public static string DefaultLocal(bool legacy = false) => ForOs(
            OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macos" : "linux",
            Environment.GetEnvironmentVariable,
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            legacy);

        /// <summary>Logica pura da pasta Local (para os testes). <paramref name="legacy"/> da a do DroidDeck.</summary>
        public static string ForOs(string os, Func<string, string?> env, string home, string localAppData, bool legacy = false) => os switch
        {
            "windows" => Path.Combine(localAppData, legacy ? "DroidDeck" : "DeckOS"),
            "macos" => Path.Combine(home, "Library", "Application Support", legacy ? "DroidDeck" : "DeckOS"),
            _ => Path.Combine(env("XDG_CONFIG_HOME") is { Length: > 0 } xdg ? xdg : Path.Combine(home, ".config"), legacy ? "droiddeck" : "deckos"),
        };

        private static string WindowsRoaming(string name) =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), name);

        private static string Default(string dir)
        {
            _ = Migrated.Value;
            return dir;
        }

        private static bool MigrateLegacyDirs()
        {
            // No macOS/Linux o Roaming mora dentro da Local, entao uma copia leva os dois.
            CopyLegacyDir(DefaultLocal(legacy: true), DefaultLocal());
            if (OperatingSystem.IsWindows())
                CopyLegacyDir(WindowsRoaming("DroidDeck"), WindowsRoaming("DeckOS"));
            return true;
        }

        /// <summary>Copia <paramref name="from"/> para <paramref name="to"/> se so a antiga existe.</summary>
        public static bool CopyLegacyDir(string from, string to)
        {
            if (!Directory.Exists(from) || Directory.Exists(to)) return false;
            var tmp = to + ".migrating";
            try
            {
                if (Directory.Exists(tmp)) Directory.Delete(tmp, recursive: true);
                CopyTree(from, tmp);
                // Copia numa pasta temporaria e renomeia no fim: se cair no meio, a proxima
                // execucao tenta de novo em vez de achar uma pasta nova pela metade.
                Directory.Move(tmp, to);
                return true;
            }
            catch
            {
                try { if (Directory.Exists(tmp)) Directory.Delete(tmp, recursive: true); } catch { }
                return false;
            }
        }

        private static void CopyTree(string from, string to)
        {
            Directory.CreateDirectory(to);
            foreach (var file in Directory.GetFiles(from))
                File.Copy(file, Path.Combine(to, Path.GetFileName(file)));
            foreach (var dir in Directory.GetDirectories(from))
                CopyTree(dir, Path.Combine(to, Path.GetFileName(dir)));
        }

        private static string Ensure(string dir)
        {
            Directory.CreateDirectory(dir);
            if (!OperatingSystem.IsWindows())
            {
                // Chave da API e segredos moram aqui: so o dono entra (rwx------).
                try { File.SetUnixFileMode(dir, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute); }
                catch { }
            }
            return dir;
        }
    }
}
