using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using DeckOS.Lib;

namespace DeckOS.Platform.Windows
{
    /// <summary>
    /// Apps do menu Iniciar: os atalhos (.lnk) das duas pastas Programs (todos os usuarios e o
    /// atual) e os apps da Store, enumerados em processo via COM (FOLDERID_AppsFolder, sem
    /// subir powershell.exe; Get-StartApps fica so de reserva se o COM falhar). O icone sai
    /// do shell (o mesmo do menu Iniciar), em 256 px quando o app tem.
    /// </summary>
    public sealed class WindowsInstalledApps : InstalledAppsBase
    {
        // Atalhos que nao sao o app (desinstalar, leia-me, site).
        private static readonly string[] Noise =
        {
            "uninstall", "desinstalar", "remove", "readme", "leia-me", "license", "help", "ajuda",
            "website", "documentation", "release notes",
        };

        public WindowsInstalledApps() : this(prewarm: true) { }

        internal WindowsInstalledApps(bool prewarm)
        {
            if (prewarm) Prewarm();
        }

        protected override IEnumerable<InstalledApp> Scan()
        {
            var roots = new[]
            {
                Environment.GetFolderPath(Environment.SpecialFolder.CommonPrograms),
                Environment.GetFolderPath(Environment.SpecialFolder.Programs),
            };
            var apps = new List<InstalledApp>();
            foreach (var root in roots.Where(r => r.Length > 0 && Directory.Exists(r)))
            {
                IEnumerable<string> links;
                try { links = Directory.EnumerateFiles(root, "*.lnk", SearchOption.AllDirectories).ToList(); }
                catch (Exception) { continue; }
                foreach (var lnk in links)
                {
                    var name = Path.GetFileNameWithoutExtension(lnk);
                    if (Noise.Any(n => name.Contains(n, StringComparison.OrdinalIgnoreCase))) continue;
                    apps.Add(new InstalledApp(MakeId(lnk), name, lnk) { IconSource = lnk });
                }
            }
            apps.AddRange(StoreApps(apps.Select(a => a.Name).ToHashSet(StringComparer.OrdinalIgnoreCase)));
            return apps;
        }

        /// <summary>
        /// Apps da Store (AppID com "!"), via COM nativo em FOLDERID_AppsFolder (sem subprocesso
        /// PowerShell). Se o COM falhar, cai no Get-StartApps como reserva. Os que ja tem atalho
        /// ficam de fora.
        /// </summary>
        private static IEnumerable<InstalledApp> StoreApps(HashSet<string> known)
        {
            var sw = Stopwatch.StartNew();
            var entries = TryEnumerateAppsFolderCom();
            var source = "com";
            if (entries == null)
            {
                source = "powershell";
                entries = EnumerateAppsFolderPowerShell();
            }
            sw.Stop();
            Log.Debug("WindowsInstalledApps: StoreApps via {Source} ({Count} itens) em {ElapsedMs} ms",
                source, entries.Count, sw.ElapsedMilliseconds);

            foreach (var (name, appId) in entries)
            {
                if (name.Length == 0 || !appId.Contains('!') || known.Contains(name)) continue;
                var target = @"shell:AppsFolder\" + appId;
                yield return new InstalledApp(MakeId(target), name, "explorer.exe")
                {
                    Arguments = target,
                    IconSource = target,
                };
            }
        }

        internal static List<(string Name, string AppId)>? TryEnumerateAppsFolderCom()
        {
            try
            {
                var list = new List<(string Name, string AppId)>();
                var folderId = FOLDERID_AppsFolder;
                var iidItem = typeof(IShellItem).GUID;
                if (SHGetKnownFolderItem(ref folderId, 0, IntPtr.Zero, ref iidItem, out var folder) != 0 || folder == null)
                    return null;
                try
                {
                    var bhid = BHID_EnumItems;
                    var iidEnum = typeof(IEnumShellItems).GUID;
                    if (folder.BindToHandler(IntPtr.Zero, ref bhid, ref iidEnum, out var en) != 0 || en == null)
                        return null;
                    try
                    {
                        while (en.Next(1, out var item, out var fetched) == 0 && fetched == 1 && item != null)
                        {
                            try
                            {
                                if (item.GetDisplayName(SIGDN_NORMALDISPLAY, out var name) == 0 &&
                                    item.GetDisplayName(SIGDN_PARENTRELATIVEPARSING, out var appId) == 0 &&
                                    !string.IsNullOrEmpty(name) &&
                                    !string.IsNullOrEmpty(appId) &&
                                    appId.Contains('!'))
                                {
                                    list.Add((name, appId));
                                }
                            }
                            finally
                            {
                                Marshal.ReleaseComObject(item);
                            }
                        }
                    }
                    finally
                    {
                        Marshal.ReleaseComObject(en);
                    }
                }
                finally
                {
                    Marshal.ReleaseComObject(folder);
                }
                return list;
            }
            catch (Exception ex)
            {
                Log.Debug(ex, "WindowsInstalledApps: enumeracao COM falhou; usando fallback PowerShell");
                return null;
            }
        }

