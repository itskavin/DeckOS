using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;
using DeckOS.Lib.Input;

namespace DeckOS.Platform.MacOS
{
    /// <summary>
    /// osascript: AppleScript (-e) e JavaScript for Automation (-l JavaScript). Vem com o macOS.
    /// O texto de botao entra sempre como literal JSON dentro do script, nunca colado cru.
    /// </summary>
    public static class Osa
    {
        public static string AppleScript(string script, int timeoutMs = 5000) =>
            Tools.Check("osascript", new[] { "-e", script }, timeoutMs).Trim();

        public static string Js(string script, int timeoutMs = 5000) =>
            Tools.Check("osascript", new[] { "-l", "JavaScript", "-e", script }, timeoutMs).Trim();

        /// <summary>Literal de string seguro para JavaScript (e AppleScript nao: use <see cref="AppleString"/>).</summary>
        public static string JsString(string value) =>
            JsonSerializer.Serialize(value, new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });

        /// <summary>Literal de string do AppleScript ("..." com \ e " escapados).</summary>
        public static string AppleString(string value) =>
            "\"" + value.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

        // Tecla de midia: evento NSSystemDefined (subtipo 8) com o NX_KEYTYPE_*; e o que o
        // teclado do Mac manda, entao vai para o app que esta tocando (Music, Spotify, Safari...).
        public const string MediaKeyFunction =
            "ObjC.import('Cocoa');" +
            "function mk(k){[0xa,0xb].forEach(function(s){" +
            "var e=$.NSEvent.otherEventWithTypeLocationModifierFlagsTimestampWindowNumberContextSubtypeData1Data2(" +
            "14,{x:0,y:0},(s<<8),0,0,null,8,(k<<16)|(s<<8),-1);" +
            "$.CGEventPost(0,e.CGEvent);});}";

        public static void MediaKey(int nxKeyType) => Js(MediaKeyFunction + $"mk({nxKeyType});");
    }

    /// <summary>
    /// Teclado no macOS. Toques e texto pelo System Events (keystroke/key code); segurar e
    /// soltar por CGEvent, que o System Events nao faz para teclas comuns. As duas coisas
    /// exigem que o DeckOS (ou o Terminal que o abriu) esteja em Ajustes do Sistema >
    /// Privacidade e Seguranca > Acessibilidade.
    ///
    /// Ctrl continua Control; a tecla Windows (# no atalho) e o Command.
    /// </summary>
    public sealed class MacKeyboard : IKeyboardInput, IDisposable
    {
        private readonly CommandQueue _queue = new("teclado");
        private long _heldFlags;

        public bool TryResolveChar(char c, out ushort vk) => KeyMaps.TryUsChar(c, out vk, out _);

        public void KeyDown(ushort vk) => _queue.Post(() => Press(vk, down: true), "down:" + vk);

        public void KeyUp(ushort vk) => _queue.Post(() => Press(vk, down: false));

        private void Press(ushort vk, bool down)
        {
            if (KeyMaps.MacMediaKeys.TryGetValue(vk, out var media))
            {
                if (down) Osa.MediaKey(media);
                return;
            }
            var code = KeyMaps.MacKeyCode(vk) ?? throw new InvalidOperationException($"Tecla 0x{vk:X2} sem equivalente no Mac.");
            var flag = KeyMaps.MacModifierFlag(vk);
            if (flag != 0)
            {
                // Modificador: evento flagsChanged com o conjunto inteiro, senao o sistema nao o
                // considera apertado nas proximas teclas.
                _heldFlags = down ? _heldFlags | flag : _heldFlags & ~flag;
                Osa.Js("ObjC.import('ApplicationServices');" +
                       $"var e=$.CGEventCreateKeyboardEvent(null,{code},{(down ? "true" : "false")});" +
                       $"$.CGEventSetType(e,12);$.CGEventSetFlags(e,{_heldFlags});$.CGEventPost(0,e);");
                return;
            }
            Osa.Js("ObjC.import('ApplicationServices');" +
                   $"var e=$.CGEventCreateKeyboardEvent(null,{code},{(down ? "true" : "false")});" +
                   (_heldFlags != 0 ? $"$.CGEventSetFlags(e,{_heldFlags});" : "") +
                   "$.CGEventPost(0,e);");
        }

        public void Send(IReadOnlyList<KeyStroke> strokes) => _queue.Send(() => Osa.Js(Script(strokes), 15000));

        /// <summary>O script JXA de uma sequencia. Publico para os testes.</summary>
        public static string Script(IReadOnlyList<KeyStroke> strokes)
        {
            var sb = new StringBuilder("var se=Application('System Events');");
            var needsMedia = false;
            var text = new StringBuilder();
            void FlushText()
            {
                if (text.Length == 0) return;
                sb.Append("se.keystroke(").Append(Osa.JsString(text.ToString())).Append(");");
                text.Clear();
            }

            foreach (var s in strokes)
            {
                if (s.IsChar && s.Modifiers == KeyModifiers.None && s.Char != '\n' && s.Char != '\t')
                {
                    text.Append(s.Char);
                    continue;
                }
                FlushText();

                var mods = s.Modifiers;
                int? code = null;
                string? keystroke = null;
                if (s.IsChar)
                {
                    if (s.Char == '\n') code = 36;
                    else if (s.Char == '\t') code = 48;
                    else keystroke = char.ToLowerInvariant(s.Char).ToString();
                }
                else if (KeyMaps.MacMediaKeys.TryGetValue(s.VirtualKey, out var media))
                {
                    needsMedia = true;
                    sb.Append($"mk({media});");
                    continue;
                }
                else
                {
                    code = KeyMaps.MacKeyCode(s.VirtualKey);
                    if (code == null) continue;
                }

                var using_ = Using(mods);
                if (keystroke != null)
                    sb.Append("se.keystroke(").Append(Osa.JsString(keystroke)).Append(using_).Append(");");
                else
                    sb.Append("se.keyCode(").Append(code).Append(using_).Append(");");
                sb.Append("delay(0.01);");
            }
            FlushText();
            return needsMedia ? Osa.MediaKeyFunction + sb : sb.ToString();
        }

        private static string Using(KeyModifiers mods)
        {
            var list = new List<string>();
            if (mods.HasFlag(KeyModifiers.Ctrl)) list.Add("'control down'");
            if (mods.HasFlag(KeyModifiers.Alt)) list.Add("'option down'");
            if (mods.HasFlag(KeyModifiers.Shift)) list.Add("'shift down'");
            if (mods.HasFlag(KeyModifiers.Win)) list.Add("'command down'");
            return list.Count == 0 ? "" : ",{using:[" + string.Join(",", list) + "]}";
        }

        public void Dispose() => _queue.Dispose();
    }
}
