using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using DeckOS.Lib;
using DeckOS.Lib.Input;

namespace DeckOS.Services
{
    public class AppActivator : IAppActivator
    {
        private const string AppsFolderPrefix = @"shell:AppsFolder\";
        private const int MaxShortcutCacheEntries = 128;

        private readonly object _lnkCacheLock = new();
        private readonly Dictionary<string, LinkedListNode<CachedShortcut>> _lnkCache = new(StringComparer.OrdinalIgnoreCase);
        private readonly LinkedList<CachedShortcut> _lnkLru = new();

        internal sealed record ResolvedShortcut(
            string TargetPath,
            string? Arguments,
            string? WorkingDirectory,
            ProcessWindowStyle WindowStyle,
            bool RequiresShellExecute);

        private sealed record CachedShortcut(string Key, DateTime LastWriteUtc, ResolvedShortcut? Resolved);

        [DllImport("USER32.DLL")]
        private static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("USER32.DLL", CharSet = CharSet.Unicode)]
        private static extern IntPtr FindWindow(string? lpClassName, string? lpWindowName);

        public void ActivateWindow(string? name)
        {
            if (string.IsNullOrEmpty(name)) return;
            var h = FindWindow(null, name);
            if (h != IntPtr.Zero)
                SetForegroundWindow(h);
        }

        /// <summary>
        /// Sintaxe do SendKeys (^ Ctrl, + Shift, % Alt, {ENTER}...) mais # = Win, enviada
        /// com SendInput. Sintaxe invalida lanca FormatException antes de apertar qualquer tecla.
        /// </summary>
        public void SendKeys(string keys)
        {
            if (string.IsNullOrEmpty(keys)) return;
            KeyboardInput.Send(KeySequence.Parse(keys));
        }

        public void LaunchApp(string path, string? arguments = null)
        {
            if (string.IsNullOrWhiteSpace(path)) return;
            var sw = Stopwatch.StartNew();

            if (OperatingSystem.IsWindows())
            {
                // 1) Store / MSIX / UWP (explorer.exe + shell:AppsFolder\<AUMID>):
                // ativa direto via IApplicationActivationManager sem subir explorer.exe filho.
                if (TryParseAppsFolderTarget(path, arguments, out var aumid, out var extraArgs) &&
                    TryActivateStoreApp(aumid, extraArgs))
                {
                    sw.Stop();
                    Log.Debug("AppActivator: launch via store-com em {ElapsedMs} ms", sw.ElapsedMilliseconds);
                    return;
                }

                // 2) Atalho .lnk apontando para .exe comum (sem RunAs/MSI):
                // pula o overhead de ShellExecuteEx/DDE usando CreateProcess direto, com
                // fallback automatico para ShellExecute em caso de UAC ou erro.
                if (path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase) &&
                    TryLaunchShortcutDirect(path, arguments))
                {
                    sw.Stop();
                    Log.Debug("AppActivator: launch via lnk-direct em {ElapsedMs} ms", sw.ElapsedMilliseconds);
                    return;
                }
            }

