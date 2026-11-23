using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using DeckOS.Lib;

namespace DeckOS.Services;

// Kept separate from process creation: single-instance launchers can exit while an older
// process owns the window. Never use the launcher PID or a display title as app identity.
internal static class WindowsAppForeground
{
    internal sealed record Target(string? ImagePath, string? AppUserModelId);

    internal interface IWindows
    {
        IntPtr Find(Target target);
        bool Activate(IntPtr window);
    }

    internal static Target? ResolveTarget(string path, string? arguments, AppActivator.ResolvedShortcut? shortcut)
    {
        if (AppActivator.TryParseAppsFolderTarget(path, arguments, out var aumid, out _))
            return new(null, aumid);
        if (shortcut != null)
        {
            if (shortcut.AppUserModelId is { Length: > 0 } id && id.Contains('!'))
                return new(null, id);
            if (AppActivator.TryParseAppsFolderTarget(shortcut.TargetPath, shortcut.Arguments, out aumid, out _))
                return new(null, aumid);
            path = shortcut.TargetPath;
        }

        path = Environment.ExpandEnvironmentVariables(path.Trim().Trim('"'));
        if (!path.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) return null;
        if (!Path.IsPathFullyQualified(path) && OperatingSystem.IsWindows())
        {
            var buffer = new StringBuilder(32768);
            var length = SearchPath(null, path, null, buffer.Capacity, buffer, IntPtr.Zero);
            if (length == 0 || length >= buffer.Capacity) return null;
            path = buffer.ToString();
        }
        return Path.IsPathFullyQualified(path) ? new(Path.GetFullPath(path), null) : null;
    }

    internal static bool Matches(Target target, string? imagePath, string? aumid) =>
        target.AppUserModelId is { Length: > 0 } id
            ? string.Equals(id, aumid, StringComparison.OrdinalIgnoreCase)
            : target.ImagePath is { Length: > 0 } image &&
              string.Equals(image, imagePath, StringComparison.OrdinalIgnoreCase);

    internal static void Restore(Target? target)
    {
        if (target == null || !OperatingSystem.IsWindows()) return;
        var timer = Stopwatch.StartNew();
        try
        {
            var activated = Restore(target, new NativeWindows(), Thread.Sleep);
            Log.Debug("AppActivator: window foreground {Activated} in {ElapsedMs} ms", activated, timer.ElapsedMilliseconds);
        }
        catch (Exception ex)
        {
            // Launch has already succeeded; inaccessible windows must not undo it.
            Log.Debug(ex, "AppActivator: window activation unavailable");
        }
    }

    internal static bool Restore(Target target, IWindows windows, Action<int> delay, Func<long>? elapsedMilliseconds = null)
    {
        // Immediate warm-app attempt; four-second deadline for cold Store/Electron windows.
        // No watcher survives the launch and a confirmed foreground window stops retries.
        var timer = Stopwatch.StartNew();
        elapsedMilliseconds ??= () => timer.ElapsedMilliseconds;
        for (var attempt = 0; attempt <= 80; attempt++)
        {
            if (attempt > 0 && elapsedMilliseconds() >= 4000) return false;
            var window = windows.Find(target);
            if (window != IntPtr.Zero && windows.Activate(window)) return true;
            var remaining = 4000 - elapsedMilliseconds();
            if (remaining <= 0) return false;
            if (attempt < 80) delay((int)Math.Min(50, remaining));
        }
        return false;
    }

    private sealed class NativeWindows : IWindows
    {
        public IntPtr Find(Target target)
        {
            var identities = new Dictionary<uint, (string? Image, string? Aumid)>();
            bool ProcessMatches(IntPtr window)
            {
                GetWindowThreadProcessId(window, out var pid);
                if (!identities.TryGetValue(pid, out var identity))
                {
                    identity = ReadProcessIdentity(pid, target.AppUserModelId != null);
                    identities[pid] = identity;
                }
                return Matches(target, identity.Image, identity.Aumid);
            }

            var found = IntPtr.Zero;
            var hidden = IntPtr.Zero;
            EnumWindows((window, _) =>
            {
                var style = GetWindowLongPtr(window, -20).ToInt64();
                if ((style & (0x80L /* TOOLWINDOW */ | 0x08000000L /* NOACTIVATE */)) != 0) return true;
                if (DwmGetWindowAttribute(window, 14 /* CLOAKED */, out var cloaked, sizeof(int)) == 0 && cloaked != 0)
                    return true;

                var visible = IsWindowVisible(window);
                if (!visible && (GetWindowTextLength(window) == 0 ||
                    (GetWindowLongPtr(window, -16).ToInt64() & 0x00C00000L /* CAPTION */) == 0)) return true;

                var match = ProcessMatches(window);
                if (!match && target.AppUserModelId != null)
                {
                    match = string.Equals(target.AppUserModelId, ReadWindowAppId(window), StringComparison.OrdinalIgnoreCase);
                    // Older UWP windows belong to ApplicationFrameHost. Their content child
                    // belongs to the app; never match the shared host's image or PID.
                    var className = new StringBuilder(256);
                    GetClassName(window, className, className.Capacity);
                    if (!match && className.ToString() == "ApplicationFrameWindow")
                    {
                        EnumChildWindows(window, (child, _) =>
                        {
                            match = ProcessMatches(child);
                            return !match;
                        }, IntPtr.Zero);
                    }
                }
                if (!match) return true;
                if (!visible) { if (hidden == IntPtr.Zero) hidden = window; return true; }
                found = window;
                return false;
            }, IntPtr.Zero);
            return found != IntPtr.Zero ? found : hidden;
        }

