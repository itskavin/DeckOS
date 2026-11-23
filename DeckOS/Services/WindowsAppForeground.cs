using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using DeckOS.Lib;

namespace DeckOS.Services;

// Brings the launched app's user-facing window in front of the active app.
//
// A deck tap arrives over the network, so Windows treats DeckOS as a background process:
// while the user is active (foreground lock) it refuses DeckOS's SetForegroundWindow, also
// with DeckOS's own thread joined to the foreground input queue, SwitchToThisWindow and
// activation by SW_RESTORE or SC_RESTORE; the apps DeckOS starts or wakes inherit that
// refusal (measured on Windows 11 26300). What Windows allows: joining the TARGET window's
// thread to the foreground thread's queue, so activation is a switch inside the active input
// context (Firefox activates itself the same way), and, if even that is blocked (elevated
// app, hung thread), normal stacking: the window is placed above the active app without
// activation (not topmost). Every step is verified against the real foreground window and
// z-order. No input injection (Chromium's and UI Automation's synthetic hotkey), topmost,
// lock or policy changes, and other apps' windows are never touched.
//
// Identity comes from launch metadata: shortcut/exe image path, packaged AUMID and the
// process tree the launch started (launcher stubs that start the real UI from the same
// install folder). Never names, titles or the launcher PID alone.
internal static class WindowsAppForeground
{
    internal sealed record Target(string? ImagePath, string? AppUserModelId);

    internal sealed record Window(IntPtr Handle, uint ProcessId, bool Visible, bool Minimized, bool Cloaked,
        bool Owned, long ExStyle, bool HasArea, uint HostedProcessId = 0, string? AppUserModelId = null,
        (int Left, int Top, int Right, int Bottom) Bounds = default);

    internal sealed record ProcessEntry(uint Id, uint ParentId);

    internal sealed record ProcessIdentity(string? Image, string? AppUserModelId, long CreatedUtc);

    internal interface IWindows
    {
        /// <summary>Top-level windows in z-order (most recently active first).</summary>
        IReadOnlyList<Window> Snapshot(bool readAppIds);
        IReadOnlyList<ProcessEntry> Processes();
        ProcessIdentity Identity(uint processId);
        IntPtr Foreground();
        bool SetForeground(IntPtr window, bool attachInput, out string detail);
        bool Show(IntPtr window, int command);
        /// <summary>Moves the window to the top of the normal (non-topmost) z-order without activating it.</summary>
        bool Raise(IntPtr window);
        long ElapsedMs { get; }
        long UtcNow { get; }
        void Delay(int ms);
    }

    internal const int SW_RESTORE = 9;
    internal const long WS_EX_TOOLWINDOW = 0x80, WS_EX_APPWINDOW = 0x40000, WS_EX_NOACTIVATE = 0x08000000;

    private static int _generation;

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

    /// <summary>Alt+Tab rules: visible, on this desktop, activatable, unowned (or app window), not empty.</summary>
    internal static bool IsUserFacing(Window w) =>
        w.Visible && !w.Cloaked && (w.ExStyle & WS_EX_NOACTIVATE) == 0 &&
        ((w.ExStyle & WS_EX_APPWINDOW) != 0 || ((w.ExStyle & WS_EX_TOOLWINDOW) == 0 && !w.Owned)) &&
        (w.Minimized || w.HasArea);

    /// <summary>Folder whose executables belong to the same app; null for shared system folders.</summary>
    internal static string? InstallRoot(string imagePath)
    {
        var dir = Path.GetDirectoryName(imagePath);
        if (string.IsNullOrEmpty(dir)) return null;
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        if (windows.Length > 0 && IsUnder(dir, windows)) return null;
        return dir;
    }