        private static List<(string Name, string AppId)> EnumerateAppsFolderPowerShell()
        {
            string json;
            try
            {
                var r = Tools.Run("powershell", new[]
                {
                    "-NoProfile", "-NonInteractive", "-Command",
                    "[Console]::OutputEncoding=[Text.Encoding]::UTF8; Get-StartApps | Select-Object Name,AppID | ConvertTo-Json -Compress",
                }, 15000);
                if (!r.Ok) return new List<(string, string)>();
                json = r.Output.Trim();
            }
            catch (Exception)
            {
                return new List<(string, string)>();
            }
            if (json.Length == 0) return new List<(string, string)>();
            if (json.StartsWith('{')) json = "[" + json + "]";

            try
            {
                using var doc = JsonDocument.Parse(json);
                return doc.RootElement.EnumerateArray()
                    .Select(e => (e.GetProperty("Name").GetString() ?? "", e.GetProperty("AppID").GetString() ?? ""))
                    .ToList();
            }
            catch (Exception)
            {
                return new List<(string, string)>();
            }
        }

        protected override Task<(byte[] Data, string ContentType)?> LoadIconAsync(InstalledApp app) =>
            Task.Run<(byte[], string)?>(() =>
            {
                var png = ShellIcon(app.IconSource ?? app.Path);
                return png == null ? null : (png, "image/png");
            });

        /// <summary>
        /// Icone pelo indice na lista de imagens do sistema (vale para arquivo, atalho sem a
        /// seta e item shell:AppsFolder). Tenta a lista de 256 px; se o app so tem icone pequeno,
        /// o shell desenha 32 px no canto da de 256 e a de 48 px fica melhor.
        /// </summary>
        public static byte[]? ShellIcon(string parsingName)
        {
            if (SHParseDisplayName(parsingName, IntPtr.Zero, out var pidl, 0, out _) != 0 || pidl == IntPtr.Zero) return null;
            try
            {
                var info = new SHFILEINFO();
                if (SHGetFileInfo(pidl, 0, ref info, (uint)Marshal.SizeOf<SHFILEINFO>(), SHGFI_PIDL | SHGFI_SYSICONINDEX) == IntPtr.Zero)
                    return null;
                using var jumbo = FromImageList(SHIL_JUMBO, info.iIcon);
                if (jumbo != null && !DrawnInCorner(jumbo)) return Png(jumbo);
                using var large = FromImageList(SHIL_EXTRALARGE, info.iIcon);
                return large != null ? Png(large) : jumbo != null ? Png(jumbo) : null;
            }
            finally
            {
                Marshal.FreeCoTaskMem(pidl);
            }
        }

        private static Bitmap? FromImageList(int list, int index)
        {
            var iid = typeof(IImageList).GUID;
            if (SHGetImageList(list, ref iid, out var images) != 0 || images == null) return null;
            try
            {
                if (images.GetIcon(index, ILD_TRANSPARENT, out var hicon) != 0 || hicon == IntPtr.Zero) return null;
                try
                {
                    using var icon = Icon.FromHandle(hicon);
                    return icon.ToBitmap();
                }
                finally
                {
                    DestroyIcon(hicon);
                }
            }
            finally
            {
                Marshal.ReleaseComObject(images);
            }
        }

