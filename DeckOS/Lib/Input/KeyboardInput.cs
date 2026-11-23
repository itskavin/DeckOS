using System;
using System.Collections.Generic;
using DeckOS.Platform;

namespace DeckOS.Lib.Input
{
    /// <summary>
    /// Teclado do PC. Quem envia de fato e o <see cref="Backend"/> do sistema: SendInput no
    /// Windows (Platform/Windows/WindowsKeyboard.cs), osascript no macOS, xdotool/ydotool/wtype
    /// no Linux. Estatico porque o <see cref="HeldKeys"/> e os provedores ja chamavam assim.
    /// </summary>
    public static class KeyboardInput
    {
        /// <summary>Quanto cada tecla fica apertada.</summary>
        public static int HoldMs { get; set; } = 20;

        /// <summary>Quem envia neste sistema (trocavel nos testes).</summary>
        public static IKeyboardInput Backend { get; set; } = PlatformServices.Keyboard;

        /// <summary>
        /// Aperta uma tecla e deixa apertada (quem solta e o <see cref="KeyUp(ushort)"/>).
        /// Quem precisa saber o que esta preso e o <see cref="HeldKeys"/>.
        /// </summary>
        public static void KeyDown(ushort vk) => Backend.KeyDown(vk);

        public static void KeyUp(ushort vk) => Backend.KeyUp(vk);

        public static void Send(IReadOnlyList<KeyStroke> strokes)
        {
            if (strokes.Count == 0) return;
            Backend.Send(strokes);
        }

        /// <summary>
        /// Nome de uma tecla so (UP, F5, SHIFT, {ENTER}, A, 0x41...) para virtual-key.
        /// Combinacoes (^C) nao: para isso ha o <see cref="KeySequence"/>.
        /// </summary>
        public static bool TryResolveKey(string keyName, out ushort vk)
        {
            vk = 0;
            if (string.IsNullOrWhiteSpace(keyName)) return false;

            var clean = keyName.Trim();
            if (clean.StartsWith("{", StringComparison.Ordinal) && clean.EndsWith("}", StringComparison.Ordinal) && clean.Length > 2)
                clean = clean[1..^1].Trim();

            if (KeySequence.TryGetNamedKey(clean, out vk))
                return true;

            if (clean.Length == 1)
            {
                char c = clean[0];
                if (c >= 'a' && c <= 'z') { vk = (ushort)(c - 'a' + 'A'); return true; }
                if (c >= 'A' && c <= 'Z') { vk = (ushort)c; return true; }
                if (c >= '0' && c <= '9') { vk = (ushort)c; return true; }

                // Pontuacao: a tecla que produz o caractere no layout em uso.
                if (Backend.TryResolveChar(c, out vk)) return true;
            }

            if (clean.StartsWith("0x", StringComparison.OrdinalIgnoreCase) &&
                ushort.TryParse(clean[2..], System.Globalization.NumberStyles.HexNumber, null, out vk))
                return vk is > 0 and <= 0xFE;

            return false;
        }
    }
}
