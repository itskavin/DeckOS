using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using DeckOS.Lib;

namespace DeckOS.Auth;

/// <summary>One installation identity. Rotation is explicit: never silently replace an unreadable key.</summary>
public static class CompanionCertificate
{
    private static readonly object Gate = new();
    private static X509Certificate2? _certificate;
    private static X509KeyStorageFlags StorageFlags => OperatingSystem.IsWindows()
        ? X509KeyStorageFlags.UserKeySet : X509KeyStorageFlags.EphemeralKeySet;
    public static X509Certificate2 Get()
    {
        lock (Gate)
        {
            if (_certificate != null) return _certificate;
            var path = Path.Combine(AppPaths.LocalDir, "transport-certificate.secret");
            if (File.Exists(path))
                return _certificate = new X509Certificate2(Convert.FromBase64String(SecretFile.ReadAllText(path)),
                    (string?)null, StorageFlags);
            using var key = RSA.Create(3072);
            var request = new CertificateRequest("CN=DeckOS Companion", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
            request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
            request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
            request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new System.Security.Cryptography.OidCollection
                { new("1.3.6.1.5.5.7.3.1") }, true));
            var san = new SubjectAlternativeNameBuilder();
            san.AddDnsName("localhost");
            san.AddIpAddress(System.Net.IPAddress.Loopback);
            if (System.Net.IPAddress.TryParse(NetworkInfo.GetLanIp(), out var ip)) san.AddIpAddress(ip);
            request.CertificateExtensions.Add(san.Build());
            using var cert = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddMinutes(-5), DateTimeOffset.UtcNow.AddYears(10));
            var pfx = cert.Export(X509ContentType.Pfx);
            SecretFile.WriteAllText(path, Convert.ToBase64String(pfx));
            return _certificate = new X509Certificate2(pfx, (string?)null,
                StorageFlags);
        }
    }
    public static string Pin => Convert.ToHexString(SHA256.HashData(Get().RawData)).ToLowerInvariant();
}

public sealed record PairedDevice(string Id, string Name, string Hash, DateTimeOffset Created);

/// <summary>256-bit one-use pairing tokens in memory; only credential hashes persist.</summary>
public sealed class SecurePairing
{
    public static SecurePairing Shared { get; } = new(Path.Combine(AppPaths.LocalDir, "paired-devices.secret"));
    private readonly object _gate = new();
    private readonly string _path;
    private readonly TimeProvider _time;
    private readonly Dictionary<string, DateTimeOffset> _tokens = new();
    private readonly Dictionary<string, CancellationTokenSource> _revocations = new();
    private List<PairedDevice> _devices;
    public SecurePairing(string path, TimeProvider? time = null)
    {
        _path = path;
        _time = time ?? TimeProvider.System;
        _devices = File.Exists(path) ? JsonSerializer.Deserialize<List<PairedDevice>>(SecretFile.ReadAllText(path))! : new();
    }
    private static string Random() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();
    private static string Hash(string value) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    private static bool Equal(string a, string b) => CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(a), Encoding.ASCII.GetBytes(b));
    public string IssueToken()
    {
        lock (_gate)
        {
            foreach (var old in _tokens.Where(t => t.Value <= _time.GetUtcNow()).Select(t => t.Key).ToArray()) _tokens.Remove(old);
            // Bound local QR generation memory even if the UI is repeatedly refreshed.
            if (_tokens.Count >= 16) _tokens.Clear();
            var token = Random();
            _tokens[Hash(token)] = _time.GetUtcNow().AddMinutes(3);
            return token;
        }
    }
    public (string Id, string Credential)? Exchange(string token, string name)
    {
        if (token.Length != 64) return null;
        lock (_gate)
        {
            var hash = Hash(token);
            var found = _tokens.Keys.FirstOrDefault(k => Equal(k, hash));
            if (found == null || !_tokens.Remove(found, out var expiry) || expiry <= _time.GetUtcNow()) return null;
            var credential = Random();
            var device = new PairedDevice(Guid.NewGuid().ToString("N"), name[..Math.Min(name.Length, 80)], Hash(credential), _time.GetUtcNow());
            _devices.Add(device);
            Persist();
            return (device.Id, credential);
        }
    }
    public string? Validate(string credential)
    {
        if (credential.Length != 64) return null;
        lock (_gate) return _devices.FirstOrDefault(d => Equal(d.Hash, Hash(credential)))?.Id;
    }
    public object[] List() { lock (_gate) return _devices.Select(d => (object)new { d.Id, d.Name, d.Created }).ToArray(); }
    public bool Revoke(string id)
    {
        lock (_gate)
        {
            if (_devices.RemoveAll(d => d.Id == id) == 0) return false;
            Persist();
            if (_revocations.Remove(id, out var cancellation)) { cancellation.Cancel(); cancellation.Dispose(); }
            return true;
        }
    }
    public CancellationToken Revocation(string id)
    {
        lock (_gate)
        {
            if (!_devices.Any(d => d.Id == id)) return new CancellationToken(true);
            if (!_revocations.TryGetValue(id, out var cts)) _revocations[id] = cts = new();
            return cts.Token;
        }
    }
    private void Persist() => SecretFile.WriteAllText(_path, JsonSerializer.Serialize(_devices));
}
