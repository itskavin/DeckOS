using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using DeckOS.Lib;

namespace DeckOS.Platform
{
    /// <summary>
    /// O comum das listas de apps: guarda a lista por alguns minutos (varrer o menu Iniciar
    /// ou /Applications leva centenas de ms) com atualizacao em segundo plano quando vence
    /// (stale-while-revalidate, para um aperto de botao nunca travar esperando rescan),
    /// busca O(1) por id e cache limitado de icones em memoria e disco.
    /// </summary>
    public abstract class InstalledAppsBase : IInstalledApps
    {
        private static readonly TimeSpan DefaultListTtl = TimeSpan.FromMinutes(5);
        private static readonly TimeSpan IconTtl = TimeSpan.FromDays(7);
        private const int MaxMemoryIcons = 128;
        private const long MaxMemoryIconBytes = 16L * 1024 * 1024;
        private const int MaxDiskIcons = 512;

        private readonly object _lock = new();
        private readonly object _scanGate = new();
        private readonly SemaphoreSlim _iconGate = new(4, 4);
        private readonly ConcurrentDictionary<string, Task<(byte[] Data, string ContentType)?>> _inflightIcons = new(StringComparer.OrdinalIgnoreCase);

        private readonly object _iconCacheLock = new();
        private readonly Dictionary<string, LinkedListNode<CachedIcon>> _iconCache = new(StringComparer.OrdinalIgnoreCase);
        private readonly LinkedList<CachedIcon> _iconLru = new();
        private long _iconCacheBytes;
        private DateTime _lastDiskPruneUtc = DateTime.MinValue;

        private List<InstalledApp>? _apps;
        private Dictionary<string, InstalledApp>? _byId;
        private DateTime _scannedAt;
        private int _refreshing;

        private sealed record CachedIcon(string Id, byte[] Data, string ContentType, DateTime CachedAtUtc);

        /// <summary>Hooks para testes (tempo e TTL).</summary>
        internal Func<DateTime> UtcNow { get; set; } = () => DateTime.UtcNow;
        internal TimeSpan ListTtl { get; set; } = DefaultListTtl;

        /// <summary>Varre o sistema. Pode repetir nomes: a base fica com o primeiro.</summary>
        protected abstract IEnumerable<InstalledApp> Scan();

        /// <summary>Extrai o icone (sem cache). Null se o app nao tem um que sirva.</summary>
        protected abstract Task<(byte[] Data, string ContentType)?> LoadIconAsync(InstalledApp app);

        /// <summary>Id estavel de um app: hash do caminho (o mesmo app tem o mesmo id entre reinicios).</summary>
        public static string MakeId(string key)
        {
            var hash = SHA1.HashData(Encoding.UTF8.GetBytes(key.ToLowerInvariant()));
            return Convert.ToHexString(hash, 0, 8).ToLowerInvariant();
        }

        /// <summary>
        /// Pre-aquece a lista em segundo plano sem bloquear quem chamou (ex.: ao subir o
        /// servidor, antes do primeiro aperto de botao). Idempotente.
        /// </summary>
        public void Prewarm()
        {
            lock (_lock)
            {
                if (_apps != null && UtcNow() - _scannedAt < ListTtl) return;
            }
            TriggerBackgroundRefresh();
        }

        /// <summary>Descarta o cache em memoria (usado em testes ou apos mudanca explicita).</summary>
        internal void Invalidate()
        {
            lock (_lock)
            {
                _apps = null;
                _byId = null;
                _scannedAt = DateTime.MinValue;
            }
            lock (_iconCacheLock)
            {
                _iconCache.Clear();
                _iconLru.Clear();
                _iconCacheBytes = 0;
            }
        }

        public IReadOnlyList<InstalledApp> List()
        {
            var now = UtcNow();
            List<InstalledApp>? cached;
            bool stale;
            lock (_lock)
            {
                cached = _apps;
                stale = cached == null || now - _scannedAt >= ListTtl;
            }
            if (cached != null)
            {
                if (stale) TriggerBackgroundRefresh();
                return cached;
            }
            return RefreshSynchronously();
        }

