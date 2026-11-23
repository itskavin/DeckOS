using System.Collections.Generic;

namespace DeckOS.Platform
{
    /// <summary>
    /// Tabelas de teclas para o macOS e o Linux. Os botoes guardam virtual-keys do Windows; o
    /// xdotool/wtype quer o nome do keysym do X11, o ydotool o codigo do evdev (linux/input-event-codes.h)
    /// e o macOS o kVK_* (HIToolbox/Events.h). Sem um layout do sistema para consultar, a
    /// pontuacao segue o teclado americano.
    /// </summary>
    public static class KeyMaps
    {
        public const ushort VkShift = 0x10, VkCtrl = 0x11, VkAlt = 0x12, VkWin = 0x5B;

        // Teclas de midia/volume: no macOS nao sao teclas, sao eventos do sistema (NX_KEYTYPE_*).
        public static readonly Dictionary<ushort, int> MacMediaKeys = new()
        {
            [0xAF] = 0,  // NX_KEYTYPE_SOUND_UP
            [0xAE] = 1,  // NX_KEYTYPE_SOUND_DOWN
            [0xAD] = 7,  // NX_KEYTYPE_MUTE
            [0xB3] = 16, // NX_KEYTYPE_PLAY
            [0xB0] = 17, // NX_KEYTYPE_NEXT
            [0xB1] = 18, // NX_KEYTYPE_PREVIOUS
            [0xB2] = 16, // sem "parar" no Mac: play/pause
        };

        /// <summary>Caractere do teclado americano: virtual-key e se precisa de Shift.</summary>
        public static bool TryUsChar(char c, out ushort vk, out bool shift)
        {
            shift = false;
            vk = 0;
            if (c >= 'a' && c <= 'z') { vk = (ushort)(c - 'a' + 'A'); return true; }
            if (c >= 'A' && c <= 'Z') { vk = c; shift = true; return true; }
            if (c >= '0' && c <= '9') { vk = c; return true; }
            if (UsPunctuation.TryGetValue(c, out var p)) { (vk, shift) = p; return true; }
            return false;
        }

        private static readonly Dictionary<char, (ushort, bool)> UsPunctuation = new()
        {
            [' '] = (0x20, false), ['\n'] = (0x0D, false), ['\t'] = (0x09, false),
            [';'] = (0xBA, false), [':'] = (0xBA, true),
            ['='] = (0xBB, false), ['+'] = (0xBB, true),
            [','] = (0xBC, false), ['<'] = (0xBC, true),
            ['-'] = (0xBD, false), ['_'] = (0xBD, true),
            ['.'] = (0xBE, false), ['>'] = (0xBE, true),
            ['/'] = (0xBF, false), ['?'] = (0xBF, true),
            ['`'] = (0xC0, false), ['~'] = (0xC0, true),
            ['['] = (0xDB, false), ['{'] = (0xDB, true),
            ['\\'] = (0xDC, false), ['|'] = (0xDC, true),
            [']'] = (0xDD, false), ['}'] = (0xDD, true),
            ['\''] = (0xDE, false), ['"'] = (0xDE, true),
            ['!'] = (0x31, true), ['@'] = (0x32, true), ['#'] = (0x33, true), ['$'] = (0x34, true),
            ['%'] = (0x35, true), ['^'] = (0x36, true), ['&'] = (0x37, true), ['*'] = (0x38, true),
            ['('] = (0x39, true), [')'] = (0x30, true),
        };

        /// <summary>Nome do keysym do X11 (xdotool key, wtype -k) para uma virtual-key.</summary>
        public static string? X11Keysym(ushort vk)
        {
            if (vk >= 'A' && vk <= 'Z') return ((char)(vk - 'A' + 'a')).ToString();
            if (vk >= '0' && vk <= '9') return ((char)vk).ToString();
            if (vk >= 0x70 && vk <= 0x87) return "F" + (vk - 0x70 + 1);
            if (vk >= 0x60 && vk <= 0x69) return "KP_" + (vk - 0x60);
            return X11Names.TryGetValue(vk, out var name) ? name : null;
        }

