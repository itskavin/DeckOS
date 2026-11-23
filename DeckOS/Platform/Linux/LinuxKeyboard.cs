using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using DeckOS.Lib.Input;

namespace DeckOS.Platform.Linux
{
    /// <summary>
    /// Teclado no Linux por ferramenta externa: xdotool no X11; no Wayland, ydotool (qualquer
    /// compositor, precisa do ydotoold e de acesso ao /dev/uinput) ou wtype (wlroots: Sway,
    /// Hyprland). O xdotool no Wayland so alcanca apps do XWayland, entao fica por ultimo.
    /// </summary>
    public sealed class LinuxKeyboard : IKeyboardInput, IDisposable
    {
        private readonly CommandQueue _queue = new("teclado");

        private enum Tool { Xdotool, Ydotool, Wtype }

        private static Tool Pick()
        {
            if (Capabilities.LinuxSession(Environment.GetEnvironmentVariable) == "wayland")
            {
                if (Tools.Has("ydotool")) return Tool.Ydotool;
                if (Tools.Has("wtype")) return Tool.Wtype;
                if (Tools.Has("xdotool")) return Tool.Xdotool;
                throw new ToolMissingException("ydotool", "ydotool");
            }
            if (Tools.Has("xdotool")) return Tool.Xdotool;
            throw new ToolMissingException("xdotool", "xdotool");
        }

        public bool TryResolveChar(char c, out ushort vk) => KeyMaps.TryUsChar(c, out vk, out _);

        // Aperta-solta pela fila, na ordem; a repeticao de uma tecla segurada que ainda nao
        // rodou e descartada (ver CommandQueue).
        public void KeyDown(ushort vk) => _queue.Post(() => Press(vk, down: true), "down:" + vk);

        public void KeyUp(ushort vk) => _queue.Post(() => Press(vk, down: false));

        private static void Press(ushort vk, bool down)
        {
            switch (Pick())
            {
                case Tool.Ydotool:
                    var code = KeyMaps.Evdev(vk) ?? throw Unknown(vk);
                    Tools.Check("ydotool", new[] { "key", $"{code}:{(down ? 1 : 0)}" });
                    break;
                case Tool.Wtype:
                    Tools.Check("wtype", new[] { down ? "-P" : "-p", KeyMaps.X11Keysym(vk) ?? throw Unknown(vk) });
                    break;
                default:
                    Tools.Check("xdotool", new[] { down ? "keydown" : "keyup", KeyMaps.X11Keysym(vk) ?? throw Unknown(vk) });
                    break;
            }
        }

        private static Exception Unknown(ushort vk) =>
            new InvalidOperationException($"Tecla 0x{vk:X2} sem equivalente no Linux.");

        public void Send(IReadOnlyList<KeyStroke> strokes) => _queue.Send(() =>
        {
            var tool = Pick();
            foreach (var segment in Segments(strokes))
            {
                if (segment.Text != null) Type(tool, segment.Text);
                else Combo(tool, segment.Mods, segment.Vk);
            }
        });

        private readonly record struct Segment(string? Text, KeyModifiers Mods, ushort Vk);

        /// <summary>
        /// Caracteres seguidos sem modificador viram um texto so (um processo para a frase);
        /// o resto vira combinacao de teclas.
        /// </summary>
        private static IEnumerable<Segment> Segments(IReadOnlyList<KeyStroke> strokes)
        {
            var text = new StringBuilder();
            foreach (var s in strokes)
            {
                if (s.IsChar && s.Modifiers == KeyModifiers.None)
                {
                    text.Append(s.Char);
                    continue;
                }
                if (text.Length > 0) { yield return new Segment(text.ToString(), 0, 0); text.Clear(); }

                var vk = s.VirtualKey;
                var mods = s.Modifiers;
                if (s.IsChar)
                {
                    // ^c: a tecla do caractere no teclado americano (com Ctrl/Alt/Win a caixa nao pesa).
                    if (!KeyMaps.TryUsChar(s.Char, out vk, out var shift))
                    {
                        yield return new Segment(s.Char.ToString(), 0, 0);
                        continue;
                    }
                    if (shift && (mods & (KeyModifiers.Ctrl | KeyModifiers.Alt | KeyModifiers.Win)) == 0) mods |= KeyModifiers.Shift;
                }
                yield return new Segment(null, mods, vk);
            }
            if (text.Length > 0) yield return new Segment(text.ToString(), 0, 0);
        }

        private static void Type(Tool tool, string text)
        {
            switch (tool)
            {
                case Tool.Ydotool: Tools.Check("ydotool", new[] { "type", "--", text }, 15000); break;
                case Tool.Wtype: Tools.Check("wtype", new[] { "--", text }, 15000); break;
                default: Tools.Check("xdotool", new[] { "type", "--delay", "12", "--", text }, 15000); break;
            }
        }

        private static void Combo(Tool tool, KeyModifiers mods, ushort vk)
        {
            var modVks = new List<ushort>();
            if (mods.HasFlag(KeyModifiers.Ctrl)) modVks.Add(KeyMaps.VkCtrl);
            if (mods.HasFlag(KeyModifiers.Alt)) modVks.Add(KeyMaps.VkAlt);
            if (mods.HasFlag(KeyModifiers.Shift)) modVks.Add(KeyMaps.VkShift);
            if (mods.HasFlag(KeyModifiers.Win)) modVks.Add(KeyMaps.VkWin);

            switch (tool)
            {
                case Tool.Ydotool:
                    var codes = modVks.Append(vk).Select(k => KeyMaps.Evdev(k) ?? throw Unknown(k)).ToList();
                    var args = new List<string> { "key" };
                    args.AddRange(codes.Select(c => c + ":1"));
                    args.AddRange(Enumerable.Reverse(codes).Select(c => c + ":0"));
                    Tools.Check("ydotool", args);
                    break;
                case Tool.Wtype:
                    var wargs = new List<string>();
                    var names = modVks.Select(WtypeModifier).ToList();
                    foreach (var m in names) { wargs.Add("-M"); wargs.Add(m); }
                    wargs.Add("-k");
                    wargs.Add(KeyMaps.X11Keysym(vk) ?? throw Unknown(vk));
                    foreach (var m in Enumerable.Reverse(names)) { wargs.Add("-m"); wargs.Add(m); }
                    Tools.Check("wtype", wargs);
                    break;
                default:
                    var combo = string.Join("+", modVks.Append(vk).Select(k => KeyMaps.X11Keysym(k) ?? throw Unknown(k)));
                    Tools.Check("xdotool", new[] { "key", "--clearmodifiers", combo });
                    break;
            }
        }

        private static string WtypeModifier(ushort vk) => vk switch
        {
            KeyMaps.VkCtrl => "ctrl",
            KeyMaps.VkAlt => "alt",
            KeyMaps.VkShift => "shift",
            _ => "logo",
        };

        public void Dispose() => _queue.Dispose();
    }
}
