// Test-only ephemeral keys. Nothing is installed in an OS trust store.
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
var dir = args[0];
Directory.CreateDirectory(dir);
using var rootKey = RSA.Create(2048);
var rootRequest = new CertificateRequest("CN=DeckOS test root", rootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
rootRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
using var root = rootRequest.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(3));
File.WriteAllText(Path.Combine(dir, "root.pem"), root.ExportCertificatePem());
foreach (var name in new[] { "server", "changed", "expired" })
{
    using var key = RSA.Create(2048);
    var request = new CertificateRequest("CN=localhost", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
    request.CertificateExtensions.Add(new X509BasicConstraintsExtension(false, false, 0, true));
    request.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.DigitalSignature | X509KeyUsageFlags.KeyEncipherment, true));
    request.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension(new OidCollection { new("1.3.6.1.5.5.7.3.1") }, true));
    var san = new SubjectAlternativeNameBuilder();
    san.AddDnsName("localhost"); san.AddIpAddress(System.Net.IPAddress.Loopback);
    request.CertificateExtensions.Add(san.Build());
    using var cert = request.Create(root, DateTimeOffset.UtcNow.AddHours(-2), name == "expired" ? DateTimeOffset.UtcNow.AddHours(-1) : DateTimeOffset.UtcNow.AddDays(1), RandomNumberGenerator.GetBytes(16));
    File.WriteAllText(Path.Combine(dir, name + ".pem"), cert.ExportCertificatePem());
    var keyPath = Path.Combine(dir, name + "-key.pem");
    var options = new FileStreamOptions { Mode = FileMode.Create, Access = FileAccess.Write };
    if (!OperatingSystem.IsWindows()) options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
    using var file = new FileStream(keyPath, options);
    using var writer = new StreamWriter(file);
    writer.Write(key.ExportPkcs8PrivateKeyPem());
    File.WriteAllText(Path.Combine(dir, name + ".pin"), Convert.ToHexString(SHA256.HashData(cert.RawData)).ToLowerInvariant());
}