        public InstalledApp? Find(string id)
        {
            if (string.IsNullOrEmpty(id)) return null;
            var now = UtcNow();
            Dictionary<string, InstalledApp>? byId;
            bool stale;
            lock (_lock)
            {
                byId = _byId;
                stale = byId == null || now - _scannedAt >= ListTtl;
            }
            if (byId != null)
            {
                if (stale) TriggerBackgroundRefresh();
                return byId.TryGetValue(id, out var found) ? found : null;
            }
            RefreshSynchronously();
            lock (_lock)
            {
                return _byId != null && _byId.TryGetValue(id, out var found) ? found : null;
            }
        }

        private void TriggerBackgroundRefresh()
        {
            if (Interlocked.CompareExchange(ref _refreshing, 1, 0) != 0) return;
            _ = Task.Run(() =>
            {
                try
                {
                    RefreshSynchronously();
                }
                catch (Exception ex)
                {
                    Log.Debug(ex, "Apps instalados: falha ao atualizar cache em segundo plano");
                }
                finally
                {
                    Volatile.Write(ref _refreshing, 0);
                }
            });
        }

        private IReadOnlyList<InstalledApp> RefreshSynchronously()
        {
            lock (_scanGate)
            {
                var now = UtcNow();
                lock (_lock)
                {
                    if (_apps != null && now - _scannedAt < ListTtl) return _apps;
                }

                var sw = Stopwatch.StartNew();
                List<InstalledApp> apps;
                try
                {
                    apps = Scan()
                        .Where(a => !string.IsNullOrWhiteSpace(a.Name))
                        .GroupBy(a => a.Name.Trim(), StringComparer.OrdinalIgnoreCase)
                        .Select(g => g.First())
                        .GroupBy(a => a.Id)
                        .Select(g => g.First())
                        .OrderBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase)
                        .ToList();
                }
                catch (Exception ex)
                {
                    Log.Warning(ex, "Apps instalados: falha ao listar");
                    lock (_lock)
                    {
                        if (_apps != null) return _apps;
                    }
                    apps = new List<InstalledApp>();
                }
                sw.Stop();
                Log.Debug("Apps instalados: scan concluido ({Count} apps) em {ElapsedMs} ms", apps.Count, sw.ElapsedMilliseconds);

                var byId = new Dictionary<string, InstalledApp>(apps.Count, StringComparer.OrdinalIgnoreCase);
                foreach (var app in apps) byId[app.Id] = app;

                lock (_lock)
                {
                    _apps = apps;
                    _byId = byId;
                    _scannedAt = UtcNow();
                }
                return apps;
            }
        }

        private static string IconDir => Path.Combine(AppPaths.LocalDir, "app-icons");

        public Task<(byte[] Data, string ContentType)?> GetIconAsync(string id)
        {
            // O id vira nome de arquivo: so hex, sem chance de ../.
            if (id.Length == 0 || id.Length > 64 || !id.All(Uri.IsHexDigit))
                return Task.FromResult<(byte[], string)?>(null);

            if (TryGetMemoryIcon(id, out var mem))
                return Task.FromResult<(byte[], string)?>(mem);

            return _inflightIcons.GetOrAdd(id, LoadIconDeduplicatedAsync);
        }