        public bool Activate(IntPtr window)
        {
            if (!IsWindow(window)) return false;
            if (IsIconic(window))
            {
                Log.Debug("AppActivator: restoring minimized HWND {Window}", window);
                ShowWindowAsync(window, 9 /* RESTORE */);
            }
            else if (!IsWindowVisible(window)) ShowWindowAsync(window, 5 /* SHOW */);

            SetForegroundWindow(window);
            if (IsForeground(window)) return true;

            // A remote deck tap does not make this worker the foreground input thread.
            // Briefly join the normal foreground queue, then always detach. Windows still
            // enforces desktop/integrity boundaries. No synthetic keys or lock changes.
            var currentThread = GetCurrentThreadId();
            var foregroundThread = GetWindowThreadProcessId(GetForegroundWindow(), out _);
            PeekMessage(out _, IntPtr.Zero, 0, 0, 0); // Ensure this worker has an input queue.
            var attached = foregroundThread != 0 && foregroundThread != currentThread &&
                AttachThreadInput(currentThread, foregroundThread, true);
            try
            {
                if (attached) SetForegroundWindow(window);
                return IsForeground(window);
            }
            finally
            {
                if (attached) AttachThreadInput(currentThread, foregroundThread, false);
            }
        }

        private static bool IsForeground(IntPtr window)
        {
            if (GetForegroundWindow() != window || !IsWindowVisible(window) || IsIconic(window)) return false;
            GetWindowThreadProcessId(window, out var pid);
            Log.Debug("AppActivator: verified visible foreground HWND {Window} PID {Pid} (not minimized)", window, pid);
            return true;
        }
    }

    private static (string? Image, string? Aumid) ReadProcessIdentity(uint pid, bool readAumid)
    {
        var process = OpenProcess(0x1000 /* QUERY_LIMITED_INFORMATION */, false, pid);
        if (process == IntPtr.Zero) return (null, null);
        try
        {
            var buffer = new StringBuilder(32768);
            var size = buffer.Capacity;
            var image = QueryFullProcessImageName(process, 0, buffer, ref size) ? buffer.ToString() : null;
            string? aumid = null;
            if (readAumid)
            {
                uint length = 512;
                var appId = new StringBuilder((int)length);
                if (GetApplicationUserModelId(process, ref length, appId) == 0) aumid = appId.ToString();
            }
            return (image, aumid);
        }
        finally { CloseHandle(process); }
    }

    private static string? ReadWindowAppId(IntPtr window)
    {
        var iid = typeof(IPropertyStore).GUID;
        if (SHGetPropertyStoreForWindow(window, ref iid, out var store) != 0 || store == null) return null;
        try { return ReadAppUserModelId(store); }
        finally { Marshal.ReleaseComObject(store); }
    }

    internal static string? ReadAppUserModelId(object shellObject)
    {
        if (shellObject is not IPropertyStore store) return null;
        var key = new PropertyKey { Format = new("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 5 };
        if (store.GetValue(ref key, out var value) != 0) return null;
        try { return value.Type == 31 ? Marshal.PtrToStringUni(value.Pointer) : null; }
        finally { PropVariantClear(ref value); }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey { public Guid Format; public uint Id; }
    [StructLayout(LayoutKind.Sequential)]
    private struct PropVariant { public ushort Type, Reserved1, Reserved2, Reserved3; public IntPtr Pointer, Extra; }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int GetAt(uint index, out PropertyKey key);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant value);
        [PreserveSig] int SetValue(ref PropertyKey key, ref PropVariant value);
        [PreserveSig] int Commit();
    }

    private delegate bool EnumWindowProc(IntPtr window, IntPtr parameter);
    [StructLayout(LayoutKind.Sequential)]
    private struct Message
    {
        public IntPtr Window;
        public uint Id;
        public UIntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public int X, Y;
        public uint Private;
    }
    [DllImport("user32.dll")] private static extern bool PeekMessage(out Message message, IntPtr window, uint min, uint max, uint remove);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumWindowProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint thread, uint other, bool attach);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextLength(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int count);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder image, ref int size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int GetApplicationUserModelId(IntPtr process, ref uint length, StringBuilder appId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern uint SearchPath(string? path, string file, string? extension, int size, StringBuilder result, IntPtr lastPart);
    [DllImport("shell32.dll")] private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore? store);
    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant value);
}
