using System.Collections.Generic;
using System.Text;

namespace DeckOS.Platform
{
    /// <summary>
    /// Divide o campo "Argumentos" de um botao em argv, como um shell faria (aspas simples e
    /// duplas agrupam, \ escapa fora das simples), sem rodar shell nenhum. No Windows o texto
    /// vai inteiro para o ProcessStartInfo.Arguments; macOS e Linux precisam da lista.
    /// </summary>
    public static class CommandLine
    {
        public static List<string> Split(string? text)
        {
            var args = new List<string>();
            if (string.IsNullOrWhiteSpace(text)) return args;
            var sb = new StringBuilder();
            char quote = '\0';
            var hasToken = false;
            for (var i = 0; i < text.Length; i++)
            {
                var c = text[i];
                if (quote == '\'')
                {
                    if (c == '\'') quote = '\0';
                    else sb.Append(c);
                    continue;
                }
                if (c == '\\' && i + 1 < text.Length && (quote == '\0' || text[i + 1] is '"' or '\\'))
                {
                    sb.Append(text[++i]);
                    hasToken = true;
                    continue;
                }
                if (quote == '"')
                {
                    if (c == '"') quote = '\0';
                    else sb.Append(c);
                    continue;
                }
                if (c is '"' or '\'')
                {
                    quote = c;
                    hasToken = true;
                    continue;
                }
                if (char.IsWhiteSpace(c))
                {
                    if (hasToken) { args.Add(sb.ToString()); sb.Clear(); hasToken = false; }
                    continue;
                }
                sb.Append(c);
                hasToken = true;
            }
            if (hasToken) args.Add(sb.ToString());
            return args;
        }
    }
}