            StartShellExecute(path, arguments);
            sw.Stop();
            Log.Debug("AppActivator: launch via shell-execute em {ElapsedMs} ms", sw.ElapsedMilliseconds);
        }

        /// <summary>
        /// Extrai o AppUserModelId e argumentos extras de um alvo Store:
        ///   ("explorer.exe", "shell:AppsFolder\Pkg!App --flag") -> ("Pkg!App", "--flag")
        ///   ("shell:AppsFolder\Pkg!App", "--flag")               -> ("Pkg!App", "--flag")
        /// So casa AUMIDs da Store (contem '!' e sem aspas malformadas).
        /// </summary>
        internal static bool TryParseAppsFolderTarget(string path, string? arguments, out string aumid, out string? extraArgs)
        {
            aumid = "";
            extraArgs = null;
            var trimmedPath = path.Trim();
            var trimmedArgs = arguments?.Trim() ?? "";

            string? spec = null;
            string? trailing = null;

            if (trimmedPath.StartsWith(AppsFolderPrefix, StringComparison.OrdinalIgnoreCase))
            {
                spec = trimmedPath[AppsFolderPrefix.Length..].Trim();
                trailing = trimmedArgs.Length > 0 ? trimmedArgs : null;
            }
            else if (IsExplorerExecutable(trimmedPath) &&
                     trimmedArgs.StartsWith(AppsFolderPrefix, StringComparison.OrdinalIgnoreCase))
            {
                var rest = trimmedArgs[AppsFolderPrefix.Length..].TrimStart();
                var split = SplitFirstToken(rest);
                spec = split.First;
                trailing = split.Trailing;
            }

            if (string.IsNullOrWhiteSpace(spec) || !spec.Contains('!')) return false;
            aumid = spec;
            extraArgs = string.IsNullOrWhiteSpace(trailing) ? null : trailing;
            return true;
        }

        private static bool IsExplorerExecutable(string path)
        {
            var fileName = Path.GetFileName(path.Trim('"'));
            return fileName.Equals("explorer.exe", StringComparison.OrdinalIgnoreCase) ||
                   fileName.Equals("explorer", StringComparison.OrdinalIgnoreCase);
        }

        private static (string First, string? Trailing) SplitFirstToken(string text)
        {
            if (text.Length == 0) return ("", null);
            if (text[0] == '"')
            {
                var end = text.IndexOf('"', 1);
                if (end < 0) return (text[1..], null);
                var rest = text[(end + 1)..].Trim();
                return (text[1..end], rest.Length > 0 ? rest : null);
            }
            for (var i = 0; i < text.Length; i++)
            {
                if (char.IsWhiteSpace(text[i]))
                {
                    var rest = text[(i + 1)..].Trim();
                    return (text[..i], rest.Length > 0 ? rest : null);
                }
            }
            return (text, null);
        }

        private static bool TryActivateStoreApp(string aumid, string? extraArgs)
        {
            try
            {
                var clsid = CLSID_ApplicationActivationManager;
                var iid = typeof(IApplicationActivationManager).GUID;
                if (CoCreateInstance(ref clsid, IntPtr.Zero, CLSCTX_LOCAL_SERVER, ref iid, out var obj) != 0 || obj == null)
                    return false;
                try
                {
                    var manager = (IApplicationActivationManager)obj;
                    var hr = manager.ActivateApplication(aumid, extraArgs, 0 /* AO_NONE */, out _);
                    return hr == 0;
                }
                finally
                {
                    Marshal.ReleaseComObject(obj);
                }
            }
            catch (Exception ex)
            {
                Log.Debug(ex, "AppActivator: IApplicationActivationManager falhou; usando ShellExecute");
                return false;
            }
        }

        private bool TryLaunchShortcutDirect(string lnkPath, string? extraArguments)
        {
            var resolved = ResolveShortcutCached(lnkPath);
            if (resolved == null || resolved.RequiresShellExecute) return false;
            if (!File.Exists(resolved.TargetPath)) return false;

            var combinedArgs = CombineArguments(resolved.Arguments, extraArguments);
            var psi = new ProcessStartInfo
            {
                FileName = resolved.TargetPath,
                Arguments = combinedArgs,
                UseShellExecute = false,
                WindowStyle = resolved.WindowStyle,
            };
            if (!string.IsNullOrWhiteSpace(resolved.WorkingDirectory) && Directory.Exists(resolved.WorkingDirectory))
            {
                psi.WorkingDirectory = resolved.WorkingDirectory;
            }
            else if (Path.GetDirectoryName(resolved.TargetPath) is { Length: > 0 } dir && Directory.Exists(dir))
            {
                psi.WorkingDirectory = dir;
            }

            try
            {
                using var proc = Process.Start(psi);
                return proc != null;
            }
            catch (Exception ex)
            {
                // Ex.: ERROR_ELEVATION_REQUIRED (740) em manifestos com requireAdministrator -> ShellExecute pede UAC.
                Log.Debug(ex, "AppActivator: abertura direta do atalho falhou; usando ShellExecute");
                return false;
            }
        }

        internal static string CombineArguments(string? first, string? second)
        {
            var a = first?.Trim() ?? "";
            var b = second?.Trim() ?? "";
            if (a.Length == 0) return b;
            if (b.Length == 0) return a;
            if (string.Equals(a, b, StringComparison.Ordinal)) return a;
            return a + " " + b;
        }

        internal ResolvedShortcut? ResolveShortcutCached(string lnkPath)
        {
            if (!File.Exists(lnkPath)) return null;
            DateTime writeTime;
            try { writeTime = File.GetLastWriteTimeUtc(lnkPath); }
            catch { return null; }

            lock (_lnkCacheLock)
            {
                if (_lnkCache.TryGetValue(lnkPath, out var node))
                {
                    if (node.Value.LastWriteUtc == writeTime)
                    {
                        _lnkLru.Remove(node);
                        _lnkLru.AddLast(node);
                        return node.Value.Resolved;
                    }
                    _lnkLru.Remove(node);
                    _lnkCache.Remove(lnkPath);
                }
            }

            var resolved = ResolveShortcutCom(lnkPath);

            lock (_lnkCacheLock)
            {
                if (_lnkCache.TryGetValue(lnkPath, out var existing))
                    _lnkLru.Remove(existing);
                var node = _lnkLru.AddLast(new CachedShortcut(lnkPath, writeTime, resolved));
                _lnkCache[lnkPath] = node;
                while (_lnkCache.Count > MaxShortcutCacheEntries)
                {
                    var oldest = _lnkLru.First;
                    if (oldest == null) break;
                    _lnkLru.RemoveFirst();
                    _lnkCache.Remove(oldest.Value.Key);
                }
            }
            return resolved;
        }

        private static ResolvedShortcut? ResolveShortcutCom(string lnkPath)
        {
            object? obj = null;
            try
            {
                var clsid = CLSID_ShellLink;
                var iid = typeof(IShellLinkW).GUID;
                if (CoCreateInstance(ref clsid, IntPtr.Zero, CLSCTX_INPROC_SERVER, ref iid, out obj) != 0 || obj == null)
                    return null;

                var link = (IShellLinkW)obj;
                var persist = (IPersistFile)obj;
                if (persist.Load(lnkPath, STGM_READ) != 0) return null;

                var requiresShell = false;
                if (obj is IShellLinkDataList dataList && dataList.GetFlags(out var flags) == 0)
                {
                    if ((flags & (SLDF_RUNAS_USER | SLDF_HAS_DARWINID)) != 0)
                        requiresShell = true;
                }

                var targetBuf = new StringBuilder(1024);
                if (link.GetPath(targetBuf, targetBuf.Capacity, IntPtr.Zero, SLGP_RAWPATH) != 0)
                    return null;
                var target = Environment.ExpandEnvironmentVariables(targetBuf.ToString().Trim());
                if (target.Length == 0 || !target.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
                    requiresShell = true;

                var argsBuf = new StringBuilder(2048);
                var args = link.GetArguments(argsBuf, argsBuf.Capacity) == 0 ? argsBuf.ToString().Trim() : "";

                var workBuf = new StringBuilder(1024);
                var workDir = link.GetWorkingDirectory(workBuf, workBuf.Capacity) == 0
                    ? Environment.ExpandEnvironmentVariables(workBuf.ToString().Trim())
                    : "";

                var style = ProcessWindowStyle.Normal;
                if (link.GetShowCmd(out var showCmd) == 0)
                {
                    style = showCmd switch
                    {
                        SW_SHOWMAXIMIZED => ProcessWindowStyle.Maximized,
                        SW_SHOWMINNOACTIVE or SW_SHOWMINIMIZED => ProcessWindowStyle.Minimized,
                        _ => ProcessWindowStyle.Normal,
                    };
                }

                return new ResolvedShortcut(
                    target,
                    args.Length > 0 ? args : null,
                    workDir.Length > 0 ? workDir : null,
                    style,
                    requiresShell);
            }
            catch (Exception ex)
            {
                Log.Debug(ex, "AppActivator: leitura COM do atalho falhou");
                return null;
            }
            finally
            {
                if (obj != null) Marshal.ReleaseComObject(obj);
            }
        }

        private static void StartShellExecute(string path, string? arguments)
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = path,
                Arguments = arguments ?? "",
                UseShellExecute = true // Allows opening URLs, documents, elevated shortcuts, and shell items
            };
            Process.Start(startInfo)?.Dispose();
        }

        // ---- Windows COM interop ----

        private static readonly Guid CLSID_ApplicationActivationManager = new("45BA127D-10A8-46EA-8AB7-56EA9078943C");
        private static readonly Guid CLSID_ShellLink = new("00021401-0000-0000-C000-000000000046");
        private const uint CLSCTX_INPROC_SERVER = 0x1;
        private const uint CLSCTX_LOCAL_SERVER = 0x4;
        private const int STGM_READ = 0;
        private const uint SLGP_RAWPATH = 0x4;
        private const uint SLDF_HAS_DARWINID = 0x00001000;
        private const uint SLDF_RUNAS_USER = 0x00002000;
        private const int SW_SHOWMINIMIZED = 2;
        private const int SW_SHOWMAXIMIZED = 3;
        private const int SW_SHOWMINNOACTIVE = 7;

        [DllImport("ole32.dll")]
        private static extern int CoCreateInstance(
            [In] ref Guid rclsid,
            IntPtr pUnkOuter,
            uint dwClsContext,
            [In] ref Guid riid,
            [MarshalAs(UnmanagedType.IUnknown)] out object? ppv);

        [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IApplicationActivationManager
        {
            [PreserveSig]
            int ActivateApplication(
                [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
                [MarshalAs(UnmanagedType.LPWStr)] string? arguments,
                uint options,
                out uint processId);
        }

        [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellLinkW
        {
            [PreserveSig] int GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cchMaxPath, IntPtr pfd, uint fFlags);
            [PreserveSig] int GetIDList(out IntPtr ppidl);
            [PreserveSig] int SetIDList(IntPtr pidl);
            [PreserveSig] int GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cchMaxName);
            [PreserveSig] int SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
            [PreserveSig] int GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cchMaxPath);
            [PreserveSig] int SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
            [PreserveSig] int GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cchMaxPath);
            [PreserveSig] int SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
            [PreserveSig] int GetHotkey(out short pwHotkey);
            [PreserveSig] int SetHotkey(short wHotkey);
            [PreserveSig] int GetShowCmd(out int piShowCmd);
            [PreserveSig] int SetShowCmd(int iShowCmd);
            [PreserveSig] int GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cchIconPath, out int piIcon);
            [PreserveSig] int SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
            [PreserveSig] int SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
            [PreserveSig] int Resolve(IntPtr hwnd, uint fFlags);
            [PreserveSig] int SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
        }

        [ComImport, Guid("0000010B-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IPersistFile
        {
            [PreserveSig] int GetClassID(out Guid pClassID);
            [PreserveSig] int IsDirty();
            [PreserveSig] int Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, int dwMode);
            [PreserveSig] int Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
            [PreserveSig] int SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
            [PreserveSig] int GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
        }

        [ComImport, Guid("45E2B4AE-B1C3-11D0-B92F-00A0C90312E1"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellLinkDataList
        {
            [PreserveSig] int AddDataBlock(IntPtr pDataBlock);
            [PreserveSig] int CopyDataBlock(uint dwSig, out IntPtr ppDataBlock);
            [PreserveSig] int RemoveDataBlock(uint dwSig);
            [PreserveSig] int GetFlags(out uint pdwFlags);
            [PreserveSig] int SetFlags(uint dwFlags);
        }
    }
}