    internal static bool IsUnder(string path, string root)
    {
        var r = root.TrimEnd('\\', '/');
        if (string.Equals(path.TrimEnd('\\', '/'), r, StringComparison.OrdinalIgnoreCase)) return true;
        return path.Length > r.Length && path[r.Length] is '\\' or '/' &&
               path.StartsWith(r, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>Snapshot before launching so windows created by the launch are recognised.</summary>
    internal static Pending? Begin(Target? target)
    {
        if (target == null || !OperatingSystem.IsWindows()) return null;
        try
        {
            var generation = Interlocked.Increment(ref _generation);
            var session = new Session(target, new NativeWindows())
            {
                Superseded = () => Volatile.Read(ref _generation) != generation,
            };
            return new Pending(session);
        }
        catch (Exception ex)
        {
            Log.Debug(ex, "AppActivator: window snapshot unavailable");
            return null;
        }
    }

    internal sealed class Pending
    {
        private readonly Session _session;
        internal Pending(Session session) => _session = session;

        /// <summary>Hands off to a background thread; the launch itself returns immediately.</summary>
        public void Start(uint launchedProcessId)
        {
            _session.Launched(launchedProcessId);
            var thread = new Thread(() =>
            {
                try { _session.Run(); }
                // Launch has already succeeded; inaccessible windows must not undo it.
                catch (Exception ex) { Log.Debug(ex, "AppActivator: window activation unavailable"); }
            }) { IsBackground = true, Name = "AppForeground" };
            thread.Start();
        }
    }

    internal sealed record Result(string Outcome, IntPtr Window, uint ProcessId, long ElapsedMs, string Steps);

    internal sealed class Session
    {
        internal const int FirstWindowMs = 12000, SettleMs = 1500, RetryMs = 250,
            ExitedLaunchMs = 4000, NewWindowGraceMs = 300, LayoutMs = 2000, MaxRaises = 3,
            RaiseVerifyMs = 300;

        private sealed class Progress
        {
            public long FirstSeen, LastTry = long.MinValue / 2, RaisedAt = -1, BoundsSince;
            public (int, int, int, int) LastBounds, RaisedBounds;
            public int Raises;
            public bool Restored;
        }

        private readonly Target _target;
        private readonly IWindows _os;
        private readonly HashSet<IntPtr> _before;
        private readonly IntPtr _originalForeground;
        private readonly long _startedUtc;
        private readonly long _startMs;
        private readonly string? _installRoot;
        private readonly HashSet<uint> _family = new();
        private readonly HashSet<string> _images = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<IntPtr, Progress> _progress = new();
        private readonly List<string> _steps = new();
        public Func<bool> Superseded { get; init; } = () => false;

        internal Session(Target target, IWindows os)
        {
            _target = target;
            _os = os;
            _before = os.Snapshot(false).Select(w => w.Handle).ToHashSet();
            _originalForeground = os.Foreground();
            _startedUtc = os.UtcNow;
            _startMs = os.ElapsedMs;
            if (target.ImagePath is { Length: > 0 } image)
            {
                _images.Add(image);
                _installRoot = InstallRoot(image);
            }
        }

        internal void Launched(uint processId)
        {
            if (processId != 0) _family.Add(processId);
        }

        internal Result Run()
        {
            long verifiedAt = -1;
            Window? raised = null;
            while (true)
            {
                var elapsed = _os.ElapsedMs - _startMs;
                if (Superseded()) return Finish("superseded", null, elapsed);

                var processes = _os.Processes();
                UpdateFamily(processes);
                var windows = _os.Snapshot(_target.AppUserModelId != null);
                var foreground = _os.Foreground();
                var fgWindow = windows.FirstOrDefault(w => w.Handle == foreground);
                var candidates = windows.Where(w => IsUserFacing(w) && IsTarget(w)).ToList();

                if (fgWindow != null && IsTarget(fgWindow))
                {
                    if (fgWindow.Visible && !fgWindow.Minimized && !fgWindow.Cloaked)
                    {
                        if (verifiedAt < 0) { verifiedAt = elapsed; _steps.Add($"foreground@{elapsed}"); }
                        // An older window got focus but the launch opened a new one (single-instance
                        // hand-off); if the app leaves the new window behind, bring that one up too.
                        var newer = !_before.Contains(foreground) ? null : candidates.FirstOrDefault(w =>
                            !_before.Contains(w.Handle) && !w.Minimized && !IsAbove(windows, w.Handle, foreground) &&
                            elapsed - Seen(w, elapsed).FirstSeen >= NewWindowGraceMs && Seen(w, elapsed).RaisedAt < 0);
                        if (newer != null) Advance(newer, elapsed, windows, foreground);
                        else if (elapsed - verifiedAt >= SettleMs) return Finish("foreground", fgWindow, elapsed);
                    }
                    // Otherwise a transient window of the app holds focus (e.g. single-instance hand-off).
                    if (elapsed >= FirstWindowMs) return Finish(verifiedAt >= 0 ? "foreground" : "transient", fgWindow, elapsed);
                    Wait(elapsed);
                    continue;
                }

                // No foreground window happens for a moment while apps swap windows.
                if (foreground == IntPtr.Zero && verifiedAt >= 0 && elapsed < FirstWindowMs) { Wait(elapsed); continue; }
                if (verifiedAt >= 0) return Finish("lost", fgWindow, elapsed); // never fight a later switch
                if (foreground != IntPtr.Zero && foreground != _originalForeground)
                    return Finish(raised != null ? "raised" : "user-switched", raised, elapsed);

                var pick = candidates.FirstOrDefault(w => !_before.Contains(w.Handle)) ?? candidates.FirstOrDefault();
                var progress = pick == null ? null : Seen(pick, elapsed);
                if (progress != null && pick!.Bounds != progress.LastBounds)
                {
                    progress.LastBounds = pick.Bounds;
                    progress.BoundsSince = elapsed;
                }
                if (progress is { RaisedAt: >= 0 })
                {
                    // In front by normal stacking; give the app a moment to activate itself, then stop.
                    // The raise is asynchronous: the app's own thread applies it a moment later.
                    raised = pick;
                    var above = IsAbove(windows, pick!.Handle, foreground) || elapsed - progress.RaisedAt < RaiseVerifyMs;
                    // A cold app still laying out moves and re-stacks its own window: stack it again.
                    // A click on another window leaves ours untouched, so the user's choice is kept.
                    if (!above && pick.Bounds != progress.RaisedBounds && progress.Raises < MaxRaises)
                    {
                        progress.RaisedAt = -1;
                        progress.LastTry = long.MinValue / 2;
                    }
                    else if (!above || elapsed - progress.RaisedAt >= SettleMs)
                        return Finish(above ? "raised" : "behind", pick, elapsed);
                }
                else if (progress != null && !_before.Contains(pick!.Handle) &&
                         elapsed - progress.BoundsSince < NewWindowGraceMs && elapsed - progress.FirstSeen < LayoutMs)
                {
                    // New window still being sized and placed by its app; act once it holds still.
                }
                else if (pick != null) Advance(pick, elapsed, windows, foreground);
                else if (elapsed >= FirstWindowMs ||
                         (elapsed >= ExitedLaunchMs && !processes.Any(p => _family.Contains(p.Id))))
                    return Finish("no-visible-window", null, elapsed);

                if (elapsed >= FirstWindowMs) return Finish("refused", pick, elapsed);
                Wait(elapsed);
            }
        }

        private void Wait(long elapsed) => _os.Delay(elapsed < 2000 ? 50 : 100);

        private Progress Seen(Window w, long elapsed)
        {
            if (!_progress.TryGetValue(w.Handle, out var p)) _progress[w.Handle] = p = new Progress { FirstSeen = elapsed };
            return p;
        }

        /// <summary>Snapshot is in z-order, so a lower index is higher on screen.</summary>
        internal static bool IsAbove(IReadOnlyList<Window> windows, IntPtr window, IntPtr other)
        {
            for (var i = 0; i < windows.Count; i++)
            {
                if (windows[i].Handle == window) return true;
                if (windows[i].Handle == other) return false;
            }
            return false;
        }

        private void Advance(Window w, long elapsed, IReadOnlyList<Window> windows, IntPtr foreground)
        {
            var p = Seen(w, elapsed);
            if (w.Minimized)
            {
                if (!p.Restored) { p.Restored = true; _steps.Add(Step(_os.Show(w.Handle, SW_RESTORE), "restore", elapsed)); }
                return;
            }
            if (elapsed - p.LastTry < RetryMs) return;
            p.LastTry = elapsed;
            if (_os.SetForeground(w.Handle, false, out var direct)) { _steps.Add($"set@{elapsed}"); return; }
            if (_os.SetForeground(w.Handle, true, out var attached)) { _steps.Add($"attach@{elapsed}"); return; }
            _steps.Add($"refused@{elapsed}({direct};{attached})");
            p.RaisedAt = elapsed;
            p.RaisedBounds = w.Bounds;
            p.Raises++;
            _steps.Add(IsAbove(windows, w.Handle, foreground) ? $"above@{elapsed}" : Step(_os.Raise(w.Handle), "raise", elapsed));
        }

        // Windows rejects these for windows protected from DeckOS (e.g. elevated apps, UIPI).
        private static string Step(bool accepted, string step, long elapsed) =>
            accepted ? $"{step}@{elapsed}" : $"{step}-denied@{elapsed}";

        private void UpdateFamily(IReadOnlyList<ProcessEntry> processes)
        {
            if (_family.Count == 0) return;
            bool added;
            do
            {
                added = false;
                foreach (var p in processes)
                {
                    if (_family.Contains(p.Id) || !_family.Contains(p.ParentId)) continue;
                    var identity = _os.Identity(p.Id);
                    // Parent PIDs are recycled: only processes started after this launch are its children.
                    if (identity.CreatedUtc < _startedUtc) continue;
                    _family.Add(p.Id);
                    added = true;
                    if (identity.Image != null && _installRoot != null && IsUnder(identity.Image, _installRoot) &&
                        _images.Add(identity.Image))
                        _steps.Add("child-image");
                }
            } while (added);
        }

        private bool IsTarget(Window w) =>
            IsTargetProcess(w.ProcessId) ||
            (w.HostedProcessId != 0 && IsTargetProcess(w.HostedProcessId)) ||
            (_target.AppUserModelId != null &&
             string.Equals(_target.AppUserModelId, w.AppUserModelId, StringComparison.OrdinalIgnoreCase));

        private bool IsTargetProcess(uint processId)
        {
            if (_family.Contains(processId)) return true;
            var identity = _os.Identity(processId);
            if (_target.AppUserModelId != null)
                return string.Equals(_target.AppUserModelId, identity.AppUserModelId, StringComparison.OrdinalIgnoreCase);
            return identity.Image != null && _images.Contains(identity.Image);
        }

        private Result Finish(string outcome, Window? w, long elapsed)
        {
            var result = new Result(outcome, w?.Handle ?? IntPtr.Zero, w?.ProcessId ?? 0, elapsed, string.Join(",", _steps));
            Log.Info("AppActivator: foreground {Outcome} hwnd {Window} pid {Pid} in {ElapsedMs} ms [{Steps}]",
                result.Outcome, result.Window, result.ProcessId, result.ElapsedMs, result.Steps);
            return result;
        }
    }

    internal sealed class NativeWindows : IWindows
    {
        private readonly Dictionary<uint, ProcessIdentity> _identities = new();
        private readonly System.Diagnostics.Stopwatch _clock = System.Diagnostics.Stopwatch.StartNew();

        public long ElapsedMs => _clock.ElapsedMilliseconds;
        public long UtcNow => DateTime.UtcNow.ToFileTimeUtc();
        public void Delay(int ms) => Thread.Sleep(ms);
        public IntPtr Foreground() => GetForegroundWindow();
        public bool Show(IntPtr window, int command) => ShowWindowAsync(window, command);
        // HWND_TOP keeps it in the normal band (never topmost); async so a hung app can't block DeckOS.
        public bool Raise(IntPtr window) =>
            SetWindowPos(window, IntPtr.Zero, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x4000 /* NOSIZE|NOMOVE|NOACTIVATE|ASYNCWINDOWPOS */);

        public IReadOnlyList<Window> Snapshot(bool readAppIds)
        {
            var list = new List<Window>();
            EnumWindows((window, _) =>
            {
                GetWindowThreadProcessId(window, out var pid);
                var visible = IsWindowVisible(window);
                var cloaked = DwmGetWindowAttribute(window, 14 /* CLOAKED */, out var c, sizeof(int)) == 0 && c != 0;
                GetWindowRect(window, out var rect);
                uint hosted = 0;
                string? appId = null;
                if (readAppIds && visible)
                {
                    appId = ReadWindowAppId(window);
                    // Older UWP windows belong to ApplicationFrameHost; their content child belongs to the app.
                    var className = new StringBuilder(64);
                    GetClassName(window, className, className.Capacity);
                    if (className.ToString() == "ApplicationFrameWindow")
                    {
                        EnumChildWindows(window, (child, _) =>
                        {
                            GetWindowThreadProcessId(child, out var childPid);
                            if (childPid != pid) hosted = childPid;
                            return hosted == 0;
                        }, IntPtr.Zero);
                    }
                }
                list.Add(new Window(window, pid, visible, IsIconic(window), cloaked,
                    GetWindow(window, 4 /* GW_OWNER */) != IntPtr.Zero, GetWindowLongPtr(window, -20).ToInt64(),
                    rect.Right > rect.Left && rect.Bottom > rect.Top, hosted, appId, (rect.Left, rect.Top, rect.Right, rect.Bottom)));
                return true;
            }, IntPtr.Zero);
            return list;
        }

        public IReadOnlyList<ProcessEntry> Processes()
        {
            var list = new List<ProcessEntry>();
            var snapshot = CreateToolhelp32Snapshot(2 /* PROCESS */, 0);
            if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) return list;
            try
            {
                var entry = new ProcessEntry32 { Size = (uint)Marshal.SizeOf<ProcessEntry32>() };
                for (var ok = Process32First(snapshot, ref entry); ok; ok = Process32Next(snapshot, ref entry))
                    list.Add(new ProcessEntry(entry.ProcessId, entry.ParentProcessId));
            }
            finally { CloseHandle(snapshot); }
            return list;
        }

        public ProcessIdentity Identity(uint processId)
        {
            if (_identities.TryGetValue(processId, out var cached)) return cached;
            var identity = new ProcessIdentity(null, null, long.MinValue);
            var process = OpenProcess(0x1000 /* QUERY_LIMITED_INFORMATION */, false, processId);
            if (process != IntPtr.Zero)
            {
                try
                {
                    var buffer = new StringBuilder(32768);
                    var size = buffer.Capacity;
                    var image = QueryFullProcessImageName(process, 0, buffer, ref size) ? buffer.ToString() : null;
                    uint length = 512;
                    var appId = new StringBuilder((int)length);
                    var aumid = GetApplicationUserModelId(process, ref length, appId) == 0 ? appId.ToString() : null;
                    var created = GetProcessTimes(process, out var c, out _, out _, out _) ? c : long.MinValue;
                    identity = new ProcessIdentity(image, aumid, created);
                }
                finally { CloseHandle(process); }
            }
            return _identities[processId] = identity;
        }

        private static bool Responsive(IntPtr window) =>
            SendMessageTimeout(window, 0 /* WM_NULL */, IntPtr.Zero, IntPtr.Zero, 0x0002 /* ABORTIFHUNG */, 200, out _) != IntPtr.Zero;

        public bool SetForeground(IntPtr window, bool attachInput, out string detail)
        {
            // A disabled main window has a modal dialog; Alt+Tab activates that popup instead.
            var popup = GetLastActivePopup(window);
            if (popup != IntPtr.Zero && popup != window && IsWindowVisible(popup) && IsWindowEnabled(popup)) window = popup;
            if (!attachInput)
            {
                var ok = SetForegroundWindow(window);
                detail = ok ? "set" : "set-denied";
                return GetForegroundWindow() == window;
            }

            // Join the TARGET window's thread to the foreground thread's input queue: activation is
            // then a switch inside the active input context, which Windows allows (measured; Firefox
            // does the same from its own thread). Joining DeckOS's own thread instead is refused.
            // While joined the two apps share input state, so both must be responsive right now and
            // the join is always undone. Windows still blocks this across integrity levels (UIPI).
            var foreground = GetForegroundWindow();
            var targetThread = GetWindowThreadProcessId(window, out _);
            var foregroundThread = GetWindowThreadProcessId(foreground, out _);
            if (targetThread == 0 || foregroundThread == 0 || targetThread == foregroundThread)
            {
                detail = "attach-none";
                return false;
            }
            if (!Responsive(window) || !Responsive(foreground))
            {
                detail = "attach-hung";
                return false;
            }
            var attached = AttachThreadInput(targetThread, foregroundThread, true);
            var error = attached ? 0 : Marshal.GetLastWin32Error();
            var set = false;
            try { if (attached) set = SetForegroundWindow(window); }
            finally { if (attached) AttachThreadInput(targetThread, foregroundThread, false); }
            detail = $"attach-{(attached ? "ok" : "err" + error)}-{(set ? "set" : "denied")}";
            return GetForegroundWindow() == window;
        }
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
    private struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry32
    {
        public uint Size, Usage, ProcessId;
        public IntPtr DefaultHeapId;
        public uint ModuleId, Threads, ParentProcessId;
        public int PriorityClassBase;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ExeFile;
    }
    [DllImport("user32.dll")] private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumWindowProc callback, IntPtr parameter);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr GetLastActivePopup(IntPtr window);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool AttachThreadInput(uint thread, uint other, bool attach);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int count);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr window, int index);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
    [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("kernel32.dll")] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", CharSet = CharSet.Unicode)] private static extern bool Process32First(IntPtr snapshot, ref ProcessEntry32 entry);
    [DllImport("kernel32.dll", EntryPoint = "Process32NextW", CharSet = CharSet.Unicode)] private static extern bool Process32Next(IntPtr snapshot, ref ProcessEntry32 entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder image, ref int size);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern int GetApplicationUserModelId(IntPtr process, ref uint length, StringBuilder appId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern uint SearchPath(string? path, string file, string? extension, int size, StringBuilder result, IntPtr lastPart);
    [DllImport("shell32.dll")] private static extern int SHGetPropertyStoreForWindow(IntPtr window, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore? store);
    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant value);
}
