using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

namespace DeckOS.Audio
{
    public readonly record struct ProcessSessionMetadata(bool Found, int Pid, string? Description, string? Icon);

    /// <summary>
    /// Resolve nome, janela e ícone de processos de sessões de áudio sem vazar handles e sem
    /// repetir extração GDI/PNG a cada poll ou em múltiplos dispositivos que compartilham o mesmo PID.
    ///
    /// Regras de corretude:
    /// - Nome do processo e <c>MainWindowTitle</c> são lidos ao vivo por passagem (nunca mantêm
    ///   sessões mortas nem congelam título de música/aba, e evitam risco de reuso de PID).
    /// - Dentro de uma mesma enumeração (<paramref name="passCache"/>), cada PID é consultado no
    ///   máximo uma vez mesmo quando o processo aparece em vários dispositivos de saída.
    /// - Apenas o ícone PNG em base64 (derivado do executável em disco) é cacheado entre chamadas,
    ///   com limite rígido (<see cref="MaxIconEntries"/>) e validação por timestamp de modificação
    ///   do arquivo (<c>LastWriteTimeUtc</c>). Falhas/executáveis sem ícone expiram em TTL curto.
    /// </summary>
    public sealed class ProcessMetadataCache
    {
        public const int DefaultMaxIconEntries = 128;
        public static readonly TimeSpan DefaultNegativeTtl = TimeSpan.FromSeconds(30);

        public static ProcessMetadataCache Shared { get; } = new();

        private readonly ConcurrentDictionary<string, CachedIconEntry> _iconCache =
            new(StringComparer.OrdinalIgnoreCase);

        private readonly int _maxIconEntries;
        private readonly TimeSpan _negativeTtl;
        private readonly Func<int, LiveProcessInfo?> _processReader;
        private readonly Func<string, long> _lastWriteTicksReader;
        private readonly Func<string, string?> _iconExtractor;
        private readonly Func<long> _utcNowTicks;

        private sealed class CachedIconEntry
        {
            public long FileWriteTicks { get; }
            public string? Base64Icon { get; }
            public long CachedAtUtcTicks { get; }
            public long LastAccessTicks;

            public CachedIconEntry(long fileWriteTicks, string? base64Icon, long nowTicks)
            {
                FileWriteTicks = fileWriteTicks;
                Base64Icon = base64Icon;
                CachedAtUtcTicks = nowTicks;
                LastAccessTicks = nowTicks;
            }
        }

        public readonly record struct LiveProcessInfo(string ProcessName, string? MainWindowTitle, string? ExecutablePath);

        public ProcessMetadataCache(
            int maxIconEntries = DefaultMaxIconEntries,
            TimeSpan? negativeTtl = null,
            Func<int, LiveProcessInfo?>? processReader = null,
            Func<string, long>? lastWriteTicksReader = null,
            Func<string, string?>? iconExtractor = null,
            Func<long>? utcNowTicks = null)
        {
            if (maxIconEntries <= 0)
                throw new ArgumentOutOfRangeException(nameof(maxIconEntries));

            _maxIconEntries = maxIconEntries;
            _negativeTtl = negativeTtl ?? DefaultNegativeTtl;
            _processReader = processReader ?? ReadLiveProcess;
            _lastWriteTicksReader = lastWriteTicksReader ?? ReadLastWriteUtcTicks;
            _iconExtractor = iconExtractor ?? ExtractAssociatedIconBase64;
            _utcNowTicks = utcNowTicks ?? (() => DateTime.UtcNow.Ticks);
        }

        public int CachedIconCount => _iconCache.Count;

        public void Clear() => _iconCache.Clear();

        public ProcessSessionMetadata Resolve(int pid, Dictionary<int, ProcessSessionMetadata>? passCache = null)
        {
            if (passCache != null && passCache.TryGetValue(pid, out var existing))
                return existing;

            var resolved = ResolveLive(pid);
            if (passCache != null)
                passCache[pid] = resolved;
            return resolved;
        }

        private ProcessSessionMetadata ResolveLive(int pid)
        {
            if (pid < 0)
                return new ProcessSessionMetadata(false, pid, null, null);

            LiveProcessInfo? info;
            try
            {
                info = _processReader(pid);
            }
            catch
            {
                return new ProcessSessionMetadata(false, pid, null, null);
            }

            if (info == null)
                return new ProcessSessionMetadata(false, pid, null, null);

            var procName = info.Value.ProcessName ?? string.Empty;
            var title = info.Value.MainWindowTitle;
            var description = (procName == "Spotify" ? procName + ": " : "") +
                              (!string.IsNullOrEmpty(title) ? title : procName);

            string? icon = null;
            if (!string.IsNullOrWhiteSpace(info.Value.ExecutablePath))
            {
                icon = GetOrExtractIcon(info.Value.ExecutablePath!);
            }

            return new ProcessSessionMetadata(true, pid, description, icon);
        }

