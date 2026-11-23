using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace DeckOS.Lib
{
    /// <summary>
    /// Arquivo de segredo (apikey, discord.json, obs.json, tuya.json) cifrado com DPAPI no
    /// escopo do usuario do Windows. Antes ficava tudo em texto puro em %LocalAppData%:
    /// qualquer programa rodando como o usuario -- ou um backup sincronizado -- levava o
    /// Client Secret do Discord, a senha do OBS e o token da conta Tuya.
    ///
    /// Formato: a linha "DDSECRET1" seguida do blob DPAPI em base64. Um arquivo sem esse
    /// cabecalho e tratado como texto puro legado: e lido normalmente e regravado cifrado na
    /// hora, entao quem atualiza nao precisa reconfigurar nada. Isso tambem deixa editar a
    /// mao (ex.: trocar o ClientId da Tuya): grava-se o JSON puro e ele e cifrado no proximo load.
    ///
    /// O blob so abre na mesma conta do Windows na mesma maquina. Copiar a pasta para outro
    /// PC nao leva os segredos -- as integracoes precisam ser configuradas de novo.
    ///
    /// macOS e Linux nao tem DPAPI: o arquivo fica em texto, so com permissao do dono (600),
    /// como o ~/.ssh. Um arquivo cifrado vindo do Windows nao abre la.
    /// </summary>
    public static class SecretFile
    {
        private const string Header = "DDSECRET1";

        // Nao e segredo: so separa os blobs do DeckOS dos de outros apps do mesmo usuario.
        // Nome antigo de proposito: mudar a entropia deixaria ilegiveis os segredos ja gravados.
        private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("DroidDeck.SecretFile.v1");

        /// <summary>Le e decifra. Arquivo legado em texto puro e migrado para cifrado.</summary>
        public static string ReadAllText(string path)
        {
            var content = File.ReadAllText(path);
            if (TryUnwrap(content, out var plain)) return plain;

            if (!OperatingSystem.IsWindows())
            {
                OwnerOnly(path);
                return content;
            }
            try { WriteAllText(path, content); } catch { /* migra na proxima gravacao */ }
            return content;
        }

        /// <summary>
        /// Cifra e grava de forma atomica (temporario + troca), para uma queda no meio nao
        /// deixar o arquivo truncado.
        /// </summary>
        public static void WriteAllText(string path, string contents)
        {
            var tmp = path + ".tmp";
            try
            {
                File.WriteAllText(tmp, Wrap(contents));
                OwnerOnly(tmp);
                File.Move(tmp, path, overwrite: true);
            }
            catch
            {
                try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
                throw;
            }
        }

        internal static string Wrap(string plain)
        {
            if (!OperatingSystem.IsWindows()) return plain;
            var blob = ProtectedData.Protect(Encoding.UTF8.GetBytes(plain), Entropy, DataProtectionScope.CurrentUser);
            return Header + "\n" + Convert.ToBase64String(blob);
        }

        internal static bool TryUnwrap(string content, out string plain)
        {
            plain = string.Empty;
            if (!content.StartsWith(Header + "\n", StringComparison.Ordinal)) return false;
            if (!OperatingSystem.IsWindows())
                throw new CryptographicException("Segredo cifrado no Windows (DPAPI): configure a integração de novo neste computador.");

            var blob = Convert.FromBase64String(content.Substring(Header.Length + 1).Trim());
            plain = Encoding.UTF8.GetString(ProtectedData.Unprotect(blob, Entropy, DataProtectionScope.CurrentUser));
            return true;
        }

        /// <summary>Fora do Windows: so o dono le e escreve (rw-------).</summary>
        private static void OwnerOnly(string path)
        {
            if (OperatingSystem.IsWindows()) return;
            try { File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite); }
            catch { }
        }
    }
}