        private static readonly Dictionary<ushort, string> X11Names = new()
        {
            [0x08] = "BackSpace", [0x09] = "Tab", [0x0D] = "Return", [0x13] = "Pause", [0x14] = "Caps_Lock",
            [0x1B] = "Escape", [0x20] = "space", [0x21] = "Prior", [0x22] = "Next", [0x23] = "End", [0x24] = "Home",
            [0x25] = "Left", [0x26] = "Up", [0x27] = "Right", [0x28] = "Down", [0x2C] = "Print", [0x2D] = "Insert",
            [0x2E] = "Delete", [0x2F] = "Help", [0x5B] = "Super_L", [0x5C] = "Super_R", [0x5D] = "Menu",
            [0x6A] = "KP_Multiply", [0x6B] = "KP_Add", [0x6C] = "KP_Separator", [0x6D] = "KP_Subtract",
            [0x6E] = "KP_Decimal", [0x6F] = "KP_Divide", [0x90] = "Num_Lock", [0x91] = "Scroll_Lock",
            [0x10] = "Shift_L", [0xA0] = "Shift_L", [0xA1] = "Shift_R",
            [0x11] = "Control_L", [0xA2] = "Control_L", [0xA3] = "Control_R",
            [0x12] = "Alt_L", [0xA4] = "Alt_L", [0xA5] = "Alt_R",
            [0xAD] = "XF86AudioMute", [0xAE] = "XF86AudioLowerVolume", [0xAF] = "XF86AudioRaiseVolume",
            [0xB0] = "XF86AudioNext", [0xB1] = "XF86AudioPrev", [0xB2] = "XF86AudioStop", [0xB3] = "XF86AudioPlay",
            [0xBA] = "semicolon", [0xBB] = "equal", [0xBC] = "comma", [0xBD] = "minus", [0xBE] = "period",
            [0xBF] = "slash", [0xC0] = "grave", [0xDB] = "bracketleft", [0xDC] = "backslash",
            [0xDD] = "bracketright", [0xDE] = "apostrophe",
        };

        /// <summary>Codigo do evdev (ydotool key CODIGO:1) para uma virtual-key.</summary>
        public static int? Evdev(ushort vk)
        {
            if (vk >= 0x70 && vk <= 0x79) return 59 + (vk - 0x70);           // F1-F10
            if (vk >= 0x7C && vk <= 0x87) return 183 + (vk - 0x7C);          // F13-F24
            return EvdevCodes.TryGetValue(vk, out var code) ? code : null;
        }

        private static readonly Dictionary<ushort, int> EvdevCodes = new()
        {
            [0x1B] = 1, ['1'] = 2, ['2'] = 3, ['3'] = 4, ['4'] = 5, ['5'] = 6, ['6'] = 7, ['7'] = 8, ['8'] = 9,
            ['9'] = 10, ['0'] = 11, [0xBD] = 12, [0xBB] = 13, [0x08] = 14, [0x09] = 15,
            ['Q'] = 16, ['W'] = 17, ['E'] = 18, ['R'] = 19, ['T'] = 20, ['Y'] = 21, ['U'] = 22, ['I'] = 23,
            ['O'] = 24, ['P'] = 25, [0xDB] = 26, [0xDD] = 27, [0x0D] = 28, [0x11] = 29, [0xA2] = 29,
            ['A'] = 30, ['S'] = 31, ['D'] = 32, ['F'] = 33, ['G'] = 34, ['H'] = 35, ['J'] = 36, ['K'] = 37,
            ['L'] = 38, [0xBA] = 39, [0xDE] = 40, [0xC0] = 41, [0x10] = 42, [0xA0] = 42, [0xDC] = 43,
            ['Z'] = 44, ['X'] = 45, ['C'] = 46, ['V'] = 47, ['B'] = 48, ['N'] = 49, ['M'] = 50,
            [0xBC] = 51, [0xBE] = 52, [0xBF] = 53, [0xA1] = 54, [0x6A] = 55, [0x12] = 56, [0xA4] = 56,
            [0x20] = 57, [0x14] = 58, [0x90] = 69, [0x91] = 70,
            [0x67] = 71, [0x68] = 72, [0x69] = 73, [0x6D] = 74, [0x64] = 75, [0x65] = 76, [0x66] = 77,
            [0x6B] = 78, [0x61] = 79, [0x62] = 80, [0x63] = 81, [0x60] = 82, [0x6E] = 83,
            [0x7A] = 87, [0x7B] = 88, [0xA3] = 97, [0x6F] = 98, [0x2C] = 99, [0xA5] = 100,
            [0x24] = 102, [0x26] = 103, [0x21] = 104, [0x25] = 105, [0x27] = 106, [0x23] = 107,
            [0x28] = 108, [0x22] = 109, [0x2D] = 110, [0x2E] = 111, [0xAD] = 113, [0xAE] = 114,
            [0xAF] = 115, [0x13] = 119, [0x5B] = 125, [0x5C] = 126, [0x5D] = 127,
            [0xB0] = 163, [0xB3] = 164, [0xB1] = 165, [0xB2] = 166,
        };