        internal string? GetOrExtractIcon(string executablePath)
        {
            var normalizedPath = NormalizePath(executablePath);
            var nowTicks = _utcNowTicks();
            long fileWriteTicks;
            try
            {
                fileWriteTicks = _lastWriteTicksReader(normalizedPath);
            }
            catch
            {
                fileWriteTicks = 0;
            }

            if (_iconCache.TryGetValue(normalizedPath, out var cached) &&
                cached.FileWriteTicks == fileWriteTicks)
            {
                var isNegative = cached.Base64Icon == null;
                var expired = isNegative && (nowTicks - cached.CachedAtUtcTicks) >= _negativeTtl.Ticks;
                if (!expired)
                {
                    System.Threading.Interlocked.Exchange(ref cached.LastAccessTicks, nowTicks);
                    return cached.Base64Icon;
                }
            }

            string? extracted;
            try
            {
                extracted = _iconExtractor(normalizedPath);
            }
            catch
            {
                extracted = null;
            }

            var entry = new CachedIconEntry(fileWriteTicks, extracted, nowTicks);
            _iconCache[normalizedPath] = entry;
            EvictIfOverLimit();
            return extracted;
        }

        private void EvictIfOverLimit()
        {
            var overflow = _iconCache.Count - _maxIconEntries;
            if (overflow <= 0) return;

            // Snapshot and evict oldest-accessed entries without holding a global lock.
            var candidates = _iconCache.ToArray()
                .OrderBy(kvp => System.Threading.Interlocked.Read(ref kvp.Value.LastAccessTicks))
                .Take(overflow);

            foreach (var kvp in candidates)
            {
                _iconCache.TryRemove(kvp.Key, out _);
            }
        }

        private static string NormalizePath(string path)
        {
            try
            {
                return Path.GetFullPath(path);
            }
            catch
            {
                return path.Trim();
            }
        }

        private static LiveProcessInfo? ReadLiveProcess(int pid)
        {
            try
            {
                using var process = Process.GetProcessById(pid);
                var procName = process.ProcessName;
                string? title = null;
                try { title = process.MainWindowTitle; } catch { }

                // QueryFullProcessImageNameW evita EnumProcessModulesEx (Process.MainModule)
                // e funciona mesmo em processos elevados sem lançar Win32Exception.
                var exePath = TryQueryProcessImagePath(pid);
                return new LiveProcessInfo(procName, title, exePath);
            }
            catch
            {
                return null;
            }
        }

        private static string? TryQueryProcessImagePath(int pid)
        {
            if (pid <= 0) return null;

            var handle = OpenProcess(ProcessQueryLimitedInformation, false, pid);
            if (handle == IntPtr.Zero) return null;

            try
            {
                var buffer = new StringBuilder(1024);
                var size = buffer.Capacity;
                if (QueryFullProcessImageName(handle, 0, buffer, ref size) && size > 0)
                    return buffer.ToString(0, size);
                return null;
            }
            catch
            {
                return null;
            }
            finally
            {
                CloseHandle(handle);
            }
        }

        private static long ReadLastWriteUtcTicks(string path)
        {
            try
            {
                return File.Exists(path) ? File.GetLastWriteTimeUtc(path).Ticks : 0;
            }
            catch
            {
                return 0;
            }
        }

        private static string? ExtractAssociatedIconBase64(string moduleFile)
        {
            try
            {
                using var icon = Icon.ExtractAssociatedIcon(moduleFile);
                if (icon == null) return null;

                using var bmp = icon.ToBitmap();
                using var ms = new MemoryStream();
                bmp.Save(ms, ImageFormat.Png);
                return "data:image/png;base64," + Convert.ToBase64String(ms.ToArray());
            }
            catch
            {
                return null;
            }
        }

        private const uint ProcessQueryLimitedInformation = 0x1000;

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint dwDesiredAccess, [MarshalAs(UnmanagedType.Bool)] bool bInheritHandle, int dwProcessId);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool QueryFullProcessImageName(IntPtr hProcess, uint dwFlags, StringBuilder lpExeName, ref int lpdwSize);
    }
}