        private async Task<(byte[] Data, string ContentType)?> LoadIconDeduplicatedAsync(string id)
        {
            try
            {
                var app = Find(id);
                if (app == null) return null;

                Directory.CreateDirectory(IconDir);
                var now = UtcNow();
                foreach (var (ext, type) in new[] { ("png", "image/png"), ("svg", "image/svg+xml") })
                {
                    var cached = Path.Combine(IconDir, $"{app.Id}.{ext}");
                    if (File.Exists(cached) && now - File.GetLastWriteTimeUtc(cached) < IconTtl)
                    {
                        var data = await File.ReadAllBytesAsync(cached);
                        PutMemoryIcon(app.Id, data, type);
                        return (data, type);
                    }
                }

                await _iconGate.WaitAsync();
                try
                {
                    var icon = await LoadIconAsync(app);
                    if (icon == null) return null;
                    PutMemoryIcon(app.Id, icon.Value.Data, icon.Value.ContentType);
                    var ext = icon.Value.ContentType == "image/svg+xml" ? "svg" : "png";
                    try
                    {
                        await File.WriteAllBytesAsync(Path.Combine(IconDir, $"{app.Id}.{ext}"), icon.Value.Data);
                        MaybePruneDiskCache();
                    }
                    catch (IOException) { }
                    return icon;
                }
                catch (Exception ex)
                {
                    Log.Debug(ex, "Apps instalados: icone de {Name} falhou", app.Name);
                    return null;
                }
                finally
                {
                    _iconGate.Release();
                }
            }
            finally
            {
                _inflightIcons.TryRemove(id, out _);
            }
        }

        private bool TryGetMemoryIcon(string id, out (byte[] Data, string ContentType) icon)
        {
            var now = UtcNow();
            lock (_iconCacheLock)
            {
                if (_iconCache.TryGetValue(id, out var node))
                {
                    if (now - node.Value.CachedAtUtc < IconTtl)
                    {
                        _iconLru.Remove(node);
                        _iconLru.AddLast(node);
                        icon = (node.Value.Data, node.Value.ContentType);
                        return true;
                    }
                    _iconLru.Remove(node);
                    _iconCache.Remove(id);
                    _iconCacheBytes -= node.Value.Data.Length;
                }
            }
            icon = default;
            return false;
        }

        private void PutMemoryIcon(string id, byte[] data, string contentType)
        {
            if (data.Length > MaxMemoryIconBytes / 4) return;
            var entry = new CachedIcon(id, data, contentType, UtcNow());
            lock (_iconCacheLock)
            {
                if (_iconCache.TryGetValue(id, out var existing))
                {
                    _iconLru.Remove(existing);
                    _iconCacheBytes -= existing.Value.Data.Length;
                }
                var node = _iconLru.AddLast(entry);
                _iconCache[id] = node;
                _iconCacheBytes += data.Length;

                while (_iconCache.Count > MaxMemoryIcons || _iconCacheBytes > MaxMemoryIconBytes)
                {
                    var oldest = _iconLru.First;
                    if (oldest == null) break;
                    _iconLru.RemoveFirst();
                    _iconCache.Remove(oldest.Value.Id);
                    _iconCacheBytes -= oldest.Value.Data.Length;
                }
            }
        }

        private void MaybePruneDiskCache()
        {
            var now = UtcNow();
            lock (_iconCacheLock)
            {
                if (now - _lastDiskPruneUtc < TimeSpan.FromMinutes(30)) return;
                _lastDiskPruneUtc = now;
            }
            _ = Task.Run(() =>
            {
                try
                {
                    var dir = new DirectoryInfo(IconDir);
                    if (!dir.Exists) return;
                    var files = dir.GetFiles();
                    var kept = new List<FileInfo>(files.Length);
                    foreach (var f in files)
                    {
                        if (now - f.LastWriteTimeUtc >= IconTtl)
                        {
                            try { f.Delete(); } catch { }
                        }
                        else
                        {
                            kept.Add(f);
                        }
                    }
                    if (kept.Count > MaxDiskIcons)
                    {
                        foreach (var f in kept.OrderBy(x => x.LastWriteTimeUtc).Take(kept.Count - MaxDiskIcons))
                        {
                            try { f.Delete(); } catch { }
                        }
                    }
                }
                catch { }
            });
        }
    }

    /// <summary>Sistema sem lista de apps (binario portavel rodando no Windows, BSD...).</summary>
    public sealed class NoInstalledApps : IInstalledApps
    {
        public IReadOnlyList<InstalledApp> List() => Array.Empty<InstalledApp>();
        public InstalledApp? Find(string id) => null;
        public Task<(byte[] Data, string ContentType)?> GetIconAsync(string id) =>
            Task.FromResult<(byte[], string)?>(null);
    }
}