        /// <summary>kVK_* do macOS para uma virtual-key (Win vira Command).</summary>
        public static int? MacKeyCode(ushort vk) => MacCodes.TryGetValue(vk, out var code) ? code : null;

        private static readonly Dictionary<ushort, int> MacCodes = new()
        {
            ['A'] = 0, ['S'] = 1, ['D'] = 2, ['F'] = 3, ['H'] = 4, ['G'] = 5, ['Z'] = 6, ['X'] = 7, ['C'] = 8,
            ['V'] = 9, ['B'] = 11, ['Q'] = 12, ['W'] = 13, ['E'] = 14, ['R'] = 15, ['Y'] = 16, ['T'] = 17,
            ['1'] = 18, ['2'] = 19, ['3'] = 20, ['4'] = 21, ['6'] = 22, ['5'] = 23, [0xBB] = 24, ['9'] = 25,
            ['7'] = 26, [0xBD] = 27, ['8'] = 28, ['0'] = 29, [0xDD] = 30, ['O'] = 31, ['U'] = 32, [0xDB] = 33,
            ['I'] = 34, ['P'] = 35, [0x0D] = 36, ['L'] = 37, ['J'] = 38, [0xDE] = 39, ['K'] = 40, [0xBA] = 41,
            [0xDC] = 42, [0xBC] = 43, [0xBF] = 44, ['N'] = 45, ['M'] = 46, [0xBE] = 47, [0x09] = 48,
            [0x20] = 49, [0xC0] = 50, [0x08] = 51, [0x1B] = 53,
            [0x5B] = 55, [0x5C] = 55, [0x10] = 56, [0xA0] = 56, [0x14] = 57, [0x12] = 58, [0xA4] = 58,
            [0x11] = 59, [0xA2] = 59, [0xA1] = 60, [0xA5] = 61, [0xA3] = 62,
            [0x6E] = 65, [0x6A] = 67, [0x6B] = 69, [0x90] = 71, [0x6F] = 75, [0x6D] = 78,
            [0x60] = 82, [0x61] = 83, [0x62] = 84, [0x63] = 85, [0x64] = 86, [0x65] = 87, [0x66] = 88,
            [0x67] = 89, [0x68] = 91, [0x69] = 92,
            [0x74] = 96, [0x75] = 97, [0x76] = 98, [0x72] = 99, [0x77] = 100, [0x78] = 101, [0x7A] = 103,
            [0x7C] = 105, [0x7F] = 106, [0x7D] = 107, [0x79] = 109, [0x7B] = 111, [0x7E] = 113,
            [0x2F] = 114, [0x24] = 115, [0x21] = 116, [0x2E] = 117, [0x73] = 118, [0x23] = 119,
            [0x71] = 120, [0x22] = 121, [0x70] = 122, [0x25] = 123, [0x27] = 124, [0x28] = 125, [0x26] = 126,
            [0x80] = 64, [0x81] = 79, [0x82] = 80, [0x83] = 90, // F17-F20
        };

        /// <summary>Modificador (virtual-key) para a flag do CGEvent do macOS; 0 se nao for modificador.</summary>
        public static long MacModifierFlag(ushort vk) => vk switch
        {
            0x10 or 0xA0 or 0xA1 => 0x20000,   // kCGEventFlagMaskShift
            0x11 or 0xA2 or 0xA3 => 0x40000,   // kCGEventFlagMaskControl
            0x12 or 0xA4 or 0xA5 => 0x80000,   // kCGEventFlagMaskAlternate
            0x5B or 0x5C => 0x100000,          // kCGEventFlagMaskCommand
            _ => 0,
        };
    }
}
