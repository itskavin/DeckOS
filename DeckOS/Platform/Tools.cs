using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace DeckOS.Platform
{
    /// <summary>
    /// Ferramenta de linha de comando que faltou (xdotool, playerctl...). A mensagem ja diz o
    /// pacote a instalar: e ela que chega no log e na resposta da API, nunca um crash.
    /// </summary>
    public class ToolMissingException : InvalidOperationException
    {
        public ToolMissingException(string tool, string package)
            : base($"'{tool}' não encontrado. Instale o pacote '{package}' e tente de novo.")
        {
            Tool = tool;
            Package = package;
        }

        public string Tool { get; }
        public string Package { get; }
    }

    /// <summary>Recurso que este sistema nao tem (trocar o audio padrao no macOS, por exemplo).</summary>
    public class PlatformFeatureException : PlatformNotSupportedException
    {
        public PlatformFeatureException(string message) : base(message) { }
    }

    /// <summary>Resultado de um processo: codigo de saida e o que ele escreveu.</summary>
    public readonly record struct ToolResult(int ExitCode, string Output, string Error)
    {
        public bool Ok => ExitCode == 0;
    }

    /// <summary>
    /// Acha e roda as ferramentas do sistema que o macOS e o Linux usam no lugar das APIs do
    /// Windows (osascript, xdotool, wpctl...). Tudo com teto de tempo e sem shell: os
    /// argumentos vao um a um (ArgumentList), entao texto vindo de botao nao vira comando.
    /// </summary>
    public static class Tools
    {
        private static readonly ConcurrentDictionary<string, string?> Cache = new();

        /// <summary>Caminho completo da ferramenta no PATH, ou null. Guardado por processo.</summary>
        public static string? Which(string tool)
        {
            if (Path.IsPathRooted(tool)) return File.Exists(tool) ? tool : null;
            return Cache.GetOrAdd(tool, Find);
        }

        public static bool Has(string tool) => Which(tool) != null;

        /// <summary>Esquece o que ja foi procurado (a pessoa instalou o pacote com o DeckOS aberto).</summary>
        public static void Forget() => Cache.Clear();

        private static string? Find(string tool)
        {
            var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator).ToList();
            // launchd e systemd --user sobem com PATH curto: o Homebrew e o ~/.local/bin ficam de fora.
            dirs.AddRange(new[] { "/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin") });
            var names = OperatingSystem.IsWindows() ? new[] { tool + ".exe", tool } : new[] { tool };
            foreach (var dir in dirs.Where(d => d.Length > 0).Distinct())
            {
                foreach (var name in names)
                {
                    try
                    {
                        var full = Path.Combine(dir.Trim('"'), name);
                        if (File.Exists(full)) return full;
                    }
                    catch (ArgumentException) { }
                }
            }
            return null;
        }

        /// <summary>A ferramenta, ou <see cref="ToolMissingException"/> com o pacote que a traz.</summary>
        public static string Require(string tool, string package) =>
            Which(tool) ?? throw new ToolMissingException(tool, package);

        /// <summary>Roda e espera (ate <paramref name="timeoutMs"/>). Lanca se a ferramenta nao existir.</summary>
        public static ToolResult Run(string tool, IEnumerable<string> args, int timeoutMs = 5000, string? stdin = null)
        {
            var exe = Which(tool) ?? throw new ToolMissingException(tool, tool);
            var psi = new ProcessStartInfo(exe)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = stdin != null,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            foreach (var a in args) psi.ArgumentList.Add(a);
            using var p = Process.Start(psi) ?? throw new InvalidOperationException($"'{tool}' não iniciou.");
            if (stdin != null)
            {
                p.StandardInput.Write(stdin);
                p.StandardInput.Close();
            }
            // Leitura assincrona dos dois: um buffer cheio de stderr travaria o processo.
            var output = p.StandardOutput.ReadToEndAsync();
            var error = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(timeoutMs))
            {
                try { p.Kill(entireProcessTree: true); } catch { }
                throw new TimeoutException($"'{tool}' não respondeu em {timeoutMs / 1000.0:0.#}s.");
            }
            p.WaitForExit();
            return new ToolResult(p.ExitCode, output.Result, error.Result);
        }

        public static ToolResult Run(string tool, params string[] args) => Run(tool, (IEnumerable<string>)args);

        public static Task<ToolResult> RunAsync(string tool, IEnumerable<string> args, int timeoutMs = 5000, string? stdin = null) =>
            Task.Run(() => Run(tool, args, timeoutMs, stdin));

        /// <summary>Roda e devolve a saida, ou null se falhou (ferramenta ausente, codigo != 0, timeout).</summary>
        public static string? TryOutput(string tool, params string[] args)
        {
            try
            {
                if (!Has(tool)) return null;
                var r = Run(tool, args);
                return r.Ok ? r.Output : null;
            }
            catch
            {
                return null;
            }
        }

        /// <summary>Roda e lanca com a mensagem da ferramenta se o codigo de saida nao for 0.</summary>
        public static string Check(string tool, IEnumerable<string> args, int timeoutMs = 5000, string? stdin = null)
        {
            var r = Run(tool, args, timeoutMs, stdin);
            if (!r.Ok)
                throw new InvalidOperationException($"'{tool}' falhou ({r.ExitCode}): {(r.Error.Length > 0 ? r.Error : r.Output).Trim()}");
            return r.Output;
        }

        /// <summary>Solta um processo sem esperar (abrir app, suspender). Lanca se a ferramenta nao existir.</summary>
        public static void Spawn(string tool, IEnumerable<string> args)
        {
            var exe = Which(tool) ?? throw new ToolMissingException(tool, tool);
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var a in args) psi.ArgumentList.Add(a);
            Process.Start(psi)?.Dispose();
        }
    }

    /// <summary>
    /// Fila de comandos de uma thread so (teclas no macOS/Linux). Cada tecla e um processo
    /// novo (xdotool, osascript): sem a fila, aperta-solta de threads diferentes chegavam fora
    /// de ordem, e a repeticao de uma tecla segurada empilhava dezenas de processos.
    /// </summary>
    public sealed class CommandQueue : IDisposable
    {
        private readonly BlockingCollection<(string? key, Action run)> _queue = new();
        private readonly ConcurrentDictionary<string, byte> _pending = new();
        private readonly Thread _thread;

        public CommandQueue(string name)
        {
            _thread = new Thread(Loop) { IsBackground = true, Name = name };
            _thread.Start();
        }

        /// <summary>
        /// Enfileira. Com <paramref name="coalesceKey"/>, um comando igual que ainda nao rodou
        /// faz este ser descartado (repeticao de tecla segurada).
        /// </summary>
        public void Post(Action run, string? coalesceKey = null)
        {
            if (coalesceKey != null && !_pending.TryAdd(coalesceKey, 0)) return;
            try { _queue.Add((coalesceKey, run)); }
            catch (InvalidOperationException) { }
        }

        /// <summary>Enfileira e espera (com a excecao do comando, se houver).</summary>
        public void Send(Action run)
        {
            Exception? error = null;
            using var done = new ManualResetEventSlim();
            Post(() =>
            {
                try { run(); }
                catch (Exception ex) { error = ex; }
                finally { done.Set(); }
            });
            done.Wait(TimeSpan.FromSeconds(15));
            if (error != null) throw error;
        }

        private void Loop()
        {
            foreach (var (key, run) in _queue.GetConsumingEnumerable())
            {
                if (key != null) _pending.TryRemove(key, out _);
                try { run(); }
                catch (Exception ex) { Lib.Log.Warning(ex, "Fila de teclas"); }
            }
        }

        public void Dispose() => _queue.CompleteAdding();
    }
}