        /// <summary>
        /// O desenho ocupa so o canto de cima a esquerda (icone pequeno na lista de 256)?
        /// Usa LockBits em vez de GetPixel: retorna false assim que acha um pixel opaco fora
        /// do quadrante superior esquerdo.
        /// </summary>
        internal static bool DrawnInCorner(Bitmap bmp)
        {
            var w = bmp.Width;
            var h = bmp.Height;
            if (w <= 0 || h <= 0) return true;
            var cutX = w / 4;
            var cutY = h / 4;
            var rect = new Rectangle(0, 0, w, h);
            var data = bmp.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                var stride = Math.Abs(data.Stride);
                var row = new byte[stride];
                for (var y = 0; y < h; y += 2)
                {
                    Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), row, 0, stride);
                    var startX = y < cutY ? ((cutX + 1) & ~1) : 0;
                    for (var x = startX; x < w; x += 2)
                    {
                        if (row[x * 4 + 3] > 16) return false;
                    }
                }
                return true;
            }
            finally
            {
                bmp.UnlockBits(data);
            }
        }

        private static byte[] Png(Bitmap bmp)
        {
            using var ms = new MemoryStream();
            bmp.Save(ms, ImageFormat.Png);
            return ms.ToArray();
        }

        // ---- Win32 / shell ----

        private static readonly Guid FOLDERID_AppsFolder = new("1e87508d-89c2-42f0-8a7e-645a0f50ca58");
        private static readonly Guid BHID_EnumItems = new("94f60519-2850-4924-aa5a-d15e84868039");
        private const uint SIGDN_NORMALDISPLAY = 0x00000000;
        private const uint SIGDN_PARENTRELATIVEPARSING = 0x80018001;

        private const uint SHGFI_SYSICONINDEX = 0x4000, SHGFI_PIDL = 0x8;
        private const int SHIL_EXTRALARGE = 2, SHIL_JUMBO = 4;
        private const int ILD_TRANSPARENT = 1;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct SHFILEINFO
        {
            public IntPtr hIcon;
            public int iIcon;
            public uint dwAttributes;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
        }

        [DllImport("shell32.dll")]
        private static extern int SHGetKnownFolderItem(
            [In] ref Guid rfid,
            uint dwFlags,
            IntPtr hToken,
            [In] ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IShellItem? ppv);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SHParseDisplayName(string pszName, IntPtr pbc, out IntPtr ppidl, uint sfgaoIn, out uint psfgaoOut);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr SHGetFileInfo(IntPtr pidl, uint attributes, ref SHFILEINFO info, uint size, uint flags);

        [DllImport("shell32.dll", EntryPoint = "#727")]
        private static extern int SHGetImageList(int iImageList, ref Guid riid, out IImageList? ppv);

        [DllImport("user32.dll")]
        private static extern bool DestroyIcon(IntPtr hIcon);

        [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IShellItem
        {
            [PreserveSig] int BindToHandler(IntPtr pbc, [In] ref Guid bhid, [In] ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out IEnumShellItems? ppv);
            [PreserveSig] int GetParent([MarshalAs(UnmanagedType.Interface)] out IShellItem? ppsi);
            [PreserveSig] int GetDisplayName(uint sigdnName, [MarshalAs(UnmanagedType.LPWStr)] out string? ppszName);
            [PreserveSig] int GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
            [PreserveSig] int Compare(IShellItem psi, uint hint, out int piOrder);
        }

        [ComImport, Guid("70629033-e363-4a28-a567-0db78006e6d7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IEnumShellItems
        {
            [PreserveSig] int Next(uint celt, [MarshalAs(UnmanagedType.Interface)] out IShellItem? rgelt, out uint pceltFetched);
            [PreserveSig] int Skip(uint celt);
            [PreserveSig] int Reset();
            [PreserveSig] int Clone([MarshalAs(UnmanagedType.Interface)] out IEnumShellItems? ppenum);
        }

        // So o GetIcon e usado; os anteriores ficam declarados para a vtable bater.
        [ComImport, Guid("46EB5926-582E-4017-9FDF-E8998DAA0950"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        private interface IImageList
        {
            [PreserveSig] int Add(IntPtr hbmImage, IntPtr hbmMask, ref int pi);
            [PreserveSig] int ReplaceIcon(int i, IntPtr hicon, ref int pi);
            [PreserveSig] int SetOverlayImage(int i, int iOverlay);
            [PreserveSig] int Replace(int i, IntPtr hbmImage, IntPtr hbmMask);
            [PreserveSig] int AddMasked(IntPtr hbmImage, int crMask, ref int pi);
            [PreserveSig] int Draw(IntPtr pimldp);
            [PreserveSig] int Remove(int i);
            [PreserveSig] int GetIcon(int i, int flags, out IntPtr picon);
        }
    }
}
