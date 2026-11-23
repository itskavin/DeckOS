using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace DeckOS.Lib
{
    /// <summary>
    /// Conexao pelo cabo USB: com a depuracao USB ligada no celular, o "adb reverse" faz o
    /// 127.0.0.1:4787 do celular cair no 4787 do PC. Funciona sem Wi-Fi, em rede que isola
    /// os aparelhos e com firewall fechado, e tem menos atraso.
    ///
    /// Usa o adb que ja existir (Android SDK, PATH). Sem ele, o menu da bandeja baixa as
    /// platform-tools oficiais do Google para %LocalAppData%\DeckOS\platform-tools.
    ///
    /// SEGURANCA: a conexao encaminhada chega no servidor como loopback, vinda do adb.exe.
    /// Ela NAO pode valer como "o proprio PC": qualquer app do celular alcanca o
    /// 127.0.0.1:4787 dele enquanto o encaminhamento existe. Ver <see cref="IsForwarded"/>.
    /// </summary>
    public class UsbBridge : BackgroundService
    {
        public static string PlatformToolsUrl =>
            "https://dl.google.com/android/repository/platform-tools-latest-" +
            (OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "darwin" : "linux") + ".zip";

        private readonly ILogger<UsbBridge> _logger;
        private readonly Func<string?> _findAdb;
        private readonly TimeSpan _interval;
        private readonly TimeSpan _commandTimeout;
        private readonly object _lock = new();
        private HashSet<string> _forwarded = new();
        private bool _timedOut;

        /// <summary>Instancia em uso (para a bandeja, que nao tem DI).</summary>
        public static UsbBridge? Instance { get; private set; }

        public UsbBridge(ILogger<UsbBridge> logger)
            : this(logger, () => Enabled ? FindAdb() : null, TimeSpan.FromSeconds(4), TimeSpan.FromSeconds(15))
        {
            Instance = this;
        }

        /// <summary>Para os testes: outro adb e outros tempos.</summary>
        internal UsbBridge(ILogger<UsbBridge> logger, Func<string?> findAdb, TimeSpan interval, TimeSpan commandTimeout)
        {
            _logger = logger;
            _findAdb = findAdb;
            _interval = interval;
            _commandTimeout = commandTimeout;
        }

        /// <summary>Muda quando um celular entra ou sai pelo USB.</summary>
        public event Action? Changed;

        /// <summary>Celulares (serial do adb) com o encaminhamento ativo.</summary>
        public IReadOnlyCollection<string> Devices
        {
            get { lock (_lock) return _forwarded.ToList(); }
        }

        // ---- Configuracao ----

        private static string SettingsPath => Path.Combine(AppPaths.LocalDir, "usb.json");

        private class Settings
        {
            public bool Enabled { get; set; }
        }

        /// <summary>
        /// Ligado? Sem escolha salva, liga sozinho quando ja existe um adb no PC (quem tem o
        /// SDK do Android). Baixar o adb e sempre uma escolha da pessoa.
        /// </summary>
        public static bool Enabled
        {
            get
            {
                try
                {
                    if (File.Exists(SettingsPath))
                        return JsonSerializer.Deserialize<Settings>(File.ReadAllText(SettingsPath))?.Enabled ?? false;
                }
                catch { }
                return FindAdb() != null;
            }
            set
            {
                try { File.WriteAllText(SettingsPath, JsonSerializer.Serialize(new Settings { Enabled = value })); }
                catch { }
            }
        }

        private static string OwnPlatformTools => Path.Combine(AppPaths.LocalDir, "platform-tools");

        /// <summary>Caminho do adb (adb.exe no Windows), ou null se nao houver nenhum.</summary>
        public static string? FindAdb()
        {
            var exe = OperatingSystem.IsWindows() ? "adb.exe" : "adb";
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var candidates = new List<string>();
            var sdk = Environment.GetEnvironmentVariable("ANDROID_HOME") ?? Environment.GetEnvironmentVariable("ANDROID_SDK_ROOT");
            if (!string.IsNullOrEmpty(sdk)) candidates.Add(Path.Combine(sdk, "platform-tools", exe));
            if (OperatingSystem.IsWindows())
                candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "Android", "Sdk", "platform-tools", exe));
            else if (OperatingSystem.IsMacOS())
                candidates.Add(Path.Combine(home, "Library", "Android", "sdk", "platform-tools", exe));
            else
                candidates.Add(Path.Combine(home, "Android", "Sdk", "platform-tools", exe));
            foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
            {
                if (dir.Length > 0) candidates.Add(Path.Combine(dir.Trim('"'), exe));
            }
            // PATH curto do launchd/systemd: o Homebrew e o /usr/bin ficam de fora.
            if (!OperatingSystem.IsWindows())
                candidates.AddRange(new[] { "/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/usr/bin/adb" });
            candidates.Add(Path.Combine(OwnPlatformTools, exe));
            return candidates.FirstOrDefault(File.Exists);
        }

        /// <summary>Baixa as platform-tools do Google (uns 7 MB) para a pasta do DeckOS.</summary>
        public static async Task DownloadAdbAsync(CancellationToken ct = default)
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
            var zip = Path.Combine(Path.GetTempPath(), "deckos-platform-tools.zip");
            await using (var file = File.Create(zip))
            await using (var stream = await http.GetStreamAsync(PlatformToolsUrl, ct))
                await stream.CopyToAsync(file, ct);
            try
            {
                if (Directory.Exists(OwnPlatformTools)) Directory.Delete(OwnPlatformTools, true);
                // O zip tem a pasta platform-tools\ na raiz.
                ZipFile.ExtractToDirectory(zip, AppPaths.LocalDir, overwriteFiles: true);
            }
            finally
            {
                try { File.Delete(zip); } catch { }
            }
        }

        // ---- Laco ----

        protected override async Task ExecuteAsync(CancellationToken stoppingToken)
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    if (_findAdb() is { } adb) await SyncAsync(adb, stoppingToken);
                    else SetForwarded(new HashSet<string>());
                    _timedOut = false;
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
                catch (TimeoutException ex)
                {
                    // Um adb travado nao desliga o cabo de vez: a proxima volta tenta de novo.
                    if (!_timedOut) _logger.LogWarning("USB: {Message}", ex.Message);
                    _timedOut = true;
                }
                catch (Exception ex)
                {
                    _logger.LogDebug("USB: {Message}", ex.Message);
                }
                try { await Task.Delay(_interval, stoppingToken); }
                catch (OperationCanceledException) { break; }
            }
        }

        private async Task SyncAsync(string adb, CancellationToken ct)
        {
            var devices = ParseDevices(await RunAsync(adb, "devices", ct));
            var now = new HashSet<string>();
            foreach (var serial in devices)
            {
                var list = await RunAsync(adb, $"-s {serial} reverse --list", ct);
                if (!HasReverse(list, PairingInfo.Port))
                {
                    await RunAsync(adb, $"-s {serial} reverse tcp:{PairingInfo.Port} tcp:{PairingInfo.Port}", ct);
                    _logger.LogInformation("USB: celular {Serial} conectado pelo cabo", serial);
                }
                now.Add(serial);
            }
            SetForwarded(now);
        }

        private void SetForwarded(HashSet<string> now)
        {
            bool changed;
            lock (_lock)
            {
                changed = !now.SetEquals(_forwarded);
                _forwarded = now;
            }
            if (changed) Changed?.Invoke();
        }

        private async Task<string> RunAsync(string exe, string args, CancellationToken ct)
        {
            var psi = new ProcessStartInfo(exe, args)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("adb nao iniciou");
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeout.CancelAfter(_commandTimeout);
            try
            {
                var output = await p.StandardOutput.ReadToEndAsync(timeout.Token);
                await p.WaitForExitAsync(timeout.Token);
                return output;
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                // A saida pode nunca fechar: o servidor que o adb sobe herda o pipe dela.
                // Mata so este cliente (nunca a arvore, que pode ser o servidor do adb).
                try { p.Kill(); } catch { }
                throw new TimeoutException($"\"adb {args}\" passou de {_commandTimeout.TotalSeconds:0} s");
            }
        }

        /// <summary>Seriais prontos ("device") na saida do "adb devices".</summary>
        public static List<string> ParseDevices(string output) =>
            output.Split('\n')
                .Select(l => l.Trim())
                .Where(l => l.Length > 0 && !l.StartsWith("List of devices") && !l.StartsWith("*"))
                .Select(l => l.Split('\t', ' ', StringSplitOptions.RemoveEmptyEntries))
                .Where(p => p.Length >= 2 && p[1] == "device")
                .Select(p => p[0])
                .ToList();

        /// <summary>A saida do "adb reverse --list" ja tem tcp:porta → tcp:porta?</summary>
        public static bool HasReverse(string output, int port) =>
            output.Split('\n').Any(l => l.Contains($"tcp:{port} tcp:{port}"));

        // ---- Quem esta do outro lado de uma conexao loopback ----

        /// <summary>
        /// A conexao loopback que chegou na porta do servidor vem do adb (um celular pelo
        /// USB)? Procura na tabela TCP do Windows o processo dono da ponta do cliente. No
        /// Linux, pelo /proc; no macOS, pelo lsof. Fora do Windows, na duvida (adb rodando e
        /// sem como conferir), vale como encaminhada: e o lado seguro.
        /// </summary>
        public static bool IsForwarded(IPAddress? remoteIp, int remotePort)
        {
            if (remoteIp == null) return false;
            if (remoteIp.IsIPv4MappedToIPv6) remoteIp = remoteIp.MapToIPv4();
            if (!IPAddress.IsLoopback(remoteIp)) return false;
            if (!OperatingSystem.IsWindows()) return UnixIsForwarded(remotePort);
            var pid = OwnerOfLoopbackClient(remotePort, PairingInfo.Port);
            if (pid is not int id) return false;
            try
            {
                using var proc = Process.GetProcessById(id);
                return proc.ProcessName.Equals("adb", StringComparison.OrdinalIgnoreCase);
            }
            catch
            {
                return false;
            }
        }

        private static bool UnixIsForwarded(int clientPort)
        {
            // Sem adb rodando ninguem encaminha: o caso comum sai daqui, sem ler nada.
            var adb = Process.GetProcessesByName("adb");
            try
            {
                if (adb.Length == 0) return false;
                var pids = adb.Select(p => p.Id).ToList();
                return OperatingSystem.IsLinux() ? LinuxOwnedBy(pids, clientPort) : MacOwnedBy(pids, clientPort);
            }
            catch
            {
                return true;
            }
            finally
            {
                foreach (var p in adb) p.Dispose();
            }
        }

        /// <summary>
        /// Inodes das conexoes porta-cliente → porta-servidor no texto do /proc/net/tcp(6). Os
        /// enderecos vem em hexa ("0100007F:C350"); a porta, em hexa big-endian.
        /// </summary>
        public static List<long> ProcNetTcpInodes(string table, int clientPort, int serverPort)
        {
            var list = new List<long>();
            foreach (var line in table.Split('\n').Skip(1))
            {
                var f = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (f.Length < 10) continue;
                static int Port(string endpoint) =>
                    endpoint.LastIndexOf(':') is var i and >= 0 && int.TryParse(endpoint[(i + 1)..], System.Globalization.NumberStyles.HexNumber, null, out var p) ? p : -1;
                if (Port(f[1]) != clientPort || Port(f[2]) != serverPort) continue;
                if (long.TryParse(f[9], out var inode) && inode > 0) list.Add(inode);
            }
            return list;
        }

        private static bool LinuxOwnedBy(List<int> adbPids, int clientPort)
        {
            var inodes = new List<long>();
            foreach (var file in new[] { "/proc/net/tcp", "/proc/net/tcp6" })
                if (File.Exists(file)) inodes.AddRange(ProcNetTcpInodes(File.ReadAllText(file), clientPort, PairingInfo.Port));
            // Conexao sumiu da tabela no meio do pedido: com adb rodando, nao arrisca.
            if (inodes.Count == 0) return true;
            var targets = inodes.Select(i => $"socket:[{i}]").ToHashSet();
            foreach (var pid in adbPids)
            {
                // adb de outro usuario (ou do root): sem acesso aos fds, vale como encaminhada.
                foreach (var fd in Directory.EnumerateFileSystemEntries($"/proc/{pid}/fd"))
                {
                    string? link;
                    try { link = new FileInfo(fd).LinkTarget; }
                    catch { continue; }
                    if (link != null && targets.Contains(link)) return true;
                }
            }
            return false;
        }

        private static bool MacOwnedBy(List<int> adbPids, int clientPort)
        {
            // -a junta os filtros: so sockets do adb com a porta do cliente. Sem lsof, na duvida, true.
            var r = Platform.Tools.Run("lsof", new[] { "-nP", "-a", "-p", string.Join(",", adbPids), $"-iTCP:{clientPort}", "-t" }, 3000);
            // lsof sai com 1 quando nao acha nada (e com saida vazia): ai nao e do adb.
            if (r.ExitCode == 1 && r.Output.Trim().Length == 0) return false;
            return !r.Ok || r.Output.Trim().Length > 0;
        }

        private const int AF_INET = 2;
        private const int TCP_TABLE_OWNER_PID_CONNECTIONS = 4;

        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int af, int tableClass, uint reserved);

        [StructLayout(LayoutKind.Sequential)]
        private struct TcpRowOwnerPid
        {
            public uint State, LocalAddr, LocalPort, RemoteAddr, RemotePort, OwningPid;
        }

        private static int NetPort(uint raw) => (int)(((raw & 0xFF) << 8) | ((raw >> 8) & 0xFF));

        /// <summary>PID do processo com a conexao local:clientPort → local:serverPort.</summary>
        public static int? OwnerOfLoopbackClient(int clientPort, int serverPort)
        {
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS, 0);
            var buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (GetExtendedTcpTable(buffer, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_CONNECTIONS, 0) != 0)
                    return null;
                var count = Marshal.ReadInt32(buffer);
                var rowSize = Marshal.SizeOf<TcpRowOwnerPid>();
                for (var i = 0; i < count; i++)
                {
                    var row = Marshal.PtrToStructure<TcpRowOwnerPid>(buffer + 4 + i * rowSize);
                    if (NetPort(row.LocalPort) == clientPort && NetPort(row.RemotePort) == serverPort)
                        return (int)row.OwningPid;
                }
                return null;
            }
            finally
            {
                Marshal.FreeHGlobal(buffer);
            }
        }
    }
}
